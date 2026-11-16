// Port of __tests__/compatibility.test.js (React Native SDK).
//
// Runs through the public `OursPrivacy` facade on a forced iOS device whose
// app is active, like RN's `jest_setup.js`. Jest's module mocks become the
// SDK's test seams (see test/helpers/core_harness.dart):
// - `jest-fetch-mock` → [CoreFetch] through SDK-owned clients; RN's
//   `signal.aborted` → the SDK closing that client;
// - Jest fake timers / `jest.setSystemTime` → [CoreFakeTimers] and the
//   injected wall clock;
// - `AppState` listeners → one `ManualLifecycleSource` per `init`; RN's
//   `onChange('background')` → Flutter's `inactive`, `hidden`, `paused`
//   sequence;
// - `jest.resetModules()` (a process restart) → dispose the instance and
//   `resetOursPrivacyForTesting()`, keeping the storage;
// - `client.oursprivacyImpl._pendingOperation` → awaiting the operation's
//   own future, or letting the event loop settle.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:ours_privacy/ours_privacy.dart';
import 'package:ours_privacy/src/constants.dart';
import 'package:ours_privacy/src/queue.dart';
import 'package:ours_privacy/src/testing.dart';

import 'helpers/core_harness.dart';

Map<String, Object?>? _find(List<QueueItem> queue, String event) {
  for (final item in queue) {
    if (item['event'] == event) return item;
  }
  return null;
}

List<Object?> _events(List<Object?> rows) =>
    [for (final row in rows) (row! as Map<String, Object?>)['event']];

Matcher _throwsMessage(String message) =>
    throwsA(predicate((Object? e) => '$e'.contains(message), message));

final String _indexedOne = jsonEncode({
  'success': true,
  'accepted': 1,
  'rejected': <Object?>[],
});

void main() {
  late CoreFetch fetch;
  late CoreFakeTimers timers;
  final clients = <CoreClient>[];

  CoreClient newClient() {
    final client = CoreClient(timers: timers, fetch: fetch);
    clients.add(client);
    return client;
  }

  /// RN `jest.resetModules()`: a new process over the same storage.
  Future<void> restart() async {
    for (final client in clients) {
      await client.dispose();
    }
    clients.clear();
    resetOursPrivacyForTesting();
  }

  Map<String, Object?> rejectionMap(OursPrivacyIngestRejection item) =>
      {'distinctId': item.distinctId, 'code': item.code};

  setUp(() {
    resetOursPrivacyForTesting();
    fetch = CoreFetch();
    timers = CoreFakeTimers();
    clients.clear();
  });

  tearDown(() async {
    for (final client in clients) {
      await client.dispose();
    }
    clients.clear();
    resetOursPrivacyForTesting();
  });

  group('SDK compatibility', () {
    test('does not upload a restored queue before stored opt-out is read',
        () async {
      const token = 'pending-consent';
      final consentRead = Completer<String?>();
      final storage = CoreStorage({
        queueKey(token, '/ingest'): jsonEncode([
          {'event': 'stored', 'distinct_id': 'stored-event'},
        ]),
        optOutKey(token): 'true',
      });
      storage.getItemOverride = (key) => key == optOutKey(token)
          ? consentRead.future
          : storage.baseGetItem(key);
      fetch.mockResponse(_indexedOne);

      final client = newClient();
      final initializing = client.op.init(token, storage: storage);
      await coreTickUntil(() => storage.getCalls.contains(optOutKey(token)));
      await timers.advance(const Duration(milliseconds: 10000));
      expect(fetch.callCount, 0);

      consentRead.complete('true');
      await initializing;
      await timers.advance(const Duration(milliseconds: 10000));
      expect(fetch.callCount, 0);
    });

    test('does not upload a restored queue if consent loading fails', () async {
      const token = 'failed-consent';
      final storage = CoreStorage({
        queueKey(token, '/ingest'): jsonEncode([
          {'event': 'stored', 'distinct_id': 'stored-event'},
        ]),
      });
      storage.getItemOverride = (key) {
        if (key == optOutKey(token)) {
          return Future<String?>.error(StateError('consent unavailable'));
        }
        return storage.baseGetItem(key);
      };
      fetch.mockResponse(_indexedOne);

      final client = newClient();
      await expectLater(
        client.op.init(token, storage: storage),
        _throwsMessage('consent unavailable'),
      );
      await timers.advance(const Duration(milliseconds: 10000));
      expect(fetch.callCount, 0);
      await client.op.flush();
      expect(fetch.callCount, 0);
    });

    test(
        'keeps an opt-out made during consent loading from being overwritten '
        'by the older read', () async {
      const token = 'opt-out-during-init';
      final consentRead = Completer<String?>();
      final queueWrites = <String>[];
      final storage = CoreStorage();
      storage.getItemOverride = (key) => key == optOutKey(token)
          ? consentRead.future
          : storage.baseGetItem(key);
      storage.setItemOverride = (key, value) {
        if (key == queueKey(token, '/ingest')) queueWrites.add(value);
        return storage.baseSetItem(key, value);
      };

      final client = newClient();
      final initializing = client.op.init(
        token,
        storage: storage,
        trackAutomaticEvents: true,
      );
      await coreTickUntil(() => storage.getCalls.contains(optOutKey(token)));
      final optingOut = client.op.optOutTracking();
      consentRead.complete(null);
      await initializing;
      await optingOut;
      expect(client.op.hasOptedOutTracking(), isTrue);
      expect(
        queueWrites.any((value) => value.contains(r'$mobile_app_open')),
        isFalse,
      );
    });

    test('fails closed when a stored tracking decision is malformed', () async {
      const token = 'malformed-consent';
      final storage = CoreStorage({
        queueKey(token, '/ingest'): jsonEncode([
          {'event': 'stored', 'distinct_id': 'stored-event'},
        ]),
        optOutKey(token): 'invalid',
      });
      fetch.mockResponse(_indexedOne);
      final client = newClient();
      await expectLater(
        client.op.init(token, storage: storage),
        _throwsMessage('Invalid stored tracking decision'),
      );
      await timers.advance(const Duration(milliseconds: 10000));
      expect(fetch.callCount, 0);
    });

    test(
        'cancels a retry of a captured batch after opt-out, including a later '
        'opt-in', () async {
      final client = newClient();
      await client.op.init('retry-consent', storage: CoreStorage());
      await client.op.track('queued');
      fetch
        ..mockRejectOnce(http.ClientException('offline'))
        ..mockResponse(_indexedOne);

      final flushing = client.op.flush();
      await coreTickUntil(() => fetch.callCount == 1);
      final optingOut = client.op.optOutTracking();
      await timers.advance(const Duration(milliseconds: 2000));
      await flushing;
      await optingOut;
      await client.op.optInTracking();
      expect(fetch.callCount, 1);
    });

    test('aborts an active upload when tracking is opted out', () async {
      final client = newClient();
      await client.op.init('active-consent', storage: CoreStorage());
      await client.op.track('queued');
      fetch.mockImplementation(CoreFetch.pendingForever);

      final flushing = client.op.flush();
      await coreTickUntil(() => fetch.callCount == 1);
      final optingOut = client.op.optOutTracking();
      expect(fetch.callClients.single.closed, isTrue);
      await flushing;
      await optingOut;
      expect(fetch.callCount, 1);
    });

    test(
        'preserves an explicit stored opt-in despite opt-out by default on '
        'restart', () async {
      final storage = CoreStorage();
      final first = newClient();
      await first.op.init(
        'remembered-choice',
        storage: storage,
        optOutTrackingByDefault: true,
      );
      await first.op.optInTracking();
      await restart();
      final second = newClient();
      await second.op.init(
        'remembered-choice',
        storage: storage,
        optOutTrackingByDefault: true,
      );
      expect(second.op.hasOptedOutTracking(), isFalse);
      await second.op.track('after-restart');
      expect(
        coreQueue(storage, 'remembered-choice')
            .any((event) => event['event'] == 'after-restart'),
        isTrue,
      );
    });

    test('starts periodic queue processing after a fresh opt-in', () async {
      final client = newClient();
      await client.op.init(
        'opt-in-timer',
        storage: CoreStorage(),
        optOutTrackingByDefault: true,
      );
      await client.op.optInTracking();
      await client.op.track('after-opt-in');
      fetch.mockResponse(jsonEncode({
        'success': true,
        'accepted': 2,
        'rejected': <Object?>[],
      }));
      await timers.advance(const Duration(milliseconds: 10000));
      expect(fetch.callCount, 1);
    });

    test(
        'reconciles a background AppState transition while initialization is '
        'pending', () async {
      final storage = CoreStorage();
      final releaseSession = Completer<String?>();
      storage.getItemOverride = (key) => key.contains('_MOBILE_SESSION_V1')
          ? releaseSession.future
          : storage.baseGetItem(key);
      final client = newClient();
      final initializing = client.op.init(
        'background-init',
        storage: storage,
        trackAutomaticEvents: true,
      );
      await coreTickUntil(
        () => storage.getCalls.any((key) => key.contains('_MOBILE_SESSION_V1')),
      );
      expect(client.lifecycle.isStarted, isTrue);
      client.emitBackground();
      releaseSession.complete(null);
      await initializing;
      await coreSettle();
      expect(
        coreQueue(storage, 'background-init')
            .any((event) => event['event'] == r'$mobile_app_open'),
        isFalse,
      );
    });

    test('omits empty per-call consent from event and identify payloads',
        () async {
      final storage = CoreStorage();
      final client = newClient();
      await client.op.init('empty-consent', storage: storage);
      final tracking = client.op.track(
        'empty-event',
        {},
        {'email': 'example@test.invalid', 'consent': <String, Object?>{}},
      );
      await client.op.identify({'consent': <String, Object?>{}});
      await tracking;
      final events = coreQueue(storage, 'empty-consent');
      expect(
        _find(events, 'empty-event')!['userProperties'],
        {'email': 'example@test.invalid'},
      );
      expect(_find(events, r'$identify')!['userProperties'], isNull);
    });
  });

  test(
      'keeps the last opt-out when an earlier opt-in waits behind '
      'initialization', () async {
    final storage = CoreStorage();
    final consentRead = Completer<String?>();
    storage.getItemOverride = (key) => key == optOutKey('last-choice')
        ? consentRead.future
        : storage.baseGetItem(key);
    final client = newClient();
    final initializing = client.op.init('last-choice', storage: storage);
    await coreTickUntil(
      () => storage.getCalls.contains(optOutKey('last-choice')),
    );
    final optingIn = client.op.optInTracking();
    final optingOut = client.op.optOutTracking();
    consentRead.complete(null);
    await Future.wait([initializing, optingIn, optingOut]);
    expect(client.op.hasOptedOutTracking(), isTrue);
    expect(storage.values[optOutKey('last-choice')], 'true');
    await client.impl.track('last-choice', 'must-stay-private');
    expect(coreQueue(storage, 'last-choice'), isEmpty);
  });

  test('ignores an unmarked legacy opt-in when an app now defaults to opt-out',
      () async {
    final storage = CoreStorage({optOutKey('legacy-default'): 'false'});
    final client = newClient();
    await client.op.init(
      'legacy-default',
      storage: storage,
      optOutTrackingByDefault: true,
    );
    expect(client.op.hasOptedOutTracking(), isTrue);
  });

  test('queues a track at call time while a flush awaits the network',
      () async {
    final storage = CoreStorage();
    final client = newClient();
    await client.op.init('slow-network', storage: storage);
    await client.impl.track('slow-network', 'first');
    final response = Completer<http.StreamedResponse>();
    fetch.mockImplementation((_) => response.future);
    final flushing = client.op.flush();
    await coreTickUntil(() => fetch.callCount == 1);
    final calledAt = coreIso(client.wallNow);
    final tracking = client.impl.track('slow-network', 'during-upload');
    client.wallOffsetMs += 5000;
    await coreSettle();
    final queuedWhileUploading =
        _find(coreQueue(storage, 'slow-network'), 'during-upload');
    final ack = jsonEncode({'success': true, 'visitor_id': 'ack'});
    fetch.mockResponse(ack);
    response.complete(coreStreamed(http.Response(ack, 200)));
    await Future.wait([flushing, tracking]);
    expect(queuedWhileUploading, isNotNull);
    expect(
      (queuedWhileUploading?['eventProperties'] as Map?)?['mobile_occurred_at'],
      calledAt,
    );
  });

  test('seeds first-open from an identity present before the SDK creates one',
      () async {
    final values = {visitorIdKey('existing-install'): 'existing-visitor'};
    final storage = CoreStorage(values);
    final client = newClient();
    await client.op.init(
      'existing-install',
      storage: storage,
      trackAutomaticEvents: true,
      appVersion: '2.0',
      appBuild: '20',
    );
    expect(
      coreQueue(storage, 'existing-install').map((item) => item['event']),
      [r'$mobile_app_open', r'$mobile_session_start'],
    );
    final stored =
        jsonDecode(values['OURSPRIVACY_existing-install_MOBILE_SESSION_V1']!)
            as Map<String, Object?>;
    expect(stored, containsPair('firstOpenSent', true));
    expect(stored, containsPair('observedAppVersion', '2.0'));
    expect(stored, containsPair('observedAppBuild', '20'));
  });

  test('persists the queue as an array readable by a rolled-back SDK',
      () async {
    final values = <String, String>{};
    final client = newClient();
    await client.op.init(
      'rollback-storage',
      storage: CoreStorage(values),
      trackAutomaticEvents: true,
    );
    await client.impl.track('rollback-storage', 'manual');
    final stored = jsonDecode(values[queueKey('rollback-storage', '/ingest')]!);
    expect(stored, isA<List<Object?>>());
    expect(_events(stored as List<Object?>), contains('manual'));
    await restart();
    final storage = CoreStorage(values);
    final next = newClient();
    await next.op.init(
      'rollback-storage',
      storage: storage,
      trackAutomaticEvents: true,
    );
    expect(
      OursPrivacyQueueManager.of(storage)
          .hasAcceptedFirstOpen('rollback-storage', '/ingest'),
      isTrue,
    );
  });

  test(
      'disposes the previous app-state subscription and pending timer on '
      're-init', () async {
    final client = newClient();
    final storage = CoreStorage();
    await client.op.init(
      'reinitialize',
      storage: storage,
      trackAutomaticEvents: true,
    );
    await client.op.init(
      'reinitialize',
      storage: storage,
      trackAutomaticEvents: true,
    );
    expect(client.activeListenerCount, 1);
    // The new instance's queue-flush timer and engagement checkpoint.
    expect(timers.activeCount, 2);
  });

  test('returns tracking, screen, and reset completion promises', () async {
    final client = newClient();
    await client.op.init('completion-promises', storage: CoreStorage());
    final tracking = client.op.track('manual');
    final screen = client.op.trackScreen('Home');
    final reset = client.op.reset();
    expect(tracking, isA<Future<void>>());
    expect(screen, isA<Future<void>>());
    expect(reset, isA<Future<void>>());
    await Future.wait([tracking, screen, reset]);
  });

  test('ignores reserved manual mobile event names', () async {
    final storage = CoreStorage();
    final client = newClient();
    await client.op.init('reserved-events', storage: storage);
    await expectLater(client.op.track(r'$mobile_app_open'), completes);
    expect(coreQueue(storage, 'reserved-events'), isEmpty);
  });

  final compatibleAcks = <(String, String, int)>[
    ('empty', '', 200),
    ('no content', '', 204),
    (
      'no visitor ID',
      jsonEncode({'success': true, 'request_id': 'extra'}),
      200
    ),
  ];
  for (final (name, body, status) in compatibleAcks) {
    test('acknowledges a successful non-indexed $name response', () async {
      final storage = CoreStorage();
      final client = newClient();
      await client.op.init('compatible-ack', storage: storage);
      await client.impl.track('compatible-ack', 'accepted');
      fetch.mockResponse(body, status: status);
      await client.op.flush();
      expect(coreQueue(storage, 'compatible-ack'), isEmpty);
    });
  }

  final permanent = <(int, String, String)>[
    (400, '{}', 'http_400'),
    (401, '{}', 'http_401'),
    (422, '{}', 'http_422'),
    (200, jsonEncode({'success': false}), 'ingest_rejected'),
  ];
  for (final (status, body, code) in permanent) {
    test(
        'durably drops permanent rejection $status and reports only its ID '
        'and code', () async {
      final storage = CoreStorage();
      final rejected = <Map<String, Object?>>[];
      final queueAtCallback = <List<QueueItem>>[];
      final client = newClient();
      await client.op.init(
        'permanent-rejection',
        storage: storage,
        onIngestRejected: (item) {
          // RN asserts inside the callback; the SDK swallows callback
          // errors, so the state is captured and asserted afterwards.
          queueAtCallback.add(coreQueue(storage, 'permanent-rejection'));
          rejected.add(rejectionMap(item));
        },
      );
      await client.impl.track('permanent-rejection', 'bad-event');
      final distinctId =
          coreQueue(storage, 'permanent-rejection')[0]['distinct_id'];
      fetch.mockResponse(body, status: status);
      final flushing = client.op.flush();
      await timers.advance(const Duration(milliseconds: 62000));
      await flushing;
      expect(coreQueue(storage, 'permanent-rejection'), isEmpty);
      expect(rejected, [
        {'distinctId': distinctId, 'code': code},
      ]);
      expect(queueAtCallback, [isEmpty]);
    });
  }

  test(
      'discards a repeatedly malformed indexed acknowledgement on the fifth '
      'flush and allows the next batch', () async {
    final storage = CoreStorage();
    final rejected = <Map<String, Object?>>[];
    final client = newClient();
    await client.op.init(
      'invalid-ack-limit',
      storage: storage,
      onIngestRejected: (item) => rejected.add(rejectionMap(item)),
    );
    client.op.setFlushBatchSize(1);
    await client.impl.track('invalid-ack-limit', 'bad-event');
    await client.impl.track('invalid-ack-limit', 'next-event');
    final distinctId =
        coreQueue(storage, 'invalid-ack-limit')[0]['distinct_id'];
    final malformed = jsonEncode({
      'success': true,
      'accepted': 0,
      'rejected': <Object?>[],
    });
    fetch.mockResponse(malformed);
    for (var i = 0; i < 4; i += 1) {
      await client.op.flush();
    }
    expect(coreQueue(storage, 'invalid-ack-limit'), hasLength(2));
    fetch
      ..mockResponseOnce(malformed)
      ..mockResponse(jsonEncode({'success': true}));
    await client.op.flush();
    expect(coreQueue(storage, 'invalid-ack-limit'), isEmpty);
    expect(rejected, [
      {'distinctId': distinctId, 'code': 'invalid_acknowledgment'},
    ]);
  });

  test(
      'limits malformed acknowledgments for the same head when new events '
      'join the batch', () async {
    const token = 'growing-invalid-batch';
    final storage = CoreStorage();
    final rejected = <Map<String, Object?>>[];
    final client = newClient();
    await client.op.init(
      token,
      storage: storage,
      onIngestRejected: (item) => rejected.add(rejectionMap(item)),
    );
    await client.op.track('head-event');
    final headId = coreQueue(storage, token)[0]['distinct_id'];
    fetch.mockResponse(jsonEncode({
      'success': true,
      'accepted': 0,
      'rejected': <Object?>[],
    }));

    for (var attempt = 0; attempt < 5; attempt += 1) {
      await client.op.track('tail-event-$attempt');
      await client.op.flush();
    }

    expect(coreQueue(storage, token), isEmpty);
    expect(
      rejected,
      contains(
          equals({'distinctId': headId, 'code': 'invalid_acknowledgment'})),
    );
  });

  test('stops rejection callbacks when the first callback opts out', () async {
    final rejected = <Map<String, Object?>>[];
    final client = newClient();
    Future<void>? optingOut;
    await client.op.init(
      'callback-opt-out',
      storage: CoreStorage(),
      onIngestRejected: (item) {
        rejected.add(rejectionMap(item));
        optingOut = client.op.optOutTracking();
      },
    );
    await client.op.track('first-event');
    await client.op.track('second-event');
    fetch.mockResponse(jsonEncode({
      'success': true,
      'accepted': 0,
      'rejected': [
        {'index': 0, 'code': 'invalid_event'},
        {'index': 1, 'code': 'invalid_event'},
      ],
    }));

    await client.op.flush();
    await optingOut;

    expect(rejected, hasLength(1));
    expect(client.op.hasOptedOutTracking(), isTrue);
  });

  test(
      'retains a saved explicit opt-out even if a rolled-back SDK rewrites '
      'the legacy flag', () async {
    final values = <String, String>{};
    final storage = CoreStorage(values);
    final client = newClient();
    await client.op.init('rollback-consent', storage: storage);
    await client.op.optOutTracking();
    values[optOutKey('rollback-consent')] = 'false';
    await restart();
    final next = newClient();
    await next.op.init('rollback-consent', storage: storage);
    expect(next.op.hasOptedOutTracking(), isTrue);
  });

  for (final method in ['reset', 'setVisitorId']) {
    test(
        'queues an announced session end under its previous identity before '
        'background $method', () async {
      final storage = CoreStorage();
      final client = newClient();
      await client.op.init(
        'background-identity',
        storage: storage,
        trackAutomaticEvents: true,
      );
      client.op.setFlushOnBackground(false);
      final originalVisitor = client.op.getVisitorId();
      client.emitBackground();
      await coreSettle();
      if (method == 'reset') {
        await client.op.reset();
      } else {
        await client.op.setVisitorId('replacement-visitor');
      }
      final ends = coreQueue(storage, 'background-identity')
          .where((item) => item['event'] == r'$mobile_session_end')
          .toList();
      expect(ends, hasLength(1));
      expect(ends[0]['visitor_id'], originalVisitor);
    });
  }

  test('captures a screen call time before an earlier storage write completes',
      () async {
    final storage = CoreStorage();
    final client = newClient();
    await client.op.init('screen-call-time', storage: storage);
    final write = Completer<void>();
    var blocked = false;
    storage.setItemOverride = (key, value) async {
      if (key.endsWith('_QUEUE') && !blocked) {
        blocked = true;
        await write.future;
      }
      return storage.baseSetItem(key, value);
    };
    final tracking = client.op.track('earlier');
    await coreTickUntil(() => blocked);
    final calledAt = coreIso(client.wallNow);
    final screen = client.op.trackScreen('Home');
    client.wallOffsetMs += 5000;
    write.complete();
    await Future.wait([tracking, screen]);
    final screenView =
        _find(coreQueue(storage, 'screen-call-time'), r'$mobile_screen_view');
    expect(screenView, isNotNull);
    expect(
      (screenView!['eventProperties']! as Map)['mobile_occurred_at'],
      calledAt,
    );
  });

  test('rejects explicit success false even when indexed fields are present',
      () async {
    final storage = CoreStorage();
    final rejected = <Map<String, Object?>>[];
    final client = newClient();
    await client.op.init(
      'false-indexed',
      storage: storage,
      onIngestRejected: (item) => rejected.add(rejectionMap(item)),
    );
    await client.op.track('bad-event');
    fetch.mockResponse(jsonEncode({
      'success': false,
      'accepted': 1,
      'rejected': <Object?>[],
    }));
    await client.op.flush();
    expect(coreQueue(storage, 'false-indexed'), isEmpty);
    expect(rejected, [
      {'distinctId': isA<String>(), 'code': 'ingest_rejected'},
    ]);
  });

  for (final kind in ['invalid JSON', 'unreadable row']) {
    test('recovers initialization after a saved event queue has $kind',
        () async {
      final values = {queueKey('unusable-queue', '/ingest'): '{broken'};
      final storage = CoreStorage(values);
      storage.getItemOverride = (key) {
        if (kind == 'unreadable row' &&
            key == queueKey('unusable-queue', '/ingest')) {
          return Future<String?>.error(StateError('row too large'));
        }
        return storage.baseGetItem(key);
      };
      final client = newClient();
      await client.op.init('unusable-queue', storage: storage);
      await client.op.track('next-event');
      expect(
        _events(
          jsonDecode(values[queueKey('unusable-queue', '/ingest')]!)
              as List<Object?>,
        ),
        ['next-event'],
      );
    });
  }

  test(
      'cancels an old upload when reinitializing and leaves its captured '
      'event available for retry', () async {
    final storage = CoreStorage();
    final client = newClient();
    await client.op.init('reinit-upload', storage: storage);
    await client.op.track('captured-event');
    fetch.mockImplementation(CoreFetch.pendingForever);
    final flushing = client.op.flush();
    await coreTickUntil(() => fetch.callCount == 1);
    final reinitializing = client.op.init('reinit-upload', storage: storage);
    final aborted = fetch.callClients.single.closed;
    expect(aborted, isTrue);
    await Future.wait([flushing, reinitializing]);
    expect(
      coreQueue(storage, 'reinit-upload').map((item) => item['event']),
      ['captured-event'],
    );
  });

  test(
      'discards both old pending flushes on re-init while preserving their '
      'captured event', () async {
    const token = 'pending-flush-reinit';
    final storage = CoreStorage();
    final client = newClient();
    await client.op.init(token, storage: storage);
    await client.op.track('captured-event');
    final response = Completer<http.StreamedResponse>();
    final ack = jsonEncode({'success': true});
    fetch
      ..mockImplementationOnce((_) => response.future)
      ..mockResponse(ack);
    final first = client.op.flush();
    await coreTickUntil(() => fetch.callCount == 1);
    final second = client.op.flush();
    await coreSettle();
    await client.op.init(token, storage: storage);
    response.complete(coreStreamed(http.Response(ack, 200)));
    await Future.wait([first, second]);
    expect(fetch.callCount, 1);
    expect(
      coreQueue(storage, token).map((item) => item['event']),
      ['captured-event'],
    );
  });

  for (final kind in ['invalid JSON', 'unreadable row']) {
    test(
        'preserves the offline event array when auxiliary queue metadata has '
        '$kind', () async {
      const token = 'offline-queue-metadata';
      final pending = <Map<String, Object?>>[
        {
          'event': r'$mobile_first_open',
          'distinct_id': 'offline-first-open',
          'visitor_id': 'offline-visitor',
          'defaultProperties': {'sid': '1791201600000'},
          'eventProperties': {
            'mobile_contract_version': 1,
            'mobile_occurred_at': '2026-10-05T12:00:00.000Z',
          },
        },
        {
          'event': 'offline-event',
          'distinct_id': 'offline-event-id',
          'visitor_id': 'offline-visitor',
        },
      ];
      final values = {
        queueKey(token, '/ingest'): jsonEncode(pending),
        queueMetadataKey(token, '/ingest'): '{broken',
      };
      final storage = CoreStorage(values);
      storage.getItemOverride = (key) {
        if (kind == 'unreadable row' &&
            key == queueMetadataKey(token, '/ingest')) {
          return Future<String?>.error(StateError('metadata unavailable'));
        }
        return storage.baseGetItem(key);
      };
      final client = newClient();
      await client.op.init(token, storage: storage);
      expect(coreQueue(storage, token), pending);
      expect(
        OursPrivacyQueueManager.of(storage)
            .hasAcceptedFirstOpen(token, '/ingest'),
        isTrue,
      );
      await client.op.track('following-event');
      final stored =
          jsonDecode(values[queueKey(token, '/ingest')]!) as List<Object?>;
      expect(stored.sublist(0, 2), pending);
      expect(_events(stored), [
        r'$mobile_first_open',
        'offline-event',
        'following-event',
      ]);
    });
  }

  test('keeps a durably queued event when its auxiliary metadata write fails',
      () async {
    const token = 'queue-metadata-write';
    final values = <String, String>{};
    final storage = CoreStorage(values);
    var failedMetadata = false;
    storage.setItemOverride = (key, value) {
      if (key == queueMetadataKey(token, '/ingest') && !failedMetadata) {
        failedMetadata = true;
        return Future<void>.error(StateError('metadata write unavailable'));
      }
      return storage.baseSetItem(key, value);
    };
    final client = newClient();
    await client.op.init(token, storage: storage);
    // RN: `client.track` resolves; the facade always completes, so the
    // underlying operation is awaited to check it did not fail.
    await expectLater(client.impl.track(token, 'first-event'), completes);
    await client.op.track('second-event');
    expect(
      _events(jsonDecode(values[queueKey(token, '/ingest')]!) as List<Object?>),
      ['first-event', 'second-event'],
    );
  });

  test(
      'reports a durably removed rejection when auxiliary metadata cannot be '
      'saved', () async {
    const token = 'rejection-metadata-write';
    final values = <String, String>{};
    final storage = CoreStorage(values);
    final rejected = <Map<String, Object?>>[];
    final storedAtCallback = <Object?>[];
    final client = newClient();
    await client.op.init(
      token,
      storage: storage,
      onIngestRejected: (item) {
        storedAtCallback.add(jsonDecode(values[queueKey(token, '/ingest')]!));
        rejected.add(rejectionMap(item));
      },
    );
    await client.op.track('rejected-event');
    storage.setItemOverride = (key, value) {
      if (key == queueMetadataKey(token, '/ingest')) {
        return Future<void>.error(StateError('metadata write unavailable'));
      }
      return storage.baseSetItem(key, value);
    };
    fetch.mockResponse(jsonEncode({'success': false}));
    await client.op.flush();
    expect(coreQueue(storage, token), isEmpty);
    expect(rejected, [
      {'distinctId': isA<String>(), 'code': 'ingest_rejected'},
    ]);
    expect(storedAtCallback, [isEmpty]);
    await client.op.flush();
    expect(fetch.callCount, 1);
  });

  test(
      'keeps a newer opt-out while an older opt-in persistence failure is '
      'handled', () async {
    const token = 'failed-older-opt-in';
    final values = <String, String>{};
    final storage = CoreStorage(values);
    final client = newClient();
    await client.op.init(token, storage: storage);
    final oldWrite = Completer<void>();
    final newWrite = Completer<void>();
    var oldWriteStarted = false;
    storage.setItemOverride = (key, value) async {
      if (key == optOutKey(token)) {
        if (value == 'false') {
          oldWriteStarted = true;
          await oldWrite.future;
        } else {
          await newWrite.future;
        }
      }
      return storage.baseSetItem(key, value);
    };
    final optingIn = client.op.optInTracking();
    unawaited(optingIn.then<void>((_) {}, onError: (Object _) {}));
    await coreTickUntil(() => oldWriteStarted);
    final optingOut = client.op.optOutTracking();
    expect(client.op.hasOptedOutTracking(), isTrue);
    oldWrite.completeError(StateError('older write failed'));
    await expectLater(optingIn, _throwsMessage('older write failed'));
    final optedOutWhileWritePending = client.op.hasOptedOutTracking();
    newWrite.complete();
    await optingOut;
    expect(optedOutWhileWritePending, isTrue);
    expect(values[optOutKey(token)], 'true');
  });
}
