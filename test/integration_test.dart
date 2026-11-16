// Port of __tests__/integration.test.js (React Native SDK): end-to-end flows
// through the public facade, the real modules, in-memory storage and a
// mocked HTTP client.
//
// Jest equivalents (see test/helpers/facade_harness.dart):
// - `OursPrivacyQueueManager.getQueue(token, EVENTS)` -> [FacadeHarness.queue]
// - `op.oursprivacyImpl` -> [FacadeHarness.impl]
// - `jest.advanceTimersByTimeAsync(ms)` -> `h.clock.advance(ms)`
// - `jest.setSystemTime(Date.now() + 1)` -> `h.clock.shiftWallClock(1)`
// - `jest.resetModules()` (process restart) -> `h.restart()`; storage the
//   test owns survives, and the relaunched app is in the foreground again
//   (RN's freshly required AppState mock reports 'active').
// - `appState.handler('active' | 'inactive' | 'background')` -> [appState],
//   which delivers `resumed` / `inactive` / `paused` to the SDK's lifecycle
//   source and lets the serialized handler run. Like the React Native tests,
//   these drive single-step transitions; the Flutter state machine treats
//   `paused` from `resumed` exactly as React Native treats `background`.
// - `fetchMock` -> [FacadeHarness.respond] / [FacadeHarness.respondOnce] and
//   [FacadeHarness.requests].
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:ours_privacy/ours_privacy.dart';
import 'package:ours_privacy/src/constants.dart';
import 'package:ours_privacy/src/queue.dart';
import 'package:ours_privacy/src/testing.dart';
import 'package:ours_privacy/src/version.dart';

import 'helpers/facade_harness.dart';

late FacadeHarness h;

/// RN `appState.handler(state)` (awaited).
Future<void> appState(String rnState) async {
  h.appState.emit(switch (rnState) {
    'active' => OursAppState.resumed,
    'inactive' => OursAppState.inactive,
    'background' => OursAppState.paused,
    _ => throw ArgumentError.value(rnState, 'rnState'),
  });
  await facadeSettle();
}

/// After [FacadeHarness.restart]: the relaunched app starts in the
/// foreground, like the fresh AppState mock React Native gets.
void relaunchInForeground() => h.appState.currentState = OursAppState.resumed;

Matcher throwsMessage(String message) =>
    throwsA(predicate((Object? error) => '$error'.contains(message)));

List<Map<String, Object?>> withEvent(
  List<Map<String, Object?>> items,
  String event,
) =>
    items.where((item) => item['event'] == event).toList();

int countOf(List<Map<String, Object?>> items, String event) =>
    withEvent(items, event).length;

Object? sidOf(Map<String, Object?> item) => defaultPropsOf(item)['sid'];

List<Object?> engagementDurations(List<Map<String, Object?>> items) => [
      for (final item in withEvent(items, r'$mobile_session_engagement'))
        eventPropsOf(item)['engagement_duration_ms'],
    ];

/// A responder whose request never completes (the upload stays in flight).
Future<http.Response> holdResponse(http.Request request) =>
    Completer<http.Response>().future;

bool hasPendingEvents(String value, int length) {
  final pending = (jsonDecode(value) as Map)['pendingEvents'];
  return pending is List && pending.length == length;
}

void main() {
  setUp(() => h = FacadeHarness());
  tearDown(() => h.dispose());

  test(
      'stitches the initial link before queuing the first mobile open and a '
      'manual event', () async {
    final op = h.create();
    await op.init(
      'mobile-token',
      storage: InMemoryStorage(),
      initialURL:
          'myapp://open?ours_visitor_id=web-123&utm_source=email&gclid=click-123&patient_email=private%40example.test',
      trackAutomaticEvents: true,
      appVersion: '2.0.0',
      appBuild: '42',
    );
    await h.impl(op).track('mobile-token', 'appointment_booked', {
      'appointment_id': 'appointment-1',
    });

    final queued = h.queue(op);
    expect(facadeEventNames(queued), [
      r'$deep_link_opened',
      r'$mobile_first_open',
      r'$mobile_app_open',
      r'$mobile_session_start',
      'appointment_booked',
    ]);
    final first = queued[1];
    final deepLink = queued[0];
    final booked = queued[4];
    expect(eventPropsOf(deepLink), {
      'mobile_contract_version': 1,
      'mobile_occurred_at': isA<String>(),
      'app_version': '2.0.0',
      'app_build': '42',
    });
    expect(deepLink['visitor_id'], 'web-123');
    expect(
      defaultPropsOf(deepLink),
      allOf(
        containsPair('utm_source', 'email'),
        containsPair('gclid', 'click-123'),
      ),
    );
    expect(jsonEncode(deepLink), isNot(contains('patient_email')));
    expect(jsonEncode(deepLink), isNot(contains('myapp://open')));
    final logs = jsonEncode([...h.logs, ...h.printed]);
    expect(logs, isNot(contains('patient_email')));
    expect(logs, isNot(contains('myapp://open')));
    expect(first['visitor_id'], 'web-123');
    expect(
      defaultPropsOf(booked),
      allOf(
        containsPair('utm_source', 'email'),
        containsPair('gclid', 'click-123'),
        containsPair('sid', sidOf(first)),
        containsPair('version', 'flutter@$oursPrivacySdkVersion'),
      ),
    );
    expect(booked.containsKey('time'), isFalse);
    expect(
      queued.map((event) => event['distinct_id']).toSet(),
      hasLength(queued.length),
    );
  });

  test(
      'ignores reserved manual facts through both entry points without '
      'consuming first-open', () async {
    const token = 'reserved-token';
    h.suspendPeriodicNetworkFlush(token);
    final storage = FacadeStorage();
    final op = h.create();
    await op.init(token, storage: storage, trackAutomaticEvents: false);

    const callerProperties = {'patient_id': 'private-patient'};
    const callerUser = {'email': 'private@example.test'};
    await expectLater(
      op.track(r'$mobile_first_open', callerProperties, callerUser),
      completes,
    );
    await expectLater(
      h.impl(op).track(
            token,
            r'$mobile_screen_view',
            callerProperties,
            callerUser,
          ),
      completes,
    );
    expect(h.queue(op), isEmpty);

    await h.restart();
    h.suspendPeriodicNetworkFlush(token);
    final reloaded = h.create();
    await reloaded.init(token, storage: storage, trackAutomaticEvents: true);
    unawaited(reloaded.track('appointment_booked', {
      'appointment_id': 'booking-1',
    }));
    unawaited(reloaded.track(r'$ae_custom', {'source': 'legacy'}));
    await facadeSettle();
    final queued = h.queue(reloaded);
    expect(facadeEventNames(queued), [
      r'$mobile_first_open',
      r'$mobile_app_open',
      r'$mobile_session_start',
      'appointment_booked',
      r'$ae_custom',
    ]);
    expect(jsonEncode(queued), isNot(contains('private-patient')));
    expect(jsonEncode(queued), isNot(contains('private@example.test')));
    expect(eventPropsOf(queued[0]), {
      'mobile_contract_version': 1,
      'mobile_occurred_at': isA<String>(),
    });
    expect(queued[0]['userProperties'], isNull);
  });

  test('adds the same mobile contract fields to Android manual events',
      () async {
    h.device = const StaticDeviceInfo.android();
    final op = h.create();
    await op.init('android-token', storage: InMemoryStorage());
    await h.impl(op).track('android-token', 'appointment_booked');

    final booked = h.queue(op).first;
    expect(
      defaultPropsOf(booked),
      allOf(
        containsPair('sid', isA<String>()),
        containsPair('os_name', 'Android'),
        containsPair('version', 'flutter@$oursPrivacySdkVersion'),
      ),
    );
    expect(defaultPropsOf(booked).containsKey('app_version'), isFalse);
    expect(defaultPropsOf(booked).containsKey('app_build'), isFalse);
    expect(booked.containsKey('time'), isFalse);
  });

  test('adds Android metadata to automatic facts', () async {
    h.device = const StaticDeviceInfo.android();
    final op = h.create();
    await op.init(
      'android-auto-token',
      storage: InMemoryStorage(),
      trackAutomaticEvents: true,
    );

    final facts = h.queue(op);
    expect(facadeEventNames(facts), [
      r'$mobile_first_open',
      r'$mobile_app_open',
      r'$mobile_session_start',
    ]);
    for (final fact in facts) {
      expect(defaultPropsOf(fact), containsPair('sid', isA<String>()));
      expect(fact.containsKey('time'), isFalse);
    }
  });

  test('keeps automatic canonical facts free of caller and attribution data',
      () async {
    final op = h.create();
    await op.init(
      'privacy-token',
      storage: InMemoryStorage(),
      trackAutomaticEvents: true,
      initialURL:
          'myapp://open?utm_source=campaign&gclid=click-123&patient_email=private%40example.test',
      defaultEventProperties: {
        'patient_email': 'private@example.test',
        'idfa': 'ad-123',
        'gaid': 'ad-456',
        'idfv': 'device-123',
        'app_set_id': 'ad-789',
      },
      defaultUserCustomProperties: {'patient_id': 'patient-123'},
      defaultUserConsentProperties: {'patient_email': 'private@example.test'},
    );

    final queued = h.queue(op);
    final facts = queued
        .where((item) => (item['event']! as String).startsWith(r'$mobile_'))
        .toList();
    expect(facadeEventNames(facts), [
      r'$mobile_first_open',
      r'$mobile_app_open',
      r'$mobile_session_start',
    ]);
    for (final fact in facts) {
      expect(fact['userProperties'], isNull);
      expect(eventPropsOf(fact), {
        'mobile_contract_version': 1,
        'mobile_occurred_at': isA<String>(),
      });
      for (final key in [
        'patient_email',
        'patient_id',
        'idfa',
        'gaid',
        'idfv',
        'app_set_id',
        'gclid',
        'utm_source',
      ]) {
        expect(defaultPropsOf(fact).containsKey(key), isFalse, reason: key);
      }
      final json = jsonEncode(fact);
      expect(json, isNot(contains('private@example.test')));
      expect(json, isNot(contains('ad-123')));
      expect(json, isNot(contains('ad-456')));
      expect(json, isNot(contains('ad-789')));
    }
  });

  test('keeps web events outside the mobile contract', () async {
    h.device = const StaticDeviceInfo.web();
    final op = h.create();
    await op.init(
      'web-token',
      storage: InMemoryStorage(),
      trackAutomaticEvents: true,
    );
    await h.impl(op).track('web-token', 'appointment_booked');

    final queued = h.queue(op);
    expect(facadeEventNames(queued), ['appointment_booked']);
    final defaults = defaultPropsOf(queued[0]);
    expect(defaults.containsKey('sid'), isFalse);
    expect(defaults.containsKey('mobile_contract_version'), isFalse);
    expect(defaults.containsKey('mobile_platform'), isFalse);
    h.respondOnce
        .add(facadeJson({'success': true, 'visitor_id': 'web-visitor'}));
    await h.impl(op).core.flush('web-token');
    expect(h.queue(op), isEmpty);
  });

  for (final platform in ['ios', 'android']) {
    test('acknowledges a WebSource token response on $platform', () async {
      h.device = platform == 'ios'
          ? const StaticDeviceInfo.ios()
          : const StaticDeviceInfo.android();
      final op = h.create();
      await op.init('legacy-token', storage: InMemoryStorage());
      await h.impl(op).track('legacy-token', 'appointment_booked');
      h.respondOnce
          .add(facadeJson({'success': true, 'visitor_id': 'web-visitor'}));

      await h.impl(op).core.flush('legacy-token');

      expect(h.queue(op), isEmpty);
    });
  }

  test('reports an indexed rejection from a mobile token while running on web',
      () async {
    h.device = const StaticDeviceInfo.web();
    final rejections = <OursPrivacyIngestRejection>[];
    final op = h.create();
    await op.init(
      'indexed-web-token',
      storage: InMemoryStorage(),
      onIngestRejected: rejections.add,
    );
    await h.impl(op).track('indexed-web-token', 'appointment_booked');
    final queued = h.queue(op);
    h.respondOnce.add(facadeJson({
      'success': true,
      'visitor_id': 'mobile-visitor',
      'accepted': 0,
      'rejected': [
        {'index': 0, 'code': 'mobile_session_required'},
      ],
    }));

    await h.impl(op).core.flush('indexed-web-token');

    expect(h.queue(op), isEmpty);
    expect(rejections, hasLength(1));
    expect(rejections.single.distinctId, queued[0]['distinct_id']);
    expect(rejections.single.code, 'mobile_session_required');
  });

  test('accepts a legacy ACK after an indexed ACK', () async {
    h.device = const StaticDeviceInfo.web();
    final rejections = <OursPrivacyIngestRejection>[];
    final op = h.create();
    await op.init(
      'indexed-then-legacy-token',
      storage: InMemoryStorage(),
      onIngestRejected: rejections.add,
    );
    op.setFlushBatchSize(1);
    await h.impl(op).track('indexed-then-legacy-token', 'first');
    await h.impl(op).track('indexed-then-legacy-token', 'appointment_booked');
    h.respondOnce.addAll([
      facadeJson({'success': true, 'accepted': 1, 'rejected': <Object?>[]}),
      facadeJson({'success': true, 'visitor_id': 'v1'}),
    ]);

    await h.impl(op).core.flush('indexed-then-legacy-token');

    expect(h.queue(op), isEmpty);
    expect(rejections, isEmpty);
  });

  test('accepts a legacy ACK after restarting with indexed response history',
      () async {
    const token = 'indexed-restart-token';
    h.device = const StaticDeviceInfo.web();
    final storage = FacadeStorage();
    final first = h.create();
    await first.init(token, storage: storage);
    await h.impl(first).track(token, 'first');
    h.respondOnce.add(
      facadeJson({'success': true, 'accepted': 1, 'rejected': <Object?>[]}),
    );
    await h.impl(first).core.flush(token);
    expect(
      (jsonDecode(storage.values[
              'OURSPRIVACY_indexed-restart-token_/ingest_QUEUE_METADATA_V1']!)
          as Map)['responseMode'],
      'indexed',
    );

    await h.restart();
    relaunchInForeground();
    final reloaded = h.create();
    await reloaded.init(token, storage: storage);
    final queueManager = h.impl(reloaded).core.queueManager;
    expect(
      queueManager.getResponseMode(token, eventsQueueType),
      OursPrivacyResponseMode.indexed,
    );
    await h.impl(reloaded).track(token, 'appointment_booked');
    final pending = h.queue(reloaded).single;
    h.requests.clear();
    h.respondOnce.add(facadeJson({'success': true, 'visitor_id': 'v1'}));

    await h.impl(reloaded).core.flush(token);
    expect(h.requests, hasLength(1));
    // RN: removeByIds(token, EVENTS, [pending.distinct_id], 'legacy').
    expect(
      h.sentEvents.map((item) => item['distinct_id']),
      [pending['distinct_id']],
    );
    expect(
      queueManager.getResponseMode(token, eventsQueueType),
      OursPrivacyResponseMode.legacy,
    );

    expect(h.queue(reloaded), isEmpty);
  });

  test(
      'discards a web queued event on permanent HTTP 400 before its token '
      'contract is known', () async {
    h.device = const StaticDeviceInfo.web();
    final op = h.create();
    await op.init('unknown-web-token', storage: InMemoryStorage());
    await h.impl(op).track('unknown-web-token', 'appointment_booked');
    h.respondOnce.add(facadeJson({'success': false}, 400));

    await h.impl(op).core.flush('unknown-web-token');

    expect(h.queue(op), isEmpty);
  });

  test('serializes overlapping flushes and acknowledges only the sent IDs',
      () async {
    final op = h.create();
    await op.init('flush-token', storage: InMemoryStorage());
    op.setFlushBatchSize(1);
    await h.impl(op).track('flush-token', 'first');
    await h.impl(op).track('flush-token', 'second');

    final firstGate = Completer<void>();
    final sent = <Object?>[];
    h.respond = (request) async {
      final body = jsonDecode(request.body) as Map<String, Object?>;
      final event = facadeMap((body['data']! as List)[0])['event'];
      sent.add(event);
      if (event == 'first') await firstGate.future;
      return http.Response(
        jsonEncode({'success': true, 'accepted': 1, 'rejected': <Object?>[]}),
        200,
      );
    };

    final firstFlush = h.impl(op).core.flush('flush-token');
    final secondFlush = h.impl(op).core.flush('flush-token');
    await facadeSettle();
    final callsWhileFirstPending = h.requests.length;
    firstGate.complete();
    await Future.wait([firstFlush, secondFlush]);
    await facadeSettle();

    expect(callsWhileFirstPending, 1);
    expect(sent, ['first', 'second']);
    expect(h.queue(op), isEmpty);
  });

  test(
      'does not remove a replacement event when an earlier send is '
      'acknowledged', () async {
    final op = h.create();
    await op.init('replacement-token', storage: InMemoryStorage());
    op.setFlushBatchSize(1);
    await h.impl(op).track('replacement-token', 'original');

    final originalGate = Completer<void>();
    final sent = <Object?>[];
    h.respond = (request) async {
      final body = jsonDecode(request.body) as Map<String, Object?>;
      final event = facadeMap((body['data']! as List)[0])['event'];
      sent.add(event);
      if (event == 'original') await originalGate.future;
      return http.Response(
        jsonEncode({'success': true, 'accepted': 1, 'rejected': <Object?>[]}),
        200,
      );
    };
    final flushing = h.impl(op).core.flush('replacement-token');
    await facadeSettle();
    await h
        .impl(op)
        .core
        .queueManager
        .clearQueue('replacement-token', eventsQueueType);
    await h.impl(op).track('replacement-token', 'replacement');
    originalGate.complete();
    await flushing;

    expect(sent, ['original', 'replacement']);
    expect(h.queue(op), isEmpty);
  });

  test(
      'discards a permanently rejected mobile event and uploads the following '
      'event', () async {
    final op = h.create();
    await op.init('bad-batch-token', storage: InMemoryStorage());
    op.setFlushBatchSize(1);
    await h.impl(op).track('bad-batch-token', 'invalid');
    await h.impl(op).track('bad-batch-token', 'valid');

    final sent = <Object?>[];
    h.respond = (request) async {
      final body = jsonDecode(request.body) as Map<String, Object?>;
      final event = facadeMap((body['data']! as List)[0])['event'];
      sent.add(event);
      return http.Response(
        jsonEncode({'success': event != 'invalid'}),
        event == 'invalid' ? 400 : 200,
      );
    };
    await h.impl(op).core.flush('bad-batch-token');

    expect(sent, ['invalid', 'valid']);
    expect(h.queue(op), isEmpty);
  });

  test(
      'waits for a real queue storage write before reporting a mobile '
      'rejection', () async {
    const token = 'durable-rejection-token';
    var failQueueSave = false;
    final storage = FacadeStorage()
      ..onSet = (key, value) {
        if (key.endsWith('_QUEUE') && failQueueSave) {
          failQueueSave = false;
          throw StateError('queue write failed');
        }
      };
    final rejections = <OursPrivacyIngestRejection>[];
    final op = h.create();
    await op.init(token, storage: storage, onIngestRejected: rejections.add);
    await h.impl(op).track(token, 'appointment_booked');
    final queued = h.queue(op);
    final eventId = queued[0]['distinct_id'];
    h.respond = facadeJson({
      'success': true,
      'visitor_id': 'v1',
      'accepted': 0,
      'rejected': [
        {'index': 0, 'code': 'invalid_session'},
      ],
    });
    failQueueSave = true;

    await h.impl(op).core.flush(token);
    expect(rejections, isEmpty);
    expect(h.queue(op), queued);
    expect(
      facadePersistedQueueItems(
          storage.values[queueKey(token, eventsQueueType)]!),
      queued,
    );

    await h.impl(op).core.flush(token);
    expect(rejections, hasLength(1));
    expect(rejections.single.distinctId, eventId);
    expect(rejections.single.code, 'invalid_session');
    expect(h.queue(op), isEmpty);
    await h.impl(op).core.flush(token);
    expect(rejections, hasLength(1));
  });

  test('reports a rejected sent event without removing its queued replacement',
      () async {
    const token = 'rejected-replacement-token';
    final rejections = <OursPrivacyIngestRejection>[];
    final op = h.create();
    await op.init(
      token,
      storage: InMemoryStorage(),
      onIngestRejected: rejections.add,
    );
    op.setFlushBatchSize(1);
    await h.impl(op).track(token, 'original');
    final original = h.queue(op)[0];

    final originalGate = Completer<void>();
    h.respond = (request) async {
      final body = jsonDecode(request.body) as Map<String, Object?>;
      final event = facadeMap((body['data']! as List)[0])['event'];
      if (event == 'original') {
        await originalGate.future;
        return http.Response(
          jsonEncode({
            'success': true,
            'accepted': 0,
            'rejected': [
              {'index': 0, 'code': 'invalid_session'},
            ],
          }),
          200,
        );
      }
      return http.Response(
        jsonEncode({
          'success': false,
          'retryable': true,
          'accepted': 1,
          'rejected': <Object?>[],
        }),
        200,
      );
    };
    final flushing = h.impl(op).core.flush(token);
    await facadeSettle();
    await h.impl(op).core.queueManager.clearQueue(token, eventsQueueType);
    await h.impl(op).track(token, 'replacement');
    originalGate.complete();
    await flushing;
    final remaining = h.queue(op);

    expect(facadeEventNames(remaining), ['replacement']);
    expect(rejections, hasLength(1));
    expect(rejections.single.distinctId, original['distinct_id']);
    expect(rejections.single.code, 'invalid_session');
  });

  test(
      'processes AppState at arrival time while an earlier flush awaits the '
      'network', () async {
    const token = 'delayed-appstate-token';
    h.suspendPeriodicNetworkFlush(token);
    final op = h.create();
    await op.init(
      token,
      storage: InMemoryStorage(),
      trackAutomaticEvents: true,
    );
    op.setFlushOnBackground(false);
    unawaited(op.trackScreen('Schedule'));
    await facadeSettle();

    final releaseRequest = Completer<void>();
    h.respond = facadeIndexedSuccess;
    h.respondOnce.add((request) async {
      await releaseRequest.future;
      return facadeIndexedSuccess(request);
    });
    final flushing = op.flush();
    await h.waitForRequests(1);

    await h.clock.advance(5000);
    final background = appState('background');
    await h.clock.advance(15000);
    releaseRequest.complete();
    await flushing;
    await background;

    final queued = h.sentEvents;
    final engagement = withEvent(queued, r'$mobile_session_engagement').first;
    expect(
      eventPropsOf(engagement),
      allOf(
        containsPair('engagement_duration_ms', 5000),
        containsPair('screen_name', 'Schedule'),
      ),
    );
    expect(
      eventPropsOf(engagement)['mobile_occurred_at'],
      DateTime.fromMillisecondsSinceEpoch(
        int.parse(sidOf(engagement)! as String) + 5000,
        isUtc: true,
      ).toIso8601String(),
    );
  });

  test('sends a queued booking when flush is awaited before opt-out', () async {
    const token = 'flush-before-optout-token';
    h.suspendPeriodicNetworkFlush(token);
    h.respond = facadeIndexedSuccess;
    final op = h.create();
    await op.init(token, storage: InMemoryStorage());
    unawaited(op.track('appointment_booked', {
      'appointment_id': 'synthetic-booking',
    }));

    await op.flush();
    await op.optOutTracking();

    expect(h.requests, hasLength(1));
    final sent = h.bodies[0]['data']! as List<Object?>;
    expect(sent, hasLength(1));
    final item = facadeMap(sent.single);
    expect(item['event'], 'appointment_booked');
    expect(
      eventPropsOf(item),
      containsPair('appointment_id', 'synthetic-booking'),
    );
  });

  test(
      'handles AppState engagement and warm opens when background flushing is '
      'disabled', () async {
    const token = 'mobile-token';
    h.suspendPeriodicNetworkFlush(token);
    final op = h.create();
    await op.init(
      token,
      storage: InMemoryStorage(),
      trackAutomaticEvents: true,
    );
    op.setFlushOnBackground(false);

    await h.clock.advance(10000);
    await appState('background');
    await h.clock.advance(5000);
    await appState('active');

    final queued = h.queue(op);
    expect(countOf(queued, r'$mobile_app_open'), 2);
    expect(countOf(queued, r'$mobile_session_start'), 1);
    expect(
      engagementDurations(queued).cast<int>().fold<int>(0, (a, b) => a + b),
      10000,
    );
    expect(h.requests, isEmpty);
  });

  test(
      'checkpoints the remaining second after a warm foreground and then '
      'every ten seconds', () async {
    const token = 'warm-checkpoint-token';
    h.suspendPeriodicNetworkFlush(token);
    final op = h.create();
    await op.init(
      token,
      storage: InMemoryStorage(),
      trackAutomaticEvents: true,
    );
    op.setFlushOnBackground(false);

    await h.clock.advance(9000);
    await appState('background');
    await h.clock.advance(5000);
    await appState('active');
    await h.clock.advance(999);
    List<Map<String, Object?>> engagement() =>
        withEvent(h.queue(op), r'$mobile_session_engagement');
    expect(engagementDurations(h.queue(op)), [9000]);
    await h.clock.advance(1);
    expect(engagementDurations(h.queue(op)), [9000, 1000]);
    await h.clock.advance(10000);
    expect(engagementDurations(h.queue(op)), [9000, 1000, 10000]);
    await appState('background');
    expect(engagement(), hasLength(3));
    expect(engagement().map(sidOf).toSet(), hasLength(1));
  });

  test(
      'uses the persisted foreground total to schedule the first checkpoint '
      'after restart', () async {
    const token = 'restart-checkpoint-token';
    h.suspendPeriodicNetworkFlush(token);
    final storage = FacadeStorage();
    final first = h.create();
    await first.init(token, storage: storage, trackAutomaticEvents: true);
    first.setFlushOnBackground(false);
    await h.clock.advance(9000);
    await appState('background');

    await h.restart();
    relaunchInForeground();
    h.suspendPeriodicNetworkFlush(token);
    final reloaded = h.create();
    await reloaded.init(token, storage: storage, trackAutomaticEvents: true);
    List<Map<String, Object?>> engagement() =>
        withEvent(h.queue(reloaded), r'$mobile_session_engagement');
    await h.clock.advance(999);
    expect(engagementDurations(h.queue(reloaded)), [9000]);
    await h.clock.advance(1);
    expect(engagementDurations(h.queue(reloaded)), [9000, 1000]);
    expect(engagement().map(sidOf).toSet(), hasLength(1));
  });

  test(
      'pauses iOS engagement through inactive callbacks without opening '
      'again', () async {
    const token = 'inactive-token';
    h.suspendPeriodicNetworkFlush(token);
    final op = h.create();
    await op.init(
      token,
      storage: InMemoryStorage(),
      trackAutomaticEvents: true,
    );
    op.setFlushOnBackground(false);
    unawaited(op.trackScreen('Schedule'));
    await facadeSettle();
    await h.clock.advance(3000);
    await appState('inactive');
    await appState('inactive');
    unawaited(op.trackScreen('Confirm'));
    await facadeSettle();
    await h.clock.advance(20000);
    await appState('active');
    await appState('active');
    await h.clock.advance(2000);
    await appState('background');
    final queued = h.queue(op);
    expect(countOf(queued, r'$mobile_app_open'), 1);
    expect(countOf(queued, r'$mobile_session_start'), 1);
    final engagements = [
      for (final item in withEvent(queued, r'$mobile_session_engagement'))
        eventPropsOf(item),
    ];
    expect(engagements, [
      allOf(
        containsPair('engagement_duration_ms', 3000),
        containsPair('screen_name', 'Schedule'),
      ),
      allOf(
        containsPair('engagement_duration_ms', 2000),
        containsPair('screen_name', 'Confirm'),
      ),
    ]);
  });

  test('keeps the inactive pause as last activity when iOS enters background',
      () async {
    const token = 'inactive-background-token';
    h.suspendPeriodicNetworkFlush(token);
    final op = h.create();
    await op.init(
      token,
      storage: InMemoryStorage(),
      trackAutomaticEvents: true,
    );
    op.setFlushOnBackground(false);
    final firstSid = sidOf(h.queue(op)[0]);

    await h.clock.advance(3000);
    await appState('inactive');
    await h.clock.advance(29 * 60 * 1000);
    unawaited(op.trackScreen('Confirm'));
    await facadeSettle();
    await appState('background');
    await h.clock.advance(60 * 1000);
    await appState('active');

    final queued = h.queue(op);
    expect(engagementDurations(queued), [3000]);
    expect(countOf(queued, r'$mobile_app_open'), 2);
    expect(countOf(queued, r'$mobile_session_start'), 2);
    expect(sidOf(withEvent(queued, r'$mobile_app_open').last), isNot(firstSid));
  });

  test('does not resume an inactive session after opt-out', () async {
    const token = 'inactive-opt-out-token';
    final op = h.create();
    await op.init(
      token,
      storage: InMemoryStorage(),
      trackAutomaticEvents: true,
    );
    await h.clock.advance(3000);
    await appState('inactive');
    await op.optOutTracking();
    await h.clock.advance(20000);
    await appState('active');
    expect(h.queue(op), isEmpty);

    await op.optInTracking();
    await h.clock.advance(2000);
    // RN reads the queue right after the background handler, before the
    // background flush it starts has completed; keep that upload in flight.
    h.respond = holdResponse;
    await appState('background');
    final queued = h.queue(op);
    expect(countOf(queued, r'$mobile_app_open'), 1);
    expect(countOf(queued, r'$mobile_session_start'), 1);
    expect(engagementDurations(queued), [2000]);
  });

  test(
      'keeps automatic facts off while manual events get sessions, then '
      'starts fresh after opt-in', () async {
    const token = 'mobile-token';
    final op = h.create();
    await op.init(
      token,
      storage: InMemoryStorage(),
      trackAutomaticEvents: false,
    );
    await h.impl(op).track(token, 'appointment_booked');
    final before = h.queue(op);
    expect(facadeEventNames(before), ['appointment_booked']);
    expect(sidOf(before[0]), isA<String>());
    final oldSid = sidOf(before[0]);

    await h.impl(op).optOutTracking(token);
    await h.impl(op).track(token, 'while_opted_out');
    expect(h.queue(op), isEmpty);

    h.clock.shiftWallClock(1);
    await h.impl(op).optInTracking(token);
    await h.impl(op).track(token, 'after_opt_in');
    final after = h.queue(op);
    expect(facadeEventNames(after), [r'$opt_in', 'after_opt_in']);
    expect(sidOf(after[1]), isNot(oldSid));
  });

  test(
      'retries a first open with its original event ID when queue '
      'persistence fails', () async {
    const token = 'retry-token';
    Object? failedId;
    var failQueueWrite = true;
    final storage = FacadeStorage()
      ..onSet = (key, value) {
        if (key.endsWith('_QUEUE') && failQueueWrite) {
          failQueueWrite = false;
          failedId = facadePersistedQueueItems(value)[0]['distinct_id'];
          throw StateError('queue write failed');
        }
      };
    final op = h.create();

    await expectLater(
      op.init(token, storage: storage, trackAutomaticEvents: true),
      throwsMessage('queue write failed'),
    );
    expect(failedId, isA<String>());
    expect(h.queue(op), isEmpty);

    await h.impl(op).initialize(
          token,
          OursPrivacyInitOptions(storage: storage, trackAutomaticEvents: true),
        );
    final queued = h.queue(op);
    expect(facadeEventNames(queued), [
      r'$mobile_first_open',
      r'$mobile_app_open',
      r'$mobile_session_start',
    ]);
    expect(queued[0]['distinct_id'], failedId);
    expect(queued.map((event) => event['distinct_id']).toSet(), hasLength(3));
  });

  test(
      'keeps unqueued lifecycle facts for their original visitor across an '
      'identity change', () async {
    const token = 'identity-token';
    var failQueueWrite = true;
    final storage = FacadeStorage()
      ..onSet = (key, value) {
        if (key.endsWith('_QUEUE') && failQueueWrite) {
          failQueueWrite = false;
          throw StateError('queue write failed');
        }
      };
    final op = h.create();

    await expectLater(
      op.init(
        token,
        storage: storage,
        visitorId: 'visitor-before',
        trackAutomaticEvents: true,
      ),
      throwsMessage('queue write failed'),
    );
    h.clock.shiftWallClock(1);
    await op.setVisitorId('visitor-after');
    await h.impl(op).initialize(
          token,
          OursPrivacyInitOptions(storage: storage, trackAutomaticEvents: true),
        );

    final queued = h.queue(op);
    final first = withEvent(queued, r'$mobile_first_open').first;
    expect(first['visitor_id'], 'visitor-before');
    expect(countOf(queued, r'$mobile_first_open'), 1);
  });

  test('preserves full opt-out across a process restart', () async {
    const token = 'consent-token';
    final storage = FacadeStorage();
    final op = h.create();
    await op.init(token, storage: storage, trackAutomaticEvents: true);
    await h.impl(op).optOutTracking(token);

    await h.restart();
    relaunchInForeground();
    final reloaded = h.create();
    await reloaded.init(token, storage: storage, trackAutomaticEvents: true);
    await h.impl(reloaded).track(token, 'appointment_booked');

    expect(reloaded.hasOptedOutTracking(), isTrue);
    expect(h.queue(reloaded), isEmpty);
  });

  test('holds first-open until automatic tracking is opted in', () async {
    const token = 'first-opt-in-token';
    final op = h.create();
    await op.init(
      token,
      storage: InMemoryStorage(),
      optOutTrackingByDefault: true,
      trackAutomaticEvents: true,
    );
    await h.impl(op).track(token, 'while_opted_out');
    expect(h.queue(op), isEmpty);

    await h.impl(op).optInTracking(token);
    final queued = h.queue(op);
    expect(facadeEventNames(queued), [
      r'$mobile_first_open',
      r'$mobile_app_open',
      r'$mobile_session_start',
      r'$opt_in',
    ]);
    expect(queued.map(sidOf).toSet(), hasLength(1));
  });

  test(
      'keeps first-open eligible after an unqueued attempt is cleared by '
      'opt-out', () async {
    const token = 'failed-first-opt-token';
    var failQueueWrite = true;
    final storage = FacadeStorage()
      ..onSet = (key, value) {
        if (key.endsWith('_QUEUE') && failQueueWrite) {
          failQueueWrite = false;
          throw StateError('queue write failed');
        }
      };
    final op = h.create();

    await expectLater(
      op.init(token, storage: storage, trackAutomaticEvents: true),
      throwsMessage('queue write failed'),
    );
    await h.impl(op).optOutTracking(token);
    await h.impl(op).optInTracking(token);

    expect(countOf(h.queue(op), r'$mobile_first_open'), 1);
  });

  test('replays first-open after restart with its original ID and app version',
      () async {
    const token = 'restart-token';
    Object? failedId;
    var failQueueWrite = true;
    final storage = FacadeStorage()
      ..onSet = (key, value) {
        if (key.endsWith('_QUEUE') && failQueueWrite) {
          failQueueWrite = false;
          failedId = facadePersistedQueueItems(value)[0]['distinct_id'];
          throw StateError('queue write failed');
        }
      };
    final first = h.create();
    await expectLater(
      first.init(
        token,
        storage: storage,
        trackAutomaticEvents: true,
        appVersion: '1.0',
      ),
      throwsMessage('queue write failed'),
    );

    await h.restart();
    relaunchInForeground();
    final reloaded = h.create();
    await reloaded.init(
      token,
      storage: storage,
      trackAutomaticEvents: true,
      appVersion: '2.0',
    );
    final queued = h.queue(reloaded);
    final firstOpen = withEvent(queued, r'$mobile_first_open').first;
    final update = withEvent(queued, r'$mobile_app_update').first;
    expect(firstOpen['distinct_id'], failedId);
    expect(eventPropsOf(firstOpen)['app_version'], '1.0');
    expect(eventPropsOf(update)['app_version'], '2.0');
    expect(eventPropsOf(update)['previous_app_version'], '1.0');
    expect(countOf(queued, r'$mobile_first_open'), 1);
  });

  test('recovers initialization when the saved queue cannot be read', () async {
    final storage = FacadeStorage(persistWrites: false)
      ..onGet = (key) {
        if (key.endsWith('_QUEUE')) throw StateError('queue read failed');
      };
    final op = h.create();

    await op.init('queue-read-token', storage: storage);
    await op.track('after-recovery');
    expect(facadeEventNames(h.queue(op)), ['after-recovery']);
  });

  test(
      'does not duplicate a persisted first-open when its session '
      'acknowledgement fails', () async {
    const token = 'ack-token';
    var failAcknowledgement = true;
    final storage = FacadeStorage()
      ..onSet = (key, value) {
        if (key.contains('_MOBILE_SESSION_V1') &&
            hasPendingEvents(value, 2) &&
            failAcknowledgement) {
          failAcknowledgement = false;
          throw StateError('ack write failed');
        }
      };
    final op = h.create();

    await expectLater(
      op.init(token, storage: storage, trackAutomaticEvents: true),
      throwsMessage('ack write failed'),
    );
    final firstAttempt = h.queue(op);
    expect(facadeEventNames(firstAttempt), [r'$mobile_first_open']);

    await h.impl(op).initialize(
          token,
          OursPrivacyInitOptions(storage: storage, trackAutomaticEvents: true),
        );
    final queued = h.queue(op);
    expect(facadeEventNames(queued), [
      r'$mobile_first_open',
      r'$mobile_app_open',
      r'$mobile_session_start',
    ]);
    expect(queued[0]['distinct_id'], firstAttempt[0]['distinct_id']);
  });

  test(
      'does not repeat a sent first-open after its session acknowledgement '
      'fails and tracking is opted out', () async {
    const token = 'sent-first-token';
    var failAcknowledgement = true;
    final storage = FacadeStorage()
      ..onSet = (key, value) {
        if (key.contains('_MOBILE_SESSION_V1') &&
            hasPendingEvents(value, 2) &&
            failAcknowledgement) {
          failAcknowledgement = false;
          throw StateError('ack write failed');
        }
      };
    final op = h.create();
    await expectLater(
      op.init(token, storage: storage, trackAutomaticEvents: true),
      throwsMessage('ack write failed'),
    );
    h.respond = facadeIndexedSuccess;
    await h.impl(op).core.flush(token);
    await h.waitForRequests(1);
    expect(h.queue(op), isEmpty);

    await h.impl(op).optOutTracking(token);
    await h.impl(op).optInTracking(token);
    expect(countOf(h.queue(op), r'$mobile_first_open'), 0);
  });

  test('remembers queue acceptance across restart before opt-out', () async {
    const token = 'restart-accepted-token';
    var failAcknowledgement = true;
    final storage = FacadeStorage()
      ..onSet = (key, value) {
        if (key.contains('_MOBILE_SESSION_V1') &&
            hasPendingEvents(value, 2) &&
            failAcknowledgement) {
          failAcknowledgement = false;
          throw StateError('ack write failed');
        }
      };
    final first = h.create();
    await expectLater(
      first.init(token, storage: storage, trackAutomaticEvents: true),
      throwsMessage('ack write failed'),
    );
    h.respond = facadeIndexedSuccess;
    await h.impl(first).core.flush(token);

    await h.restart();
    relaunchInForeground();
    final reloaded = h.create();
    await reloaded.init(
      token,
      storage: storage,
      trackAutomaticEvents: true,
      optOutTrackingByDefault: true,
    );
    await reloaded.optInTracking();

    expect(countOf(h.queue(reloaded), r'$mobile_first_open'), 0);
  });

  test(
      'keeps a sent first-open consumed across a failed marker write, crash, '
      'opt-out, and opt-in', () async {
    const token = 'crash-accepted-token';
    var failMarker = true;
    final storage = FacadeStorage()
      ..onSet = (key, value) {
        if (!key.contains('_MOBILE_SESSION_V1') || !failMarker) return;
        final pending = (jsonDecode(value) as Map)['pendingEvents'];
        final accepted = pending is List &&
            pending.any((record) =>
                record is Map &&
                (record['fact'] as Map?)?['event'] == r'$mobile_first_open' &&
                record['queueAccepted'] == true);
        if (accepted) {
          failMarker = false;
          throw StateError('marker write failed');
        }
      };
    final first = h.create();
    await expectLater(
      first.init(token, storage: storage, trackAutomaticEvents: true),
      throwsMessage('marker write failed'),
    );
    final firstOpen = h.queue(first)[0];
    expect(firstOpen['event'], r'$mobile_first_open');
    h.respond = facadeIndexedSuccess;
    await h.impl(first).core.flush(token);
    expect(h.queue(first), isEmpty);

    await h.restart();
    relaunchInForeground();
    final reloaded = h.create();
    await reloaded.init(
      token,
      storage: storage,
      trackAutomaticEvents: true,
      optOutTrackingByDefault: true,
    );
    await reloaded.optInTracking();
    expect(withEvent(h.queue(reloaded), r'$mobile_first_open'), isEmpty);
  });

  test(
      'restores first-open eligibility across a failed queue write, crash, '
      'opt-out, and opt-in', () async {
    const token = 'crash-unaccepted-token';
    Object? failedId;
    var failQueue = true;
    final storage = FacadeStorage()
      ..onSet = (key, value) {
        if (key.endsWith('_QUEUE') && failQueue) {
          failQueue = false;
          failedId = facadePersistedQueueItems(value)[0]['distinct_id'];
          throw StateError('queue write failed');
        }
      };
    final first = h.create();
    await expectLater(
      first.init(token, storage: storage, trackAutomaticEvents: true),
      throwsMessage('queue write failed'),
    );

    await h.restart();
    relaunchInForeground();
    final reloaded = h.create();
    await reloaded.init(
      token,
      storage: storage,
      trackAutomaticEvents: true,
      optOutTrackingByDefault: true,
    );
    await reloaded.optInTracking();
    final firstOpens = withEvent(h.queue(reloaded), r'$mobile_first_open');
    expect(firstOpens, hasLength(1));
    expect(firstOpens[0]['distinct_id'], isNot(failedId));
  });

  for (final action in ['setVisitorId', 'reset']) {
    test('counts time spent in slow session storage after $action rotation',
        () async {
      final token = 'slow-$action-token';
      h.suspendPeriodicNetworkFlush(token);
      var holdNextSessionWrite = false;
      var blocked = false;
      final held = Completer<void>();
      final storage = FacadeStorage()
        ..onSet = (key, value) async {
          if (key.contains('_MOBILE_SESSION_V1') && holdNextSessionWrite) {
            holdNextSessionWrite = false;
            blocked = true;
            await held.future;
          }
        };
      final op = h.create();
      await op.init(token, storage: storage, trackAutomaticEvents: true);
      op.setFlushOnBackground(false);
      holdNextSessionWrite = true;
      h.clock.shiftWallClock(1);
      final rotationAtMs = h.clock.wallMs;
      final rotation = action == 'setVisitorId'
          ? op.setVisitorId('new-visitor')
          : h.impl(op).reset(token);
      await facadeSettle(100);
      expect(blocked, isTrue);
      await h.clock.advance(5000);
      held.complete();
      await rotation;
      await h.clock.advance(5000);
      await appState('background');

      final queued = h.queue(op);
      final starts = withEvent(queued, r'$mobile_session_start');
      expect(starts, hasLength(2));
      expect(int.parse(sidOf(starts[1])! as String), rotationAtMs);
      expect(
        DateTime.parse(eventPropsOf(starts[1])['mobile_occurred_at']! as String)
            .millisecondsSinceEpoch,
        rotationAtMs,
      );
      final rotatedSid = sidOf(starts[1]);
      expect(
        withEvent(queued, r'$mobile_session_engagement')
            .where((item) => sidOf(item) == rotatedSid)
            .map((item) => eventPropsOf(item)['engagement_duration_ms']! as int)
            .fold<int>(0, (total, value) => total + value),
        10000,
      );
    });
  }

  test(
      'reports opt-out persistence failure and succeeds on retry across '
      'restart', () async {
    const token = 'consent-failure-token';
    var failOptOut = true;
    final storage = FacadeStorage()
      ..onSet = (key, value) {
        if (key.endsWith('_OPT_OUT') && value == 'true' && failOptOut) {
          failOptOut = false;
          throw StateError('opt-out write failed');
        }
      };
    final op = h.create();
    await op.init(token, storage: storage);

    await expectLater(
      op.optOutTracking(),
      throwsMessage('opt-out write failed'),
    );
    expect(op.hasOptedOutTracking(), isTrue);
    await op.optOutTracking();

    await h.restart();
    relaunchInForeground();
    final reloaded = h.create();
    await reloaded.init(token, storage: storage);
    expect(reloaded.hasOptedOutTracking(), isTrue);
  });

  test('keeps tracking opted out when an opt-in write fails', () async {
    const token = 'failed-opt-in-token';
    var failOptIn = true;
    final storage = FacadeStorage()
      ..onSet = (key, value) {
        if (key.endsWith('_OPT_OUT') && value == 'false' && failOptIn) {
          failOptIn = false;
          throw StateError('opt-in write failed');
        }
      };
    final op = h.create();
    await op.init(token, storage: storage, optOutTrackingByDefault: true);

    await expectLater(
      op.optInTracking(),
      throwsMessage('opt-in write failed'),
    );
    expect(op.hasOptedOutTracking(), isTrue);
    await h.impl(op).track(token, 'appointment_booked');
    expect(h.queue(op), isEmpty);

    await h.restart();
    relaunchInForeground();
    final reloaded = h.create();
    await reloaded.init(token, storage: storage);
    expect(reloaded.hasOptedOutTracking(), isTrue);
  });

  test('fails initialization when the saved opt-out flag cannot be read',
      () async {
    final storage = FacadeStorage(persistWrites: false)
      ..onGet = (key) {
        if (key.endsWith('_OPT_OUT')) throw StateError('opt-out read failed');
      };
    final op = h.create();
    await expectLater(
      op.init('consent-read-token', storage: storage),
      throwsMessage('opt-out read failed'),
    );
  });

  test(
      'keeps app-open tied to AppState while rotating identity and reset '
      'sessions', () async {
    const token = 'active-rotation-token';
    h.suspendPeriodicNetworkFlush(token);
    final op = h.create();
    await op.init(
      token,
      storage: InMemoryStorage(),
      trackAutomaticEvents: true,
    );
    op.setFlushOnBackground(false);
    unawaited(op.trackScreen('Schedule'));
    await facadeSettle();
    final initial = h.queue(op);
    final firstSid = sidOf(initial[0]);

    h.clock.shiftWallClock(1);
    await op.setVisitorId('different-visitor');
    h.clock.shiftWallClock(1);
    await h.impl(op).reset(token);
    await h.impl(op).track(token, 'appointment_booked');
    await h.clock.advance(10000);

    final queued = h.queue(op);
    expect(countOf(queued, r'$mobile_app_open'), 1);
    final booked = withEvent(queued, 'appointment_booked').first;
    expect(sidOf(booked), isNot(firstSid));
    final engagement = withEvent(queued, r'$mobile_session_engagement')
        .where((item) => sidOf(item) == sidOf(booked))
        .toList();
    expect(engagement, isNotEmpty);
    expect(
      eventPropsOf(engagement.first),
      allOf(
        containsPair('engagement_duration_ms', 10000),
        containsPair('screen_name', 'Schedule'),
      ),
    );

    await appState('background');
    await appState('active');
    expect(countOf(h.queue(op), r'$mobile_app_open'), 2);
  });

  test(
      'does not attach changed attribution or user defaults to a replayed '
      'lifecycle fact', () async {
    const token = 'context-token';
    var failFirstOpen = true;
    final storage = FacadeStorage()
      ..onSet = (key, value) {
        if (key.endsWith('_QUEUE') &&
            facadePersistedQueueItems(value)
                .any((item) => item['event'] == r'$mobile_first_open') &&
            failFirstOpen) {
          failFirstOpen = false;
          throw StateError('queue write failed');
        }
      };
    final op = h.create();
    await expectLater(
      op.init(
        token,
        storage: storage,
        trackAutomaticEvents: true,
        initialURL: 'myapp://open?utm_source=before',
        defaultUserCustomProperties: {'plan': 'before'},
      ),
      throwsMessage('queue write failed'),
    );
    final originalVisitor = op.getVisitorId();
    h.clock.shiftWallClock(1);
    await op.setVisitorId('visitor-after');
    h.impl(op).updateDefaultUserCustomProperties(token, {'plan': 'after'});
    await op.trackDeepLink('myapp://open?utm_source=after');

    final queued = h.queue(op);
    final firstOpen = withEvent(queued, r'$mobile_first_open').first;
    expect(defaultPropsOf(firstOpen).containsKey('utm_source'), isFalse);
    expect(firstOpen['userProperties'], isNull);
    expect(firstOpen['visitor_id'], originalVisitor);
  });

  test('queues a snapshot-observed session end under the old session defaults',
      () async {
    const token = 'mobile-token';
    h.suspendPeriodicNetworkFlush(token);
    final op = h.create();
    await op.init(
      token,
      storage: InMemoryStorage(),
      trackAutomaticEvents: true,
    );
    op.setFlushOnBackground(false);
    await appState('background');
    await h.clock.advance(30 * 60 * 1000);
    await h.impl(op).track(token, 'appointment_booked');

    final queued = h.queue(op);
    final oldSid = sidOf(withEvent(queued, r'$mobile_session_start').first);
    final end = withEvent(queued, r'$mobile_session_end').first;
    final booked = withEvent(queued, 'appointment_booked').first;
    expect(sidOf(end), oldSid);
    expect(sidOf(booked), isNot(oldSid));
    expect(sidOf(end), sidOf(queued[0]));
  });

  test('continues foreground engagement after an identity change', () async {
    const token = 'identity-engagement-token';
    h.suspendPeriodicNetworkFlush(token);
    final op = h.create();
    await op.init(
      token,
      storage: InMemoryStorage(),
      trackAutomaticEvents: true,
    );
    final queuedBefore = h.queue(op);
    final oldSid = sidOf(queuedBefore[0]);

    h.clock.shiftWallClock(1);
    await op.setVisitorId('visitor-after');
    await h.clock.advance(10000);
    final queuedAfter = h.queue(op);
    final engagement =
        withEvent(queuedAfter, r'$mobile_session_engagement').first;
    expect(sidOf(engagement), isNot(oldSid));
    expect(eventPropsOf(engagement)['engagement_duration_ms'], 10000);
    expect(countOf(queuedAfter, r'$mobile_first_open'), 1);
  });

  // RN: 'runs init -> track -> flush through the real JS stack'.
  test('runs init -> track -> flush through the real Dart stack', () async {
    h.respondOnce.add(facadeJson({'success': true}));

    final op = h.create();

    await op.init(
      'test-token',
      storage: InMemoryStorage(),
      serverURL: 'https://api.oursprivacy.com',
      visitorId: 'preset-visitor-123',
      defaultEventProperties: {'platform': 'mobile'},
      defaultUserCustomProperties: {'plan': 'pro'},
      defaultUserConsentProperties: {'marketing': true},
    );

    unawaited(op.track('Purchase', {'price': 99}));
    await facadeSettle();
    unawaited(op.flush());
    await h.waitForRequests(1);

    final request = h.requests[0];
    final body = h.bodies[0];

    expect(request.url.toString(), 'https://api.oursprivacy.com/ingest');
    expect(body['token'], 'test-token');
    expect(body['is_manually_set_id'], isTrue);
    expect(body['data'], hasLength(1));
    final item = facadeMap((body['data']! as List)[0]);
    expect(item['event'], 'Purchase');
    expect(item['visitor_id'], 'preset-visitor-123');
    expect(item['distinct_id'], isA<String>());
    expect(
      eventPropsOf(item),
      allOf(containsPair('platform', 'mobile'), containsPair('price', 99)),
    );
    expect(userPropsOf(item), {
      'custom_properties': {'plan': 'pro'},
      'consent': {'marketing': true},
    });
    expect(
      defaultPropsOf(item),
      allOf(
        containsPair('device_type', 'mobile'),
        containsPair('os_name', 'iOS'),
        containsPair('version', isA<String>()),
      ),
    );
  });

  test(
      'drops pre-opt-out queued events across optOut -> optIn -> track -> '
      'flush', () async {
    h.respondOnce.add(facadeJson({'success': true}));

    final op = h.create();

    await op.init(
      'test-token',
      storage: InMemoryStorage(),
      serverURL: 'https://api-eu.oursprivacy.com',
      visitorId: 'preset-visitor-123',
    );

    unawaited(op.track('Before Opt Out', {'step': 1}));
    await facadeSettle();

    unawaited(op.optOutTracking());
    await facadeSettle();
    expect(op.hasOptedOutTracking(), isTrue);

    unawaited(op.optInTracking());
    await facadeSettle();
    expect(op.hasOptedOutTracking(), isFalse);

    unawaited(op.track('After Opt In', {'step': 2}));
    await facadeSettle();

    unawaited(op.flush());
    await h.waitForRequests(1);

    final eventNames = facadeEventNames(h.sentEvents);

    expect(
        h.requests[0].url.toString(), 'https://api-eu.oursprivacy.com/ingest');
    expect(eventNames, [r'$opt_in', 'After Opt In']);
    expect(eventNames, isNot(contains('Before Opt Out')));
  });

  test(
      'deep link attribution: initialURL → warm deep link → set visitor → opt '
      'cycle → reset', () async {
    h.respond = facadeIndexedSuccess;

    final op = h.create();

    // Step 1: Init with initialURL — should fire $deep_link_opened and set
    // attribution
    await op.init(
      'test-token',
      storage: InMemoryStorage(),
      serverURL: 'https://api.oursprivacy.com',
      initialURL:
          'myapp://open?utm_source=google&utm_medium=cpc&gclid=init_gclid&aleid=init_aleid',
    );
    await facadeSettle();
    unawaited(op.flush());
    await h.waitForRequests(1);

    var body = h.bodies[0];
    List<Map<String, Object?>> data() =>
        [for (final item in body['data']! as List) facadeMap(item)];
    var deepLinkEvent = withEvent(data(), r'$deep_link_opened').first;
    // Attribution in defaultProperties, not eventProperties
    expect(defaultPropsOf(deepLinkEvent)['utm_source'], 'google');
    expect(defaultPropsOf(deepLinkEvent)['gclid'], 'init_gclid');
    expect(defaultPropsOf(deepLinkEvent)['aleid'], 'init_aleid');
    expect(eventPropsOf(deepLinkEvent), {
      'mobile_contract_version': 1,
      'mobile_occurred_at': isA<String>(),
    });

    // Step 2: Track after init — attribution should persist in
    // defaultProperties
    h.requests.clear();
    unawaited(op.track('after_init', {'step': 2}));
    await facadeSettle();
    unawaited(op.flush());
    await h.waitForRequests(1);

    body = h.bodies[0];
    var trackEvent = withEvent(data(), 'after_init').first;
    expect(defaultPropsOf(trackEvent)['utm_source'], 'google');
    expect(defaultPropsOf(trackEvent)['gclid'], 'init_gclid');
    final visitorIdAfterInit = trackEvent['visitor_id'];

    // Step 3: Warm deep link — replaces attribution, stitches visitor ID
    h.requests.clear();
    await op.trackDeepLink(
      'myapp://products/123?utm_source=applovin&aleid=warm_aleid&ours_visitor_id=web-uuid-123',
    );
    unawaited(op.track('after_warm_link', {'step': 3}));
    await facadeSettle();
    unawaited(op.flush());
    await h.waitForRequests(1);

    body = h.bodies[0];
    deepLinkEvent = withEvent(data(), r'$deep_link_opened').first;
    trackEvent = withEvent(data(), 'after_warm_link').first;
    // New attribution replaces old — gclid from init should be gone
    expect(defaultPropsOf(deepLinkEvent)['utm_source'], 'applovin');
    expect(defaultPropsOf(deepLinkEvent)['aleid'], 'warm_aleid');
    expect(defaultPropsOf(deepLinkEvent).containsKey('gclid'), isFalse);
    expect(eventPropsOf(deepLinkEvent), {
      'mobile_contract_version': 1,
      'mobile_occurred_at': isA<String>(),
    });
    // Visitor ID stitched from ours_visitor_id
    expect(trackEvent['visitor_id'], 'web-uuid-123');
    expect(trackEvent['visitor_id'], isNot(visitorIdAfterInit));
    expect(defaultPropsOf(trackEvent)['utm_source'], 'applovin');
    expect(defaultPropsOf(trackEvent)['aleid'], 'warm_aleid');
    expect(defaultPropsOf(trackEvent).containsKey('gclid'), isFalse);
    // is_manually_set_id should be true
    expect(body['is_manually_set_id'], isTrue);

    // Step 4: setVisitorId manually
    h.requests.clear();
    await op.setVisitorId('manual-visitor-id');
    unawaited(op.track('after_set_visitor', {'step': 4}));
    await facadeSettle();
    unawaited(op.flush());
    await h.waitForRequests(1);

    body = h.bodies[0];
    trackEvent = withEvent(data(), 'after_set_visitor').first;
    expect(trackEvent['visitor_id'], 'manual-visitor-id');

    // Step 5: Opt out → deep link (should be complete no-op) → opt in
    h.requests.clear();
    await op.optOutTracking();
    await facadeSettle();
    await op.trackDeepLink(
      'myapp://open?utm_source=should_not_appear&gclid=nope',
    );
    await facadeSettle();
    await op.optInTracking();
    await facadeSettle();
    unawaited(op.track('after_opt_cycle', {'step': 5}));
    await facadeSettle();
    unawaited(op.flush());
    await h.waitForRequests(1);

    body = h.bodies[0];
    trackEvent = withEvent(data(), 'after_opt_cycle').first;
    // Attribution from opted-out deep link should NOT be present
    expect(defaultPropsOf(trackEvent).containsKey('utm_source'), isFalse);
    expect(defaultPropsOf(trackEvent).containsKey('gclid'), isFalse);
    // The $deep_link_opened from the opted-out call should not exist
    final allEvents = facadeEventNames(data());
    expect(allEvents, contains(r'$opt_in'));
    expect(allEvents, isNot(contains(r'$deep_link_opened')));

    // Step 6: Reset — should clear everything
    h.requests.clear();
    unawaited(op.reset());
    await facadeSettle();
    unawaited(op.track('after_reset', {'step': 6}));
    await facadeSettle();
    unawaited(op.flush());
    await h.waitForRequests(1);

    body = h.bodies[0];
    trackEvent = withEvent(data(), 'after_reset').first;
    // No attribution after reset
    expect(defaultPropsOf(trackEvent).containsKey('utm_source'), isFalse);
    expect(defaultPropsOf(trackEvent).containsKey('aleid'), isFalse);
    // New visitor_id
    expect(trackEvent['visitor_id'], isNot('manual-visitor-id'));
    expect(trackEvent['visitor_id'], isNot('web-uuid-123'));
  });

  test(
      '3-arg track: top-level user props, custom_properties + consent merge, '
      'null when empty', () async {
    h.respond = facadeIndexedSuccess;

    final op = h.create();

    await op.init(
      'test-token',
      storage: InMemoryStorage(),
      serverURL: 'https://api.oursprivacy.com',
      visitorId: 'preset-visitor-123',
      defaultUserCustomProperties: {'test_user': true},
    );

    // S1: 2-arg backwards compat — default custom only on the wire
    unawaited(op.track('two_arg_compat', {'scenario': 1}));
    // S2: 3-arg with top-level user props (email + externalId)
    unawaited(op.track(
      'three_arg_top_level',
      {'scenario': 2},
      {'email': 'qa@example.com', 'externalId': 'qa-1'},
    ));
    // S3: 3-arg with per-call customProperties — merges on top of default
    // {test_user:true}
    unawaited(op.track(
      'three_arg_custom_merge',
      {'scenario': 3},
      {
        'customProperties': {'tier': 'gold'},
      },
    ));
    // S4: 3-arg with per-call consent — no default consent, should appear
    // verbatim
    unawaited(op.track(
      'three_arg_consent',
      {'scenario': 4},
      {
        'consent': {'marketing': true},
      },
    ));

    await facadeSettle();
    unawaited(op.flush());
    await h.waitForRequests(1);

    final byName = {
      for (final item in h.sentEvents) item['event']! as String: item,
    };

    // S1: backwards compat — default custom_properties only
    expect(userPropsOf(byName['two_arg_compat']!), {
      'custom_properties': {'test_user': true},
    });

    // S2: top-level keys spread, default custom_properties merged, no consent
    // key
    expect(userPropsOf(byName['three_arg_top_level']!), {
      'email': 'qa@example.com',
      'external_id': 'qa-1',
      'custom_properties': {'test_user': true},
    });
    expect(
      userPropsOf(byName['three_arg_top_level']!)!.containsKey('consent'),
      isFalse,
    );

    // S3: custom_properties merged (default + per-call)
    expect(userPropsOf(byName['three_arg_custom_merge']!)!['custom_properties'],
        {'test_user': true, 'tier': 'gold'});

    // S4: consent appears, default custom_properties still merged
    expect(userPropsOf(byName['three_arg_consent']!)!['consent'], {
      'marketing': true,
    });
    expect(userPropsOf(byName['three_arg_consent']!)!['custom_properties'], {
      'test_user': true,
    });

    // S5: separate instance with no defaults and no per-call user props →
    // null
    h.requests.clear();
    final op2 = h.create();
    await op2.init(
      'test-token-2',
      storage: InMemoryStorage(),
      serverURL: 'https://api.oursprivacy.com',
      visitorId: 'preset-visitor-456',
    );
    unawaited(op2.track('no_user_props_anywhere', {'scenario': 5}));
    await facadeSettle();
    unawaited(op2.flush());
    await h.waitForRequests(1);
    final s5 = withEvent(h.sentEvents, 'no_user_props_anywhere').first;
    expect(s5.containsKey('userProperties'), isTrue);
    expect(s5['userProperties'], isNull);
  });

  test('flushes queued events when the app moves to background', () async {
    h.respond = facadeIndexedSuccess;

    final op = h.create();

    await op.init(
      'test-token',
      storage: InMemoryStorage(),
      serverURL: 'https://api.oursprivacy.com',
      visitorId: 'preset-visitor-bg',
    );

    unawaited(op.track('Backgrounded Event', {'step': 1}));
    await facadeSettle();

    expect(h.appState.listenerCount, greaterThan(0));
    expect(h.requests, isEmpty);

    // Simulate the OS pushing the app to background.
    h.appState.emit(OursAppState.paused);

    await h.waitForRequests(1);

    final body = h.bodies[0];
    expect(h.requests[0].url.toString(), 'https://api.oursprivacy.com/ingest');
    expect(body['data'], hasLength(1));
    expect(
        facadeMap((body['data']! as List)[0])['event'], 'Backgrounded Event');
  });

  test('does not flush on transitions that are not background/inactive',
      () async {
    h.respond = facadeIndexedSuccess;

    final op = h.create();

    await op.init(
      'test-token',
      storage: InMemoryStorage(),
      serverURL: 'https://api.oursprivacy.com',
      visitorId: 'preset-visitor-bg2',
    );

    unawaited(op.track('Foreground Only', {'step': 1}));
    await facadeSettle();

    h.appState.emit(OursAppState.resumed);
    await facadeSettle();

    expect(h.requests, isEmpty);
  });

  group('visitor identity authority', () {
    // `is_manually_set_id: false` lets ingest replace the visitor through a
    // cookie or probabilistic match, so an explicit or reset visitor must
    // keep `true` across a cold restart (as on Android, iOS and React Native).
    Future<OursPrivacy> restartAndTrack(
        String token, FacadeStorage storage, String event) async {
      await h.restart();
      h.suspendPeriodicNetworkFlush(token);
      h.respond = facadeIndexedSuccess;
      final reloaded = h.create();
      await reloaded.init(token, storage: storage);
      await reloaded.track(event);
      await reloaded.flush();
      return reloaded;
    }

    List<Map<String, Object?>> sent() => [
          for (final body in h.bodies)
            for (final item in body['data']! as List<Object?>)
              {
                'event': facadeMap(item)['event'],
                'visitor_id': facadeMap(item)['visitor_id'],
                'is_manually_set_id': body['is_manually_set_id'],
              },
        ];

    test('sends the reset visitor as manually set, before and after restart',
        () async {
      const token = 'reset-authority-token';
      final storage = FacadeStorage();
      h.suspendPeriodicNetworkFlush(token);
      h.respond = facadeIndexedSuccess;
      final op = h.create();
      await op.init(token, storage: storage);
      final initialVisitor = op.getVisitorId();
      await op.track('before_reset');
      await op.reset();
      final resetVisitor = op.getVisitorId();
      expect(resetVisitor, isNot(initialVisitor));
      await op.track('after_reset');
      await op.flush();

      final reloaded = await restartAndTrack(token, storage, 'after_restart');

      expect(reloaded.getVisitorId(), resetVisitor);
      expect(sent(), [
        {
          'event': 'before_reset',
          'visitor_id': initialVisitor,
          'is_manually_set_id': false,
        },
        {
          'event': 'after_reset',
          'visitor_id': resetVisitor,
          'is_manually_set_id': true,
        },
        {
          'event': 'after_restart',
          'visitor_id': resetVisitor,
          'is_manually_set_id': true,
        },
      ]);
    });

    test('keeps a fresh install automatic after restart', () async {
      const token = 'automatic-restart-token';
      final storage = FacadeStorage();
      final op = h.create();
      await op.init(token, storage: storage);
      final visitor = op.getVisitorId();

      await restartAndTrack(token, storage, 'after_restart');

      expect(sent(), [
        {
          'event': 'after_restart',
          'visitor_id': visitor,
          'is_manually_set_id': false,
        },
      ]);
    });

    for (final source in [
      'setVisitorId',
      'init visitorId option',
      'deep link',
      'reset then setVisitorId',
    ]) {
      test('keeps explicit visitor authority across restart after $source',
          () async {
        const token = 'explicit-restart-token';
        const explicitVisitor = 'explicit-visitor';
        final storage = FacadeStorage();
        final op = h.create();
        if (source == 'init visitorId option') {
          await op.init(token, storage: storage, visitorId: explicitVisitor);
        } else {
          await op.init(token, storage: storage);
        }
        if (source == 'setVisitorId') await op.setVisitorId(explicitVisitor);
        if (source == 'deep link') {
          await op
              .trackDeepLink('myapp://open?ours_visitor_id=$explicitVisitor');
        }
        if (source == 'reset then setVisitorId') {
          await op.reset();
          await op.setVisitorId(explicitVisitor);
        }
        expect(op.getVisitorId(), explicitVisitor);

        final reloaded = await restartAndTrack(token, storage, 'after_restart');

        expect(reloaded.getVisitorId(), explicitVisitor);
        expect(
            sent(),
            contains(equals({
              'event': 'after_restart',
              'visitor_id': explicitVisitor,
              'is_manually_set_id': true,
            })));
      });
    }

    for (final (failedWrite, source, restoredMode) in [
      ('authority', 'automatic', false),
      ('authority', 'explicit', true),
      ('visitor', 'automatic', false),
      ('visitor', 'explicit', true),
    ]) {
      test(
          'keeps the $failedWrite write predecessor from $source when '
          'setVisitorId cannot persist', () async {
        const token = 'explicit-write-failure-token';
        String? failingKey;
        final storage = FacadeStorage()
          ..onSet = (key, value) {
            if (key == failingKey) throw StateError('$failedWrite failed');
          };
        h.suspendPeriodicNetworkFlush(token);
        h.respond = facadeIndexedSuccess;
        final op = h.create();
        await op.init(token, storage: storage);
        if (source == 'explicit') await op.setVisitorId('first-explicit');
        final previousVisitor = op.getVisitorId();
        failingKey = failedWrite == 'authority'
            ? isManuallySetIdKey(token)
            : visitorIdKey(token);

        await op.setVisitorId('unsaved-visitor');
        expect(op.getVisitorId(), 'unsaved-visitor');
        await op.track('after_unsaved_set');
        await op.flush();
        failingKey = null;

        final reloaded = await restartAndTrack(token, storage, 'after_restart');

        expect(reloaded.getVisitorId(), previousVisitor);
        expect(sent(), [
          {
            'event': 'after_unsaved_set',
            'visitor_id': 'unsaved-visitor',
            'is_manually_set_id': true,
          },
          {
            'event': 'after_restart',
            'visitor_id': previousVisitor,
            'is_manually_set_id': restoredMode,
          },
        ]);
      });
    }

    for (final source in ['automatic', 'explicit', 'prior-reset']) {
      for (final firstFailure in ['authority', 'visitor']) {
        for (final retry in [
          'same-ID setVisitorId',
          'new-ID setVisitorId',
          'reset',
        ]) {
          test(
              'keeps the durable $source predecessor after a failed '
              '$firstFailure write and a failed $retry', () async {
            const token = 'repeated-write-failure-token';
            String? failingKey;
            final storage = FacadeStorage()
              ..onSet = (key, value) {
                if (key == failingKey) throw StateError('write failed');
              };
            h.suspendPeriodicNetworkFlush(token);
            h.respond = facadeIndexedSuccess;
            final op = h.create();
            await op.init(token, storage: storage);
            if (source == 'explicit') await op.setVisitorId('first-explicit');
            if (source == 'prior-reset') await op.reset();
            final durableVisitor = op.getVisitorId();

            failingKey = firstFailure == 'authority'
                ? isManuallySetIdKey(token)
                : visitorIdKey(token);
            await op.setVisitorId('unsaved-visitor');
            failingKey = visitorIdKey(token);
            if (retry == 'same-ID setVisitorId') {
              await op.setVisitorId('unsaved-visitor');
            } else if (retry == 'new-ID setVisitorId') {
              await op.setVisitorId('another-unsaved-visitor');
            } else {
              await op.reset();
              expect(h.logs, contains(startsWith('error: ')));
            }
            expect(storage.values[visitorIdKey(token)], durableVisitor);
            failingKey = null;

            final reloaded = await restartAndTrack(
              token,
              storage,
              'after_restart',
            );

            expect(reloaded.getVisitorId(), durableVisitor);
            expect(
              sent(),
              contains(
                equals({
                  'event': 'after_restart',
                  'visitor_id': durableVisitor,
                  'is_manually_set_id': source != 'automatic',
                }),
              ),
            );
          });
        }
      }
    }

    for (final (failedWrite, source, runtimeMode, restoredMode) in [
      ('authority', 'automatic', false, false),
      ('authority', 'explicit', true, true),
      ('authority', 'prior-reset', true, true),
      ('visitor', 'automatic', false, false),
      ('visitor', 'explicit', true, true),
      ('visitor', 'prior-reset', true, true),
    ]) {
      test(
          'retains the $failedWrite write predecessor from $source after a '
          'failed reset', () async {
        const token = 'reset-write-failure-token';
        String? failingKey;
        final storage = FacadeStorage()
          ..onSet = (key, value) {
            if (key == failingKey) throw StateError('$failedWrite failed');
          };
        h.suspendPeriodicNetworkFlush(token);
        h.respond = facadeIndexedSuccess;
        final op = h.create();
        await op.init(token, storage: storage);
        if (source == 'explicit') await op.setVisitorId('explicit-visitor');
        if (source == 'prior-reset') await op.reset();
        final previousVisitor = op.getVisitorId();
        await op.track('before_failed_reset');
        failingKey = failedWrite == 'authority'
            ? isManuallySetIdKey(token)
            : visitorIdKey(token);

        // The facade logs operation failures instead of throwing.
        await op.reset();
        expect(h.logs, contains(startsWith('error: ')));
        expect(op.getVisitorId(), previousVisitor);
        expect(storage.values[visitorIdKey(token)], previousVisitor);
        await op.track('after_failed_reset');
        await op.flush();
        failingKey = null;

        final reloaded = await restartAndTrack(token, storage, 'after_restart');

        expect(reloaded.getVisitorId(), previousVisitor);
        expect(sent(), [
          {
            'event': 'before_failed_reset',
            'visitor_id': previousVisitor,
            'is_manually_set_id': runtimeMode,
          },
          {
            'event': 'after_failed_reset',
            'visitor_id': previousVisitor,
            'is_manually_set_id': runtimeMode,
          },
          {
            'event': 'after_restart',
            'visitor_id': previousVisitor,
            'is_manually_set_id': restoredMode,
          },
        ]);
      });
    }
  });
}
