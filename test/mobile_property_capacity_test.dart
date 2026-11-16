// Port of __tests__/mobile-property-capacity.test.js (React Native SDK).
//
// Ingest accepts at most 200 eventProperties keys and less than 1 MiB of
// serialized eventProperties. SDK mobile metadata is added only when it
// still fits; the caller's own properties are never dropped.
//
// Mapping of the Jest setup: see mobile_contract_test.dart. In addition,
// `jest.spyOn(console, 'warn')` -> `oursPrivacyLogSink`, counting
// warning-level lines (the sink receives every level regardless of
// `setLoggingEnabled`, so debug lines are filtered by level, as RN's spies
// on console.info / console.log are separate from console.warn).
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:ours_privacy/src/constants.dart';
import 'package:ours_privacy/src/testing.dart';
import 'package:ours_privacy/src/version.dart';

import 'helpers/session_harness.dart';

const String _iso = sessionIso;

Map<String, Object?> _propertiesFor(int count) => {
      for (var index = 0; index < count; index++)
        'property_$index': 'value-$index',
    };

/// RN `acceptWithinPropertyLimit()`.
void _acceptWithinPropertyLimit(SessionSdk sdk) {
  sdk.respond = (request) async {
    final data =
        (jsonDecode(request.body) as Map<String, Object?>)['data']! as List;
    final valid = data.every((item) {
      final properties = ((item as Map)['eventProperties'] as Map?) ??
          const <String, Object?>{};
      return properties.length <= 200 &&
          jsonEncode(properties).length < 1048576;
    });
    return http.Response(
      jsonEncode({'success': valid, 'visitor_id': 'server-visitor'}),
      valid ? 200 : 400,
    );
  };
}

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

  for (final (count, host, expectedCount, includesMetadata) in [
    (196, {'appVersion': '2.0', 'appBuild': '42'}, 200, true),
    (197, {'appVersion': '2.0', 'appBuild': '42'}, 197, false),
    (197, {'appVersion': '2.0'}, 197, false),
    (198, {'appVersion': '2.0'}, 198, false),
    (198, <String, String>{}, 198, false),
    (199, <String, String>{}, 199, false),
  ]) {
    test(
        'preserves $count ordinary properties with host metadata ${jsonEncode(host)} as $expectedCount properties',
        () async {
      final client = sdk.create();
      await client.init(
        'boundary',
        storage: SessionHookStorage(),
        appVersion: host['appVersion'],
        appBuild: host['appBuild'],
      );
      final properties = _propertiesFor(count);
      await client.track('manual', {
        ...properties,
        'mobile_contract_version': 9,
        'mobile_occurred_at': 'caller-time',
        'app_version': 'caller-release',
        'app_build': 'caller-build',
      });
      await settle();
      final event = sdk.queue(client, 'boundary')[0];
      expect(
        event['eventProperties'],
        includesMetadata
            ? {
                ...properties,
                'mobile_contract_version': 1,
                'mobile_occurred_at': _iso,
                if (host['appVersion'] != null)
                  'app_version': host['appVersion'],
                if (host['appBuild'] != null) 'app_build': host['appBuild'],
              }
            : properties,
      );
      expect((event['eventProperties']! as Map).keys, hasLength(expectedCount));
      expect(
        event['defaultProperties'],
        matchesObject({
          'sid': '$sessionStart',
          'os_name': 'iOS',
          'version': oursPrivacyLibraryVersion,
        }),
      );
    });
  }

  test('uploads a 200-property event and its following event with a legacy ACK',
      () async {
    final client = sdk.create();
    await client.init(
      'full-bag',
      storage: SessionHookStorage(),
      appVersion: '2.0',
      appBuild: '42',
    );
    final properties = _propertiesFor(200);
    unawaited(client.track(
      'full',
      properties,
      {'externalId': 'synthetic-patient'},
    ));
    unawaited(client.track('following', {'action': 'submitted'}));
    await settle();
    _acceptWithinPropertyLimit(sdk);
    await client.flush();

    expect(sdk.queue(client, 'full-bag'), isEmpty);
    final events = sdk.sentEvents;
    expect(eventNames(events), ['full', 'following']);
    expect(events[0]['eventProperties'], properties);
    expect(events[0]['userProperties'], {'external_id': 'synthetic-patient'});
    expect(
      (events[0]['defaultProperties']! as Map)['sid'],
      '$sessionStart',
    );
    expect(events[1]['eventProperties'], {
      'action': 'submitted',
      'mobile_contract_version': 1,
      'mobile_occurred_at': _iso,
      'app_version': '2.0',
      'app_build': '42',
    });
  });

  test(
      'preserves a caller bag just below 1 MiB and uploads its following event',
      () async {
    final client = sdk.create();
    await client.init(
      'size-boundary',
      storage: SessionHookStorage(),
      appVersion: '2.0',
      appBuild: '42',
    );
    final properties = <String, Object?>{'text': 'a' * 1048564};
    expect(jsonEncode(properties), hasLength(1048575));
    expect(
      jsonEncode({
        ...properties,
        'mobile_contract_version': 1,
        'mobile_occurred_at': _iso,
        'app_version': '2.0',
        'app_build': '42',
      }).length,
      greaterThanOrEqualTo(1048576),
    );
    unawaited(client.track('near-size-limit', properties));
    unawaited(client.track('following', {'action': 'submitted'}));
    await settle();
    _acceptWithinPropertyLimit(sdk);
    await client.flush();

    expect(sdk.queue(client, 'size-boundary').length, 0);
    final events = sdk.sentEvents;
    expect(eventNames(events), ['near-size-limit', 'following']);
    expect((events[0]['eventProperties']! as Map).keys.toList(), ['text']);
    expect(jsonEncode(events[0]['eventProperties']), hasLength(1048575));
    expect(
      (events[0]['eventProperties']! as Map)['text'] == properties['text'],
      isTrue,
    );
    expect(
      events[0]['defaultProperties'],
      matchesObject({'sid': '$sessionStart', 'os_name': 'iOS'}),
    );
    expect(events[1]['eventProperties'], {
      'action': 'submitted',
      'mobile_contract_version': 1,
      'mobile_occurred_at': _iso,
      'app_version': '2.0',
      'app_build': '42',
    });
  });

  for (final layout in ['legacy-defaults', 'current-event-properties']) {
    test(
        'normalizes a full persisted $layout event without blocking the following event',
        () async {
      final properties = _propertiesFor(200);
      const commonMetadata = <String, Object?>{
        'mobile_contract_version': 1,
        'mobile_occurred_at': '2026-10-05T11:59:59.000Z',
        'app_version': 'captured-release',
        'app_build': 'captured-build',
      };
      const defaults = <String, Object?>{
        'sid': '1791201595000',
        'os_name': 'iOS',
        'version': 'react-native@4.1.0',
      };
      final item = <String, Object?>{
        'event': 'stored',
        'distinct_id': 'stable-event',
        'visitor_id': 'captured-visitor',
        'userProperties': {
          'external_id': 'synthetic-patient',
          'custom_properties': {'healthcare': 'preserved'},
        },
        'eventProperties': layout == 'legacy-defaults'
            ? properties
            : {...properties, ...commonMetadata},
        'defaultProperties': layout == 'legacy-defaults'
            ? {
                ...defaults,
                ...commonMetadata,
                'sid': 'old-uuid',
                'mobile_platform': 'ios',
                'mobile_session_started_at': '2026-10-05T11:59:55.000Z',
              }
            : defaults,
      };
      final client = sdk.create();
      await client.init(
        'stored-full-bag',
        storage: SessionHookStorage({
          queueKey('stored-full-bag', eventsQueueType): jsonEncode([item]),
        }),
        visitorId: 'captured-visitor',
        appVersion: '2.0',
        appBuild: '42',
      );
      expect(sdk.queue(client, 'stored-full-bag'), [
        {...item, 'eventProperties': properties, 'defaultProperties': defaults},
      ]);
      unawaited(client.track('following', {'action': 'submitted'}));
      await settle();
      _acceptWithinPropertyLimit(sdk);
      await client.flush();

      expect(sdk.queue(client, 'stored-full-bag'), isEmpty);
      final events = sdk.sentEvents;
      expect(eventNames(events), ['stored', 'following']);
      expect(events[0], {
        ...item,
        'eventProperties': properties,
        'defaultProperties': defaults,
      });
      expect(
        (events[1]['eventProperties']! as Map)['mobile_contract_version'],
        1,
      );
      expect(client.getVisitorId(), 'captured-visitor');
    });
  }

  test(
      'retains canonical and identify metadata with a full default property bag',
      () async {
    final client = sdk.create();
    await client.init(
      'canonical-capacity',
      storage: SessionHookStorage(),
      appVersion: '2.0',
      appBuild: '42',
      defaultEventProperties: _propertiesFor(200),
      trackAutomaticEvents: true,
    );
    unawaited(client.trackScreen('Schedule'));
    await client.identify({'externalId': 'synthetic-patient'});
    await settle();
    final events = sdk.queue(client, 'canonical-capacity');
    expect(eventNames(events), [
      r'$mobile_first_open',
      r'$mobile_app_open',
      r'$mobile_session_start',
      r'$mobile_screen_view',
      r'$identify',
    ]);
    for (final event in events) {
      final properties = event['eventProperties']! as Map;
      expect(
        properties,
        matchesObject({
          'mobile_contract_version': 1,
          'mobile_occurred_at': _iso,
          'app_version': '2.0',
          'app_build': '42',
        }),
      );
      expect(properties.containsKey('property_0'), isFalse);
      expect(properties.length, lessThanOrEqualTo(5));
    }
  });

  test('warns about metadata omission without event names, IDs, or properties',
      () async {
    // RN's console.warn spy sees only warnings, not the info / debug lines
    // (separately mocked console.info / console.log).
    final warnings = <String>[];
    final originalDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {};
    addTearDown(() => debugPrint = originalDebugPrint);
    oursPrivacyLogSink = (level, message) {
      if (level == OursPrivacyLogLevel.warning) warnings.add(message);
    };
    final client = sdk.create();
    await client.init(
      'synthetic-token',
      storage: SessionHookStorage(),
      visitorId: 'synthetic-visitor',
      appVersion: '2.0',
      appBuild: '42',
    );
    client.setLoggingEnabled(true);
    unawaited(client.track('synthetic-event', _propertiesFor(200)));
    await settle();

    expect(
      (sdk.queue(client, 'synthetic-token')[0]['eventProperties']! as Map)
          .containsKey('mobile_contract_version'),
      isFalse,
    );
    expect(warnings, hasLength(1));
    final message = warnings[0];
    expect(message,
        matches(RegExp('mobile.*metadata.*omitted', caseSensitive: false)));
    expect(
      message,
      isNot(matches(RegExp(
          'synthetic-token|synthetic-visitor|synthetic-event|property_0|value-0'))),
    );
  });
}
