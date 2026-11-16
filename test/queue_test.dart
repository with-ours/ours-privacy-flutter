// Port of __tests__/queue.test.js (React Native SDK).
//
// React Native mocks the persistence module (`loadQueue` resolves `[]`,
// `saveQueue` is a spy). Dart cannot mock the shared persistence instance, so
// these tests run the real persistence over [CoreStorage] and assert on what
// was written to storage instead of on the spy's arguments. The queue rows
// are stored as a bare JSON array and the response mode under the separate
// metadata key (the layout RN's `compatibility.test.js` requires), so RN's
// `saveQueue(token, type, objectContaining({items, responseMode}))` becomes
// "rows written to the queue key and `responseMode` written to the metadata
// key".
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ours_privacy/src/constants.dart';
import 'package:ours_privacy/src/queue.dart';
import 'package:ours_privacy/src/testing.dart';

import 'helpers/core_harness.dart';

void main() {
  group('OursPrivacyQueueManager', () {
    const token = 'testToken';
    const type = eventsQueueType;
    late CoreStorage storage;
    late OursPrivacyQueueManager queueManager;

    Object? storedRows() {
      final value = storage.values[queueKey(token, type)];
      return value == null ? null : jsonDecode(value);
    }

    Map<String, Object?> storedMetadata() =>
        jsonDecode(storage.values[queueMetadataKey(token, type)]!)
            as Map<String, Object?>;

    setUp(() async {
      resetOursPrivacyForTesting();
      storage = CoreStorage();
      queueManager = OursPrivacyQueueManager.of(storage);
      await queueManager.clearQueue(token, type);
      storage.setCalls.clear();
    });

    tearDown(resetOursPrivacyForTesting);

    test('initializes the queue correctly', () async {
      await queueManager.initialize(token, type);
      expect(queueManager.getQueue(token, type), isEmpty);
    });

    test('enqueue adds data to the queue and updates storage', () async {
      final data = {'test': 'data'};

      await queueManager.initialize(token, type);
      await queueManager.enqueue(token, type, data);

      expect(
        storage.setCalls.where((call) => call.$1 == queueKey(token, type)),
        isNotEmpty,
      );
      expect(storedRows(), isA<List<Object?>>());
      expect(storedRows(), [data]);
      expect(queueManager.getQueue(token, type), [data]);
    });

    test('splices the queue correctly', () async {
      await queueManager.enqueue(token, type, {'data': 'sample1'});
      await queueManager.enqueue(token, type, {'data': 'sample2'});

      await queueManager.spliceQueue(token, type, 0, 1);

      final queue = queueManager.getQueue(token, type);
      expect(queue.length, 1);
      expect(queue, [
        {'data': 'sample2'},
      ]);
    });

    test('clears the queue correctly', () async {
      await queueManager.enqueue(token, type, {'data': 'sample'});
      await queueManager.clearQueue(token, type);

      final queue = queueManager.getQueue(token, type);
      expect(queue, isEmpty);
    });

    test('keeps indexed response mode with acknowledged removal and reload',
        () async {
      await queueManager.initialize(token, type);
      await queueManager.enqueue(token, type, {
        'event': 'appointment_booked',
        'distinct_id': 'booked-id',
      });

      await queueManager.removeByIds(
        token,
        type,
        ['booked-id'],
        OursPrivacyResponseMode.indexed,
      );
      expect(queueManager.getQueue(token, type), isEmpty);
      expect(
        queueManager.getResponseMode(token, type),
        OursPrivacyResponseMode.indexed,
      );
      // RN: saveQueue last called with {items: [], responseMode: 'indexed'}.
      expect(storage.setCalls.last.$1, queueMetadataKey(token, type));
      expect(storedRows(), isEmpty);
      expect(storedMetadata()['responseMode'], 'indexed');

      await queueManager.clearQueue(token, type);
      expect(
        queueManager.getResponseMode(token, type),
        OursPrivacyResponseMode.indexed,
      );

      // Reload: a fresh queue manager over the same storage restores it.
      OursPrivacyQueueManager.resetForTesting();
      final reloaded = OursPrivacyQueueManager.of(storage);
      await reloaded.initialize(token, type);
      expect(reloaded.getQueue(token, type), isEmpty);
      expect(
        reloaded.getResponseMode(token, type),
        OursPrivacyResponseMode.indexed,
      );
    });
  });

  test('a legacy ACK replaces indexed response history', () async {
    resetOursPrivacyForTesting();
    addTearDown(resetOursPrivacyForTesting);
    final queueManager = OursPrivacyQueueManager.of(CoreStorage());
    await queueManager.initialize('mode-transition', '/ingest');
    await queueManager.enqueue('mode-transition', '/ingest', {
      'distinct_id': 'first',
    });
    await queueManager.removeByIds(
      'mode-transition',
      '/ingest',
      ['first'],
      OursPrivacyResponseMode.indexed,
    );
    await queueManager.enqueue('mode-transition', '/ingest', {
      'distinct_id': 'second',
    });
    await queueManager.removeByIds(
      'mode-transition',
      '/ingest',
      ['second'],
      OursPrivacyResponseMode.legacy,
    );
    expect(
      queueManager.getResponseMode('mode-transition', '/ingest'),
      OursPrivacyResponseMode.legacy,
    );
  });
}
