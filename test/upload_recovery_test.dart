// Port of __tests__/upload-recovery.test.js (React Native SDK).
//
// Upload response recovery through the real core, queue, persistence and
// network, with the HTTP boundary faked by [CoreFetch] (RN's
// `jest-fetch-mock`) and backoff timers by [CoreFakeTimers] (Jest fake
// timers). RN's `AbortSignal.aborted` is the SDK-owned client being closed
// by `cancelPendingUploads`; RN's `jest.resetModules()` "restart" is
// `resetOursPrivacyForTesting()` followed by a new core over the same
// storage.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:ours_privacy/src/config.dart';
import 'package:ours_privacy/src/core.dart';
import 'package:ours_privacy/src/persistent.dart';
import 'package:ours_privacy/src/queue.dart';
import 'package:ours_privacy/src/testing.dart';

import 'helpers/core_harness.dart';

const _token = 'upload-token';
const _type = '/ingest';
const _queueKey = 'OURSPRIVACY_upload-token_/ingest_QUEUE';

final Map<String, Object?> _firstEvent = {
  'event': 'appointment_booked',
  'distinct_id': 'first-event',
  'visitor_id': 'visitor-1',
  'isManuallySetId': false,
  'eventProperties': {
    'mobile_contract_version': 1,
    'mobile_occurred_at': '2026-10-05T12:00:00.000Z',
  },
  'userProperties': null,
  'defaultProperties': {'sid': '1791201600000', 'os_name': 'iOS'},
};

Map<String, Object?> _with(
        Map<String, Object?> event, Map<String, Object?> o) =>
    {...event, ...o};

/// RN `createStorage()`: memory storage whose queue writes can be failed.
class _Storage extends CoreStorage {
  _Storage() {
    setItemOverride = (key, value) {
      if (key == _queueKey && failQueueWrites) {
        return Future<void>.error(StateError('Queue write failed'));
      }
      return baseSetItem(key, value);
    };
  }

  bool failQueueWrites = false;
}

class _Harness {
  _Harness({
    required this.core,
    required this.config,
    required this.persistent,
    required this.storage,
  });

  final OursPrivacyCore core;
  final OursPrivacyConfig config;
  final OursPrivacyPersistent persistent;
  final _Storage storage;
  final List<Map<String, Object?>> rejected = [];
  final List<List<Object?>> removalSnapshots = [];

  List<Object?> savedItems() => storage.savedItems(_token);

  List<QueueItem> queuedItems() =>
      OursPrivacyQueueManager.of(storage).getQueue(_token, _type);

  String? responseMode() =>
      OursPrivacyQueueManager.of(storage).getResponseMode(_token, _type)?.name;
}

void main() {
  late CoreFetch fetch;
  late CoreFakeTimers timers;

  Future<_Harness> startCore([
    _Storage? storage,
    List<Map<String, Object?>>? items,
  ]) async {
    final store = storage ?? _Storage();
    final core = OursPrivacyCore(
      storage: store,
      network: fetch.network(timers),
      timerFactory: timers.create,
    );
    final harness = _Harness(
      core: core,
      config: OursPrivacyConfig.instance,
      persistent: OursPrivacyPersistent.of(store),
      storage: store,
    );
    harness.config.setServerURL(_token, 'https://upload.example.test');
    harness.config.setOnIngestRejected(_token, (result) {
      harness.removalSnapshots.add(harness.savedItems());
      harness.rejected.add({
        'distinctId': result.distinctId,
        'code': result.code,
      });
    });
    await harness.persistent.initializationComplete(_token);
    await core.initialize(_token);
    for (final item in items ?? [_firstEvent]) {
      await core.addToOursPrivacyQueue(_token, _type, item);
    }
    return harness;
  }

  group('upload response recovery through the real core and fetch boundary',
      () {
    setUp(() {
      resetOursPrivacyForTesting();
      fetch = CoreFetch();
      timers = CoreFakeTimers();
    });

    tearDown(resetOursPrivacyForTesting);

    test(
        'retains HTML 200 until the fifth flush, then durably rejects the head',
        () async {
      final harness = await startCore();
      fetch.mockResponse('<html>upstream error</html>');

      for (var attempt = 1; attempt <= 4; attempt += 1) {
        await harness.core.flush(_token);
        expect(fetch.callCount, attempt);
        expect(harness.queuedItems(), [_firstEvent]);
        expect(harness.savedItems(), [_firstEvent]);
        expect(harness.rejected, isEmpty);
      }

      await harness.core.flush(_token);

      expect(fetch.callCount, 5);
      expect(
        fetch.sentDistinctIds,
        List.filled(5, ['first-event']),
      );
      expect(harness.queuedItems(), isEmpty);
      expect(harness.savedItems(), isEmpty);
      expect(harness.rejected, [
        {'distinctId': 'first-event', 'code': 'invalid_acknowledgment'},
      ]);
      expect(harness.removalSnapshots, [<Object?>[]]);
    });

    test(
        'retains HTTP 403 beyond five flushes while using the existing '
        'network backoff', () async {
      final harness = await startCore();
      fetch.mockResponse('<html>forbidden</html>', status: 403);

      for (var flush = 1; flush <= 6; flush += 1) {
        final pending = harness.core.flush(_token);
        await timers.advance(const Duration(milliseconds: 62000));
        await pending;

        expect(harness.queuedItems(), [_firstEvent]);
        expect(harness.savedItems(), [_firstEvent]);
        expect(harness.rejected, isEmpty);
        expect(fetch.callCount, flush * 6);
      }
    });

    const invalidBodies = <String, String>{
      'truncated JSON': '{"success":',
      'null': 'null',
      'array': '[]',
      'string': '"accepted"',
      'number': '42',
      'boolean': 'true',
      'whitespace': ' \n\t',
      'incomplete indexed object': '{"success":true,"accepted":1}',
    };
    for (final MapEntry(key: name, value: body) in invalidBodies.entries) {
      test('caps invalid acknowledgment for a $name body', () async {
        final harness = await startCore();
        fetch.mockResponse(body);

        for (var attempt = 1; attempt <= 4; attempt += 1) {
          await harness.core.flush(_token);
          expect(harness.savedItems(), [_firstEvent]);
          expect(harness.queuedItems(), [_firstEvent]);
          expect(harness.rejected, isEmpty);
          expect(fetch.callCount, attempt);
        }
        await harness.core.flush(_token);

        expect(harness.savedItems(), isEmpty);
        expect(harness.queuedItems(), isEmpty);
        expect(harness.rejected, [
          {'distinctId': 'first-event', 'code': 'invalid_acknowledgment'},
        ]);
        expect(fetch.callCount, 5);
      });
    }

    const compatible = <(String, String, int)>[
      ('empty HTTP 200', '', 200),
      // RN passes a null body; package:http has no null body, so it is ''.
      ('empty HTTP 204', '', 204),
      ('empty object', '{}', 200),
      (
        'unknown keys without visitor acknowledgment',
        '{"future_field":42}',
        200
      ),
      ('success without visitor acknowledgment', '{"success":true}', 200),
    ];
    for (final (name, body, status) in compatible) {
      test('durably acknowledges a compatible $name response', () async {
        final harness = await startCore();
        fetch.mockResponseOnce(body, status: status);

        await harness.core.flush(_token);

        expect(harness.savedItems(), isEmpty);
        expect(harness.queuedItems(), isEmpty);
        expect(harness.responseMode(), 'legacy');
        expect(harness.rejected, isEmpty);
        expect(fetch.callCount, 1);
      });
    }

    test(
        'preserves indexed acknowledgments and reports only rejected IDs '
        'after durable removal', () async {
      final secondEvent = _with(_firstEvent, {'distinct_id': 'second-event'});
      final harness = await startCore(_Storage(), [_firstEvent, secondEvent]);
      fetch.mockResponseOnce(
        '{"success":true,"accepted":1,"rejected":[{"index":1,"code":"invalid_session"}],"future_field":42}',
      );

      await harness.core.flush(_token);

      expect(harness.savedItems(), isEmpty);
      expect(harness.queuedItems(), isEmpty);
      expect(harness.responseMode(), 'indexed');
      expect(harness.rejected, [
        {'distinctId': 'second-event', 'code': 'invalid_session'},
      ]);
      expect(harness.removalSnapshots, [<Object?>[]]);
      expect(fetch.callCount, 1);
    });

    test(
        'keeps the malformed cap on the same head as its batch grows and '
        'gives the next head five attempts', () async {
      final appendedEvent =
          _with(_firstEvent, {'distinct_id': 'appended-event'});
      final nextEvent = _with(_firstEvent, {
        'distinct_id': 'next-event',
        'visitor_id': 'visitor-2',
      });
      final harness = await startCore();
      fetch.mockResponse('<html>upstream error</html>');
      await harness.core.flush(_token);
      await harness.core.addToOursPrivacyQueue(_token, _type, appendedEvent);
      await harness.core.addToOursPrivacyQueue(_token, _type, nextEvent);

      for (var attempt = 2; attempt <= 4; attempt += 1) {
        await harness.core.flush(_token);
        expect(harness.savedItems(), [_firstEvent, appendedEvent, nextEvent]);
        expect(harness.rejected, isEmpty);
      }
      await harness.core.flush(_token);

      expect(fetch.callCount, 6);
      expect(harness.savedItems(), [nextEvent]);
      expect(harness.queuedItems(), [nextEvent]);
      expect(harness.rejected, [
        {'distinctId': 'first-event', 'code': 'invalid_acknowledgment'},
        {'distinctId': 'appended-event', 'code': 'invalid_acknowledgment'},
      ]);
      expect(harness.removalSnapshots, [
        [nextEvent],
        [nextEvent],
      ]);

      for (var attempt = 2; attempt <= 4; attempt += 1) {
        await harness.core.flush(_token);
        expect(harness.savedItems(), [nextEvent]);
        expect(harness.rejected, hasLength(2));
      }
      await harness.core.flush(_token);

      expect(harness.savedItems(), isEmpty);
      expect(harness.queuedItems(), isEmpty);
      expect(harness.rejected, [
        {'distinctId': 'first-event', 'code': 'invalid_acknowledgment'},
        {'distinctId': 'appended-event', 'code': 'invalid_acknowledgment'},
        {'distinctId': 'next-event', 'code': 'invalid_acknowledgment'},
      ]);
      expect(fetch.sentDistinctIds, [
        ['first-event'],
        ...List.filled(4, ['first-event', 'appended-event']),
        ...List.filled(5, ['next-event']),
      ]);
    });

    test(
        'retains rows without callbacks when capped removal fails and '
        'recovers them after restart', () async {
      final harness = await startCore();
      fetch.mockResponse('<html>upstream error</html>');
      for (var attempt = 1; attempt <= 4; attempt += 1) {
        await harness.core.flush(_token);
      }
      harness.storage.failQueueWrites = true;
      await harness.core.flush(_token);
      await harness.core.flush(_token);

      expect(harness.savedItems(), [_firstEvent]);
      expect(harness.queuedItems(), [_firstEvent]);
      expect(harness.rejected, isEmpty);
      expect(fetch.callCount, 6);

      harness.core.stopProcessingQueue();
      resetOursPrivacyForTesting();
      harness.storage.failQueueWrites = false;
      // In RN the fetch mock's call count is cleared across the restart
      // (instrumented: 6 before, 0 after the restarted startCore, 5 at the
      // end), so its final `toHaveBeenCalledTimes(5)` counts only the
      // restarted core's requests. Count from here to match.
      final callsBeforeRestart = fetch.callCount;
      final restarted = await startCore(harness.storage, []);
      expect(restarted.queuedItems(), [_firstEvent]);
      for (var attempt = 1; attempt <= 4; attempt += 1) {
        await restarted.core.flush(_token);
        expect(restarted.savedItems(), [_firstEvent]);
        expect(restarted.rejected, isEmpty);
      }
      await restarted.core.flush(_token);

      expect(restarted.savedItems(), isEmpty);
      expect(restarted.queuedItems(), isEmpty);
      expect(restarted.rejected, [
        {'distinctId': 'first-event', 'code': 'invalid_acknowledgment'},
      ]);
      expect(restarted.removalSnapshots, [<Object?>[]]);
      expect(harness.rejected, isEmpty);
      expect(fetch.callCount - callsBeforeRestart, 5);
    });

    test(
        'does not charge HTTP 403 backoff attempts against a nearly capped '
        'malformed head', () async {
      final harness = await startCore();
      fetch.mockResponse('<html>upstream error</html>');
      for (var attempt = 1; attempt <= 4; attempt += 1) {
        await harness.core.flush(_token);
      }
      fetch.mockResponse('<html>forbidden</html>', status: 403);
      final pending = harness.core.flush(_token);
      await timers.advance(const Duration(milliseconds: 62000));
      await pending;

      expect(harness.savedItems(), [_firstEvent]);
      expect(harness.queuedItems(), [_firstEvent]);
      expect(harness.rejected, isEmpty);
      expect(fetch.callCount, 10);

      fetch.mockResponse('<html>upstream error</html>');
      await harness.core.flush(_token);

      expect(harness.savedItems(), isEmpty);
      expect(harness.rejected, [
        {'distinctId': 'first-event', 'code': 'invalid_acknowledgment'},
      ]);
      expect(fetch.callCount, 11);
    });

    const pendingBodies = <String, String>{
      'indexed rejection':
          '{"success":true,"accepted":0,"rejected":[{"index":0,"code":"invalid_session"}]}',
      'malformed acknowledgment': '<html>upstream error</html>',
    };
    for (final MapEntry(key: name, value: body) in pendingBodies.entries) {
      test(
          'cancels a pending $name body on opt-out without removal or '
          'callbacks', () async {
        final harness = await startCore();
        final readingBody = Completer<void>();
        final releaseBody = Completer<void>();
        fetch.mockImplementationOnce((request) async {
          // The response body is read only after `releaseBody` (RN replaces
          // `response.text()`).
          late final StreamController<List<int>> controller;
          controller = StreamController<List<int>>(onListen: () {
            if (!readingBody.isCompleted) readingBody.complete();
            unawaited(releaseBody.future.then((_) async {
              controller.add(utf8.encode(body));
              await controller.close();
            }));
          });
          return http.StreamedResponse(controller.stream, 200);
        });
        final pending = harness.core.flush(_token);
        await readingBody.future;
        harness.persistent.updateOptedOut(_token, true);
        harness.core.cancelPendingUploads(_token);
        final abortedAtCancel = fetch.callClients.single.closed;
        await harness.persistent.persistOptedOut(_token);
        releaseBody.complete();
        await pending;
        await harness.core.flush(_token);

        expect(abortedAtCancel, isTrue);
        expect(fetch.callClients.single.closed, isTrue);
        expect(harness.savedItems(), [_firstEvent]);
        expect(harness.queuedItems(), [_firstEvent]);
        expect(harness.rejected, isEmpty);
        expect(fetch.callCount, 1);
      });
    }

    test(
        'cancels HTTP 403 backoff on opt-out without retrying or reporting '
        'rejection', () async {
      final harness = await startCore();
      fetch.mockResponse('<html>forbidden</html>', status: 403);
      final pending = harness.core.flush(_token);
      await timers.advance(Duration.zero);
      expect(fetch.callCount, 1);
      final client = fetch.callClients[0];

      harness.persistent.updateOptedOut(_token, true);
      harness.core.cancelPendingUploads(_token);
      final abortedAtCancel = client.closed;
      await harness.persistent.persistOptedOut(_token);
      await pending;
      await timers.advance(const Duration(milliseconds: 62000));
      await harness.core.flush(_token);

      expect(abortedAtCancel, isTrue);
      expect(harness.savedItems(), [_firstEvent]);
      expect(harness.queuedItems(), [_firstEvent]);
      expect(harness.rejected, isEmpty);
      expect(fetch.callCount, 1);
    });
  });
}
