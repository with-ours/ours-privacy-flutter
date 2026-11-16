// Port of __tests__/mobile-contract.test.js (React Native SDK).
//
// The mobile wire contract: SDK-owned metadata lives in eventProperties,
// `sid` in defaultProperties, canonical facts carry no PHI, and persisted
// queues and pending facts from older layouts normalize on load.
//
// Mapping of the Jest setup:
// - `jest.useFakeTimers({ now: START })` -> [SessionFakeTimers] at
//   [sessionStart] (no test advances time).
// - `Platform.OS = platform` -> [StaticDeviceInfo.ios] / `.android`; RN's
//   default mock platform is iOS and `AppState.currentState` is 'active'.
// - `react-native@${packageJson.version}` -> `oursPrivacyLibraryVersion`
//   (`flutter@<version>`).
// - `client.oursprivacyImpl._pendingOperation` -> awaiting the returned
//   futures, then [settle] (in-memory storage settles every serialized
//   operation).
// - `OursPrivacyPersistent.getInstance()` -> the implementation's
//   `persistent` (shared per storage backend).
// - `jest.resetModules()` mid-test -> [SessionSdk.restart].
// - Stored items that carry `version: 'react-native@4.x'` are kept verbatim:
//   they are opaque queued data from another SDK and must pass through.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:ours_privacy/src/constants.dart';
import 'package:ours_privacy/src/mobile_session.dart';
import 'package:ours_privacy/src/testing.dart';
import 'package:ours_privacy/src/version.dart';

import 'helpers/session_harness.dart';

const String _iso = sessionIso;
String _queueKey(String token) => queueKey(token, eventsQueueType);

const Map<String, Object?> _serverAck = {
  'success': true,
  'visitor_id': 'server-visitor',
};

void main() {
  late SessionSdk sdk;

  setUp(() {
    resetOursPrivacyForTesting();
    sdk = SessionSdk();
  });

  tearDown(() async {
    await sdk.disposeAll();
    resetOursPrivacyForTesting();
  });

  for (final platform in ['ios', 'android']) {
    test(
        'owns metadata in event properties on every $platform event without automatic PHI',
        () async {
      sdk.device = platform == 'ios'
          ? const StaticDeviceInfo.ios()
          : const StaticDeviceInfo.android();
      final client = sdk.create();
      await client.init(
        'wire',
        storage: SessionHookStorage(),
        trackAutomaticEvents: true,
        appVersion: '2.0',
        appBuild: '42',
        defaultEventProperties: {
          'mobile_contract_version': 9,
          'app_build': 'bad',
          'patient': 'excluded',
        },
        defaultUserCustomProperties: {'patient': 'excluded'},
        initialURL: 'example://open?utm_source=campaign&email=excluded',
      );
      unawaited(client.trackScreen('Schedule'));
      unawaited(client.track(
        'appointment_booked',
        {
          'mobile_contract_version': 9,
          'mobile_occurred_at': 'bad',
          'mobile_session_started_at': 'bad',
          'mobile_platform': 'bad',
          'app_version': 'bad',
        },
        {
          'externalId': 'synthetic-patient',
          'customProperties': {'healthcare': 'caller-supplied'},
        },
      ));
      await client.identify({'externalId': 'synthetic-patient'});
      await settle();
      sdk.mockResponse(_serverAck);
      await client.flush();
      final events = sdk.sentEvents;
      expect(events.length, greaterThanOrEqualTo(7));
      for (final event in events) {
        final defaults = event['defaultProperties']! as Map;
        final properties = event['eventProperties']! as Map;
        expect(defaults['sid'], '$sessionStart');
        expect(
          defaults,
          matchesObject({
            'os_name': platform == 'ios' ? 'iOS' : 'Android',
            'version': oursPrivacyLibraryVersion,
            'device_type': 'mobile',
          }),
        );
        expect(
          properties,
          matchesObject({
            'mobile_contract_version': 1,
            'mobile_occurred_at': _iso,
            'app_version': '2.0',
            'app_build': '42',
          }),
        );
        for (final key in [
          'mobile_session_started_at',
          'mobile_platform',
          'mobile_contract_version',
          'mobile_occurred_at',
          'app_version',
          'app_build',
        ]) {
          expect(defaults.containsKey(key), isFalse, reason: key);
        }
        expect(properties.containsKey('mobile_session_started_at'), isFalse);
        expect(properties.containsKey('mobile_platform'), isFalse);
        expect(event.containsKey('isManuallySetId'), isFalse);
        if ((event['event']! as String).startsWith(r'$mobile_')) {
          expect(event['userProperties'], isNull);
          expect(properties.containsKey('patient'), isFalse);
          expect(defaults.containsKey('utm_source'), isFalse);
        }
      }
      expect(
        events.firstWhere((event) => event['event'] == 'appointment_booked')[
            'userProperties'],
        {
          'external_id': 'synthetic-patient',
          'custom_properties': {
            'patient': 'excluded',
            'healthcare': 'caller-supplied',
          },
        },
      );
    });
  }

  test(
      'preserves caller host metadata when initialization provides no override',
      () async {
    final client = sdk.create();
    await client.init('no-host', storage: SessionHookStorage());
    await client.track('manual', {
      'app_version': 'fake',
      'app_build': 'fake',
      'mobile_contract_version': 9,
    });
    await settle();
    expect(sdk.queue(client, 'no-host')[0]['eventProperties'], {
      'app_version': 'fake',
      'app_build': 'fake',
      'mobile_contract_version': 1,
      'mobile_occurred_at': _iso,
    });
  });

  test(
      'starts a fresh session after a saved UUID without repeating first-open or changing pending facts',
      () async {
    final pending = <String, Object?>{
      'id': 'captured-fact',
      'visitorId': 'captured-visitor',
      'isManuallySetId': false,
      'appVersion': '1.0',
      'appBuild': '20',
      'fact': {
        'event': r'$mobile_screen_view',
        'eventProperties': {'screen_name': 'Schedule'},
        'defaultProperties': {
          'sid': 'old-uuid',
          'mobile_session_started_at': '2026-10-05T11:59:55.000Z',
          'mobile_occurred_at': '2026-10-05T11:59:59.000Z',
        },
      },
    };
    final storage = SessionMapStorage({
      'OURSPRIVACY_migrate_MOBILE_SESSION_V1': jsonEncode({
        'sid': 'old-uuid',
        'startedAtMs': sessionStart - 5000,
        'lastActiveAtMs': sessionStart - 1000,
        'firstOpenSent': true,
        'sessionStartSent': true,
        'foregroundDurationMs': 9000,
        'pendingEvents': [pending],
      }),
    });
    final session = MobileSession(
      token: 'migrate',
      storage: storage,
      wallNow: () => sessionStart,
      monotonicNow: () => 0,
    );
    await session.load();
    expect(
      [for (final record in await session.pendingQueueFacts()) record.toJson()],
      [pending],
    );
    final facts = await session.foreground(automaticEnabled: true);
    expect(eventNames(facts), [
      r'$mobile_app_open',
      r'$mobile_session_start',
    ]);
    for (final fact in facts) {
      expect(fact.defaultProperties, {
        'sid': '$sessionStart',
        'mobile_occurred_at': _iso,
      });
    }
    expect(session.remainingCheckpointMs(), 10000);
    expect(
      jsonDecode(storage.values['OURSPRIVACY_migrate_MOBILE_SESSION_V1']!),
      matchesObject({
        'sid': '$sessionStart',
        'startedAtMs': sessionStart,
        'lastActiveAtMs': sessionStart,
        'firstOpenSent': true,
        'sessionStartSent': true,
        'foregroundDurationMs': 0,
      }),
    );
    expect((await session.pendingQueueFacts())[0].toJson(), pending);
  });

  for (final osName in ['iOS', 'Android']) {
    test('leaves an unversioned persisted $osName event unchanged', () async {
      final item = <String, Object?>{
        'event': 'appointment_booked',
        'distinct_id': 'precontract-event',
        'visitor_id': 'captured-visitor',
        'userProperties': {'external_id': 'synthetic-patient'},
        'eventProperties': {'appointment_id': 'synthetic-appointment'},
        'defaultProperties': {
          'sid': 'old-uuid',
          'os_name': osName,
          'version': 'react-native@4.0.0',
        },
      };
      final client = sdk.create();
      await client.init(
        'precontract',
        storage: SessionHookStorage({
          _queueKey('precontract'): jsonEncode([item]),
        }),
      );
      expect(sdk.queue(client, 'precontract'), [item]);
      sdk.mockResponse(_serverAck);
      await client.flush();
      expect(sdk.bodies[0]['data'], [item]);
    });
  }

  for (final started in [null, '2026-10-05T11:59:55.000Z']) {
    test(
        'preserves a missing legacy occurrence when the captured start is $started',
        () async {
      final item = <String, Object?>{
        'event': 'appointment_booked',
        'distinct_id': 'missing-occurrence',
        'visitor_id': 'captured-visitor',
        'eventProperties': {'appointment_id': 'synthetic-appointment'},
        'defaultProperties': {
          'sid': 'old-uuid',
          'os_name': 'iOS',
          'mobile_contract_version': 1,
          if (started != null) 'mobile_session_started_at': started,
        },
      };
      final client = sdk.create();
      await client.init(
        'missing-occurrence',
        storage: SessionHookStorage({
          _queueKey('missing-occurrence'): jsonEncode([item]),
        }),
      );
      sdk.mockResponse(_serverAck);
      await client.flush();
      expect((sdk.bodies[0]['data']! as List)[0], {
        ...item,
        'defaultProperties': {
          'os_name': 'iOS',
          if (started != null) 'sid': '1791201595000',
        },
        'eventProperties': {
          'appointment_id': 'synthetic-appointment',
          'mobile_contract_version': 1,
        },
      });
    });
  }

  for (final shape in ['raw', 'indexed-envelope']) {
    test('normalizes a persisted $shape queue and accepts a legacy ACK',
        () async {
      final item = <String, Object?>{
        'event': 'appointment_booked',
        'distinct_id': 'stable-event',
        'visitor_id': 'captured-visitor',
        'userProperties': {
          'external_id': 'synthetic-patient',
          'custom_properties': {'healthcare': 'preserved'},
        },
        'eventProperties': {'appointment_id': 'synthetic-appointment'},
        'defaultProperties': {
          'sid': 'old-uuid',
          'os_name': 'iOS',
          'version': 'react-native@4.0.0',
          'mobile_session_started_at': _iso,
          'mobile_occurred_at': '2026-10-05T12:00:02.000Z',
          'mobile_platform': 'ios',
          'mobile_contract_version': 1,
          'app_version': '1.2',
          'app_build': '30',
        },
      };
      final Object stored = shape == 'raw'
          ? [item]
          : {
              'items': [item],
              'responseMode': 'indexed',
            };
      final client = sdk.create();
      await client.init(
        'old-queue',
        storage: SessionHookStorage({
          _queueKey('old-queue'): jsonEncode(stored),
        }),
        appVersion: '2.0',
        appBuild: '42',
      );
      sdk.mockResponse(_serverAck);
      await client.flush();
      expect(sdk.queue(client, 'old-queue'), isEmpty);
      expect((sdk.bodies[0]['data']! as List)[0], {
        ...item,
        'defaultProperties': {
          'sid': '$sessionStart',
          'os_name': 'iOS',
          'version': 'react-native@4.0.0',
        },
        'eventProperties': {
          'appointment_id': 'synthetic-appointment',
          'mobile_contract_version': 1,
          'mobile_occurred_at': '2026-10-05T12:00:02.000Z',
          'app_version': '1.2',
          'app_build': '30',
        },
      });
      expect(client.getVisitorId(), isNot('server-visitor'));
    });
  }

  for (final started in [
    'bad',
    '2026-02-30T12:00:00.000Z',
    '1970-01-01T00:00:00.000Z',
    '2026-10-05',
  ]) {
    test('does not derive a session ID from invalid start $started', () async {
      final item = <String, Object?>{
        'event': 'stored',
        'distinct_id': 'invalid-start',
        'visitor_id': 'old-visitor',
        'eventProperties': {'appointment_id': 'synthetic-appointment'},
        'userProperties': {'external_id': 'synthetic-patient'},
        'defaultProperties': {
          'os_name': 'Android',
          'sid': 'old-uuid',
          'mobile_session_started_at': started,
          'mobile_occurred_at': _iso,
        },
      };
      final client = sdk.create();
      await client.init(
        'invalid-start',
        storage: SessionHookStorage({
          _queueKey('invalid-start'): jsonEncode([item]),
        }),
      );
      sdk.mockResponse(_serverAck);
      await client.flush();
      final sent = (sdk.bodies[0]['data']! as List)[0] as Map;
      expect(sent['defaultProperties'], {'os_name': 'Android'});
      expect(
        sent,
        matchesObject({
          'distinct_id': 'invalid-start',
          'visitor_id': 'old-visitor',
          'userProperties': {'external_id': 'synthetic-patient'},
          'eventProperties': {
            'appointment_id': 'synthetic-appointment',
            'mobile_occurred_at': _iso,
            'mobile_contract_version': 1,
          },
        }),
      );
      expect(sdk.queue(client, 'invalid-start'), isEmpty);
    });
  }

  test(
      'normalizes pending facts with their captured version, occurrence and identity mode',
      () async {
    final pending = <String, Object?>{
      'id': 'pending-fact',
      'visitorId': 'pending-visitor',
      'isManuallySetId': false,
      'appVersion': '1.0',
      'appBuild': '20',
      'fact': {
        'event': r'$mobile_screen_view',
        'eventProperties': {'screen_name': 'Schedule'},
        'defaultProperties': {
          'sid': 'old-uuid',
          'mobile_session_started_at': _iso,
          'mobile_occurred_at': '2026-10-05T12:00:01.000Z',
        },
      },
    };
    final client = sdk.create();
    await client.init(
      'pending',
      storage: SessionHookStorage({
        'OURSPRIVACY_pending_MOBILE_SESSION_V1': jsonEncode({
          'firstOpenSent': true,
          'pendingEvents': [pending],
        }),
      }),
      appVersion: '2.0',
      visitorId: 'new-visitor',
    );
    sdk.mockResponse(_serverAck);
    await client.flush();
    expect(sdk.bodies[0]['is_manually_set_id'], isFalse);
    final sent = (sdk.bodies[0]['data']! as List)[0] as Map;
    expect(
      sent,
      matchesObject({
        'distinct_id': 'pending-fact',
        'visitor_id': 'pending-visitor',
        'defaultProperties': {'sid': '$sessionStart'},
        'eventProperties': {
          'screen_name': 'Schedule',
          'mobile_contract_version': 1,
          'mobile_occurred_at': '2026-10-05T12:00:01.000Z',
          'app_version': '1.0',
          'app_build': '20',
        },
        'userProperties': null,
      }),
    );
    expect(
      (sent['defaultProperties']! as Map)
          .containsKey('mobile_session_started_at'),
      isFalse,
    );
  });

  test(
      'flushes captured visitors and identity modes separately while retaining patient identity',
      () async {
    final client = sdk.create();
    await client.init('mixed', storage: SessionHookStorage());
    final original = client.getVisitorId();
    unawaited(client.track(
        'before', <String, Object?>{}, {'externalId': 'synthetic-patient'}));
    await client.setVisitorId(original!);
    unawaited(client.track('same-visitor-manual', <String, Object?>{},
        {'externalId': 'synthetic-patient'}));
    await client.setVisitorId('second-visitor');
    unawaited(client.track(
        'after', <String, Object?>{}, {'externalId': 'synthetic-patient'}));
    await settle();
    sdk.mockResponse(_serverAck);
    await client.flush();
    expect(
      [
        for (final body in sdk.bodies)
          {
            'mode': body['is_manually_set_id'],
            'visitors': [
              for (final event in body['data']! as List)
                (event as Map)['visitor_id'],
            ],
            'patients': [
              for (final event in body['data']! as List)
                ((event as Map)['userProperties']! as Map)['external_id'],
            ],
          },
      ],
      [
        {
          'mode': false,
          'visitors': [original],
          'patients': ['synthetic-patient'],
        },
        {
          'mode': true,
          'visitors': [original],
          'patients': ['synthetic-patient'],
        },
        {
          'mode': true,
          'visitors': ['second-visitor'],
          'patients': ['synthetic-patient'],
        },
      ],
    );
    expect(client.getVisitorId(), 'second-visitor');
  });

  test(
      'uses stored SDK defaults over caller metadata when migrating legacy events',
      () async {
    final item = <String, Object?>{
      'event': 'manual',
      'distinct_id': 'legacy-collision',
      'visitor_id': 'original',
      'eventProperties': {
        'mobile_occurred_at': 'caller-time',
        'app_version': 'caller-version',
      },
      'defaultProperties': {
        'os_name': 'iOS',
        'sid': '1791201599000',
        'mobile_session_started_at': _iso,
        'mobile_occurred_at': _iso,
        'app_version': '1.0',
      },
    };
    final client = sdk.create();
    await client.init(
      'collision',
      storage: SessionHookStorage({
        _queueKey('collision'): jsonEncode([item]),
      }),
    );
    expect(
      sdk.queue(client, 'collision')[0],
      matchesObject({
        'defaultProperties': {'sid': '1791201599000'},
        'eventProperties': {'mobile_occurred_at': _iso, 'app_version': '1.0'},
      }),
    );
  });

  for (final markers in <Map<String, Object?>>[
    {'mobile_contract_version': 1},
    {'mobile_platform': 'ios'},
    {'mobile_session_started_at': _iso},
  ]) {
    test(
        'omits absent SDK host metadata when migrating old wire markers ${jsonEncode(markers)}',
        () async {
      final item = <String, Object?>{
        'event': 'manual',
        'distinct_id': 'legacy-no-host',
        'visitor_id': 'captured-visitor',
        'eventProperties': {
          'appointment_id': 'synthetic-appointment',
          'mobile_contract_version': 9,
          'mobile_occurred_at': 'caller-time',
          'app_version': 'caller-release',
          'app_build': 'caller-build',
        },
        'defaultProperties': {
          'os_name': 'iOS',
          'sid': '$sessionStart',
          'mobile_occurred_at': _iso,
          ...markers,
        },
      };
      final client = sdk.create();
      await client.init(
        'legacy-no-host',
        storage: SessionHookStorage({
          _queueKey('legacy-no-host'): jsonEncode([item]),
        }),
        appVersion: 'current-release',
        appBuild: 'current-build',
      );
      sdk.mockResponse(_serverAck);
      await client.flush();
      expect((sdk.bodies[0]['data']! as List)[0], {
        ...item,
        'defaultProperties': {'os_name': 'iOS', 'sid': '$sessionStart'},
        'eventProperties': {
          'appointment_id': 'synthetic-appointment',
          'mobile_contract_version': 1,
          'mobile_occurred_at': _iso,
        },
      });
    });
  }

  test(
      'preserves current event-properties metadata through queue hydration and upload',
      () async {
    final item = <String, Object?>{
      'event': 'manual',
      'distinct_id': 'current-metadata',
      'visitor_id': 'captured-visitor',
      'eventProperties': {
        'appointment_id': 'synthetic-appointment',
        'mobile_contract_version': 1,
        'mobile_occurred_at': '2026-10-05T11:59:59.000Z',
        'app_version': 'captured-release',
        'app_build': 'captured-build',
      },
      'defaultProperties': {
        'os_name': 'iOS',
        'sid': '1791201595000',
        'version': 'react-native@4.1.0',
      },
    };
    final client = sdk.create();
    await client.init(
      'current-metadata',
      storage: SessionHookStorage({
        _queueKey('current-metadata'): jsonEncode([item]),
      }),
      appVersion: 'current-release',
      appBuild: 'current-build',
    );
    expect(sdk.queue(client, 'current-metadata'), [item]);
    sdk.mockResponse(_serverAck);
    await client.flush();
    expect(sdk.bodies[0]['data'], [item]);
  });

  test('preserves pending fact metadata stored inside the fact', () async {
    final pending = <String, Object?>{
      'id': 'stored-fact',
      'visitorId': 'original',
      'fact': {
        'event': r'$mobile_screen_view',
        'eventProperties': {'screen_name': 'Schedule'},
        'defaultProperties': {
          'sid': 'old-uuid',
          'mobile_session_started_at': _iso,
          'mobile_occurred_at': _iso,
          'app_version': '1.0',
          'app_build': '20',
        },
      },
    };
    final client = sdk.create();
    await client.init(
      'fact-metadata',
      storage: SessionHookStorage({
        'OURSPRIVACY_fact-metadata_MOBILE_SESSION_V1': jsonEncode({
          'firstOpenSent': true,
          'pendingEvents': [pending],
        }),
      }),
      appVersion: '2.0',
    );
    expect(
      sdk.queue(client, 'fact-metadata')[0],
      matchesObject({
        'eventProperties': {
          'app_version': '1.0',
          'app_build': '20',
          'mobile_occurred_at': _iso,
        },
      }),
    );
  });

  test(
      'retains captured identity modes across restart alongside older items with the baseline mode',
      () async {
    final storage = SessionHookStorage();
    final client = sdk.create();
    await client.init('restart-mode', storage: storage);
    final visitor = client.getVisitorId()!;
    unawaited(client.track('anonymous'));
    await client.setVisitorId(visitor);
    unawaited(client.track('manual'));
    await settle();
    final stored =
        jsonDecode(storage.values[_queueKey('restart-mode')]!) as List<Object?>;
    stored.add({
      'event': 'older',
      'distinct_id': 'older-id',
      'visitor_id': visitor,
      'userProperties': {'external_id': 'synthetic-patient'},
    });
    storage.values[_queueKey('restart-mode')] = jsonEncode(stored);
    await sdk.restart();
    final reloaded = sdk.create();
    await reloaded.init(
      'restart-mode',
      storage: storage,
      visitorId: visitor,
    );
    sdk.mockResponse(_serverAck);
    await reloaded.flush();
    expect(
      [
        for (final body in sdk.bodies)
          {
            'mode': body['is_manually_set_id'],
            'events': [
              for (final event in body['data']! as List)
                (event as Map)['event'],
            ],
          },
      ],
      [
        {
          'mode': false,
          'events': ['anonymous'],
        },
        {
          'mode': true,
          'events': ['manual', 'older'],
        },
      ],
    );
    expect(
      (((sdk.bodies[1]['data']! as List)[1] as Map)['userProperties']!
          as Map)['external_id'],
      'synthetic-patient',
    );
  });

  test(
      'discards nonnumeric stored session times while preserving first-open history',
      () async {
    final session = MobileSession(
      token: 'invalid-time',
      storage: SessionMapStorage({
        'OURSPRIVACY_invalid-time_MOBILE_SESSION_V1': jsonEncode({
          'sid': 'old-uuid',
          'startedAtMs': '1791201595000',
          'lastActiveAtMs': sessionStart,
          'firstOpenSent': true,
          'sessionStartSent': true,
        }),
      }),
      wallNow: () => sessionStart,
      monotonicNow: () => 0,
    );
    final facts = await session.foreground(automaticEnabled: true);
    expect(eventNames(facts), [
      r'$mobile_app_open',
      r'$mobile_session_start',
    ]);
    expect(facts[0].defaultProperties['sid'], '$sessionStart');
  });

  test(
      'keeps the captured batch queued if opt-out occurs before its ACK is processed',
      () async {
    final client = sdk.create();
    await client.init('ack-consent', storage: SessionHookStorage());
    await client.track('queued');
    await settle();
    final before = sdk.queue(client, 'ack-consent');
    sdk.respond = (_) async {
      oursPrivacyImplOf(client)!.persistent.updateOptedOut('ack-consent', true);
      return http.Response(jsonEncode(_serverAck), 200);
    };
    await client.flush();
    expect(sdk.queue(client, 'ack-consent'), before);
    expect(client.hasOptedOutTracking(), isTrue);
    expect(client.getVisitorId(), before[0]['visitor_id']);
  });
}
