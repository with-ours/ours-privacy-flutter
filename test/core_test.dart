// Port of __tests__/core.test.js (React Native SDK).
//
// React Native replaces the queue manager, persistence, network and config
// modules with Jest mocks. Dart cannot swap those modules, so:
// - the network is a [CoreScriptedNetwork] injected into `OursPrivacyCore`
//   (the `sendRequest` mock);
// - the queue manager and persistence are the real ones over [CoreStorage];
//   RN's `removeByIds` call assertions are checked against the durable
//   removals reconstructed from storage writes ([CoreStorage.removals]), and
//   `removeByIds.mockRejectedValueOnce` becomes a failing queue write;
// - config values (`getFlushBatchSize`, `getIsManuallySetId`,
//   `getOnIngestRejected`) are set on the real per-token config;
// - `Platform.OS` is forced through `OursPrivacyDeviceInfo.debugOverride`
//   (the Dart core does not branch on platform, which is what these cases
//   pin down);
// - `jest.spyOn(JSON, 'stringify')` throwing becomes an event with a value
//   that `jsonEncode` rejects.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ours_privacy/src/config.dart';
import 'package:ours_privacy/src/constants.dart';
import 'package:ours_privacy/src/core.dart';
import 'package:ours_privacy/src/mobile_payload.dart';
import 'package:ours_privacy/src/network.dart';
import 'package:ours_privacy/src/persistent.dart';
import 'package:ours_privacy/src/queue.dart';
import 'package:ours_privacy/src/testing.dart';

import 'helpers/core_harness.dart';

const _platforms = <String, OursPrivacyDeviceInfo>{
  'ios': StaticDeviceInfo.ios(),
  'android': StaticDeviceInfo.android(),
  'web': StaticDeviceInfo.web(),
};

OursPrivacyHttpError _http(int code) =>
    OursPrivacyHttpError('HTTP error! status: $code', code);

Map<String, Object?> _rejection(OursPrivacyIngestRejection r) =>
    {'distinctId': r.distinctId, 'code': r.code};

void main() {
  group('OursPrivacyQueueManager', () {
    const token = 'test-token';
    const type = eventsQueueType;
    final data = <String, Object?>{
      'event': 'testEvent',
      'distinct_id': 'event-1',
    };

    late CoreStorage storage;
    late CoreScriptedNetwork network;
    late List<OursPrivacyIngestRejection> rejections;
    OursPrivacyConfig config() => OursPrivacyConfig.instance;

    OursPrivacyCore newCore() =>
        OursPrivacyCore(storage: storage, network: network);
    OursPrivacyQueueManager queueManager() =>
        OursPrivacyQueueManager.of(storage);
    OursPrivacyPersistent persistent() => OursPrivacyPersistent.of(storage);
    List<Map<String, Object?>> reported() =>
        rejections.map(_rejection).toList();

    void setPlatform(String platform) =>
        OursPrivacyDeviceInfo.debugOverride = _platforms[platform];

    void listenForRejections([void Function(OursPrivacyIngestRejection)? on]) {
      config().setOnIngestRejected(token, (rejection) {
        rejections.add(rejection);
        on?.call(rejection);
      });
    }

    /// RN `queueBatch(items)`: seeds the queue and returns its live view.
    Future<List<QueueItem> Function()> queueBatch(
      List<Map<String, Object?>> items, {
      String queueToken = token,
    }) async {
      await persistent().initializationComplete(queueToken);
      // Seeded as stored rows and loaded, so they reach the core as given
      // (RN mocks `getQueue` to return them verbatim).
      storage.values[queueKey(queueToken, type)] = jsonEncode(items);
      await queueManager().initialize(queueToken, type);
      storage.setCalls.clear();
      storage.committedWrites.clear();
      return () => queueManager().getQueue(queueToken, type);
    }

    List<Map<String, Object?>> removals() => storage.removals(token);

    setUp(() async {
      resetOursPrivacyForTesting();
      setPlatform('ios');
      storage = CoreStorage();
      network = CoreScriptedNetwork();
      rejections = [];
      await persistent().initializationComplete(token);
      storage.setCalls.clear();
    });

    tearDown(resetOursPrivacyForTesting);

    test('initializes the OursPrivacy queue for events', () async {
      await newCore().initialize(token);
      expect(storage.getCalls, contains(queueKey(token, eventsQueueType)));
      expect(queueManager().getQueue(token, eventsQueueType), isEmpty);
    });

    test(
        'adds data to the OursPrivacy queue if not opted out and data is valid',
        () async {
      final queued = await newCore().addToOursPrivacyQueue(token, type, data);
      expect(queued, isTrue);
      expect(queueManager().getQueue(token, type), [data]);
    });

    test('do not add data to the OursPrivacy queue if opted out', () async {
      persistent().updateOptedOut(token, true);
      final queued = await newCore().addToOursPrivacyQueue(token, type, data);
      expect(queued, isFalse);
      expect(queueManager().getQueue(token, type), isEmpty);
      expect(storage.setCalls, isEmpty);
    });

    test('do not add data to the OursPrivacy queue if data is not valid',
        () async {
      // RN mocks JSON.stringify to throw; here the payload itself cannot be
      // encoded.
      final invalid = {...data, 'value': Object()};
      final queued =
          await newCore().addToOursPrivacyQueue(token, type, invalid);
      expect(queued, isFalse);
      expect(queueManager().getQueue(token, type), isEmpty);
      expect(storage.setCalls, isEmpty);
    });

    test('flushes the queue', () async {
      await queueBatch([data]);
      network.mockResolvedValue({
        'success': true,
        'accepted': 1,
        'rejected': <Object?>[],
      });
      await newCore().flush(token);
      expect(network.calls, isNotEmpty);
      expect(removals(), [
        {
          'ids': ['event-1'],
          'mode': 'indexed'
        },
      ]);
    });

    test('do not flush the queue if opted out', () async {
      await queueBatch([data]);
      persistent().updateOptedOut(token, true);
      await newCore().flush(token);
      expect(network.calls, isEmpty);
    });

    test('not flushes the queue if there is no data', () async {
      await queueBatch([]);
      await newCore().flush(token);
      expect(network.calls, isEmpty);
    });

    test('passes isManuallySetId from config to sendRequest', () async {
      config().setIsManuallySetId(token, true);
      await queueBatch([data]);
      network.mockResolvedValue({
        'success': true,
        'accepted': 1,
        'rejected': <Object?>[],
      });

      await newCore().flush(token);

      expect(network.calls.first.isManuallySetId, isTrue);
    });

    test('enqueues event data without adding session metadata', () async {
      final eventData = <String, Object?>{
        'event': 'Purchase',
        'visitor_id': 'uuid-123',
        'distinct_id': 'per-event-uuid',
        'eventProperties': {'price': 99},
        'userProperties': null,
        'defaultProperties': {'device_type': 'mobile'},
      };

      await newCore().addToOursPrivacyQueue(token, type, eventData);

      expect(queueManager().getQueue(token, type), [eventData]);
    });

    test('reports a mixed rejection once after removing only the sent IDs',
        () async {
      final remaining = await queueBatch([
        {'event': 'appointment_booked', 'distinct_id': 'bad-event-id'},
        {'event': 'purchase', 'distinct_id': 'good-event-id'},
        {'event': 'later', 'distinct_id': 'later-event-id'},
      ]);
      config().setFlushBatchSize(token, 2);
      listenForRejections();
      network
        ..mockResolvedValueOnce({
          'success': true,
          'visitor_id': 'v1',
          'accepted': 1,
          'rejected': [
            {'index': 0, 'code': 'mobile_occurred_at_future'},
          ],
        })
        ..mockRejectedValueOnce(Exception('offline'));

      await newCore().flush(token);

      expect(remaining(), [
        {'event': 'later', 'distinct_id': 'later-event-id'},
      ]);
      expect(rejections, hasLength(1));
      expect(reported(), [
        {'distinctId': 'bad-event-id', 'code': 'mobile_occurred_at_future'},
      ]);
      expect(removals(), [
        {
          'ids': ['bad-event-id', 'good-event-id'],
          'mode': 'indexed'
        },
      ]);

      await newCore().flush(token);
      expect(rejections, hasLength(1));
    });

    test('reports every item in an all-rejected batch', () async {
      final remaining = await queueBatch([
        {'event': 'first', 'distinct_id': 'id-1'},
        {'event': 'second', 'distinct_id': 'id-2'},
      ]);
      listenForRejections();
      network.mockResolvedValueOnce({
        'success': true,
        'visitor_id': 'v1',
        'accepted': 0,
        'rejected': [
          {'index': 1, 'code': 'invalid_session'},
          {'index': 0, 'code': 'mobile_occurred_at_future'},
        ],
      });

      await newCore().flush(token);

      expect(remaining(), isEmpty);
      expect(reported(), [
        {'distinctId': 'id-2', 'code': 'invalid_session'},
        {'distinctId': 'id-1', 'code': 'mobile_occurred_at_future'},
      ]);
    });

    final malformed = <String, Map<String, Object?>>{
      'missing success': {'accepted': 1, 'rejected': <Object?>[]},
      'missing accepted': {'success': true, 'rejected': <Object?>[]},
      'missing rejected': {'success': true, 'accepted': 1},
      'negative accepted': {
        'success': true,
        'accepted': -1,
        'rejected': <Object?>[],
      },
      'fractional accepted': {
        'success': true,
        'accepted': 0.5,
        'rejected': <Object?>[],
      },
      'duplicate index': {
        'success': true,
        'accepted': 0,
        'rejected': [
          {'index': 0, 'code': 'invalid'},
          {'index': 0, 'code': 'invalid'},
        ],
      },
      'out-of-range index': {
        'success': true,
        'accepted': 0,
        'rejected': [
          {'index': 1, 'code': 'invalid'},
        ],
      },
      'fractional index': {
        'success': true,
        'accepted': 0,
        'rejected': [
          {'index': 0.5, 'code': 'invalid'},
        ],
      },
      'missing code': {
        'success': true,
        'accepted': 0,
        'rejected': [
          {'index': 0},
        ],
      },
      'mismatched count': {
        'success': true,
        'accepted': 0,
        'rejected': <Object?>[],
      },
    };
    for (final MapEntry(key: name, value: response) in malformed.entries) {
      test('retains the batch for a $name indexed response', () async {
        final remaining = await queueBatch([
          {'event': 'appointment_booked', 'distinct_id': 'id-1'},
        ]);
        listenForRejections();
        network.mockResolvedValue(response);

        await newCore().flush(token);

        expect(remaining(), hasLength(1));
        expect(removals(), isEmpty);
        expect(rejections, isEmpty);
      });
    }

    for (final platform in ['ios', 'android']) {
      test('acknowledges a legacy token response on $platform', () async {
        setPlatform(platform);
        final remaining = await queueBatch([
          {'event': 'appointment_booked', 'distinct_id': 'id-1'},
        ]);
        listenForRejections();
        network.mockResolvedValueOnce({'success': true, 'visitor_id': 'v1'});

        await newCore().flush(token);

        expect(remaining(), isEmpty);
        expect(rejections, isEmpty);
      });
    }

    test('reports an indexed rejection on web after queue removal', () async {
      setPlatform('web');
      final remaining = await queueBatch([
        {'event': 'appointment_booked', 'distinct_id': 'id-1'},
      ]);
      final remainingAtCallback = <List<QueueItem>>[];
      listenForRejections((_) => remainingAtCallback.add(remaining()));
      network.mockResolvedValueOnce({
        'success': true,
        'visitor_id': 'v1',
        'accepted': 0,
        'rejected': [
          {'index': 0, 'code': 'invalid_session'},
        ],
      });

      await newCore().flush(token);

      expect(remaining(), isEmpty);
      expect(remainingAtCallback, [isEmpty]);
      expect(reported(), [
        {'distinctId': 'id-1', 'code': 'invalid_session'},
      ]);
    });

    test('retains a partial indexed result on web', () async {
      setPlatform('web');
      final remaining = await queueBatch([
        {'event': 'appointment_booked', 'distinct_id': 'id-1'},
      ]);
      listenForRejections();
      network.mockResolvedValueOnce({'success': true, 'accepted': 1});

      await newCore().flush(token);

      expect(remaining(), hasLength(1));
      expect(rejections, isEmpty);
    });

    test('retains a retryable no-index response with success false', () async {
      setPlatform('web');
      final remaining = await queueBatch([data]);
      network.mockResolvedValueOnce({'success': false, 'retryable': true});

      await newCore().flush(token);

      expect(remaining(), [data]);
    });

    for (final platform in ['ios', 'android', 'web']) {
      test('acknowledges an incomplete successful legacy response on $platform',
          () async {
        setPlatform(platform);
        final remaining = await queueBatch([
          {'event': 'appointment_booked', 'distinct_id': 'id-1'},
        ]);
        network.mockResolvedValueOnce({'success': true});

        await newCore().flush(token);

        expect(remaining(), isEmpty);
      });
    }

    for (final visitorId in <Object?>[null, 42]) {
      test('acknowledges a legacy response with optional visitor_id $visitorId',
          () async {
        setPlatform('web');
        final remaining = await queueBatch([data]);
        network.mockResolvedValueOnce({
          'success': true,
          'visitor_id': visitorId,
        });

        await newCore().flush(token);

        expect(remaining(), isEmpty);
      });
    }

    for (final platform in ['ios', 'web']) {
      test('accepts a legacy ACK after indexed mode on $platform', () async {
        setPlatform(platform);
        final remaining = await queueBatch([
          {'event': 'first', 'distinct_id': 'id-1'},
          {'event': 'appointment_booked', 'distinct_id': 'id-2'},
        ]);
        config().setFlushBatchSize(token, 1);
        listenForRejections();
        network
          ..mockResolvedValueOnce({
            'success': true,
            'accepted': 1,
            'rejected': <Object?>[],
          })
          ..mockResolvedValueOnce({'success': true, 'visitor_id': 'v1'});

        await newCore().flush(token);

        expect(remaining(), isEmpty);
        expect(rejections, isEmpty);
        expect(removals(), [
          {
            'ids': ['id-1'],
            'mode': 'indexed'
          },
          {
            'ids': ['id-2'],
            'mode': 'legacy'
          },
        ]);
      });
    }

    test('keeps a mobile batch on transport failure', () async {
      final remaining = await queueBatch([data]);
      network.mockRejectedValueOnce(Exception('offline'));

      await newCore().flush(token);

      expect(remaining(), [data]);
      expect(removals(), isEmpty);
    });

    for (final platform in ['ios', 'web']) {
      test(
          'retains an event after HTTP 429 before source mode is known on '
          '$platform', () async {
        setPlatform(platform);
        final remaining = await queueBatch([
          {'event': 'appointment_booked', 'distinct_id': 'id-1'},
        ]);
        network.mockRejectedValueOnce(_http(429));

        await newCore().flush(token);

        expect(remaining(), hasLength(1));
        expect(removals(), isEmpty);
      });
    }

    for (final platform in ['ios', 'web']) {
      test('retains HTTP 429 on $platform after a legacy response', () async {
        setPlatform(platform);
        final remaining = await queueBatch([
          {'event': 'first', 'distinct_id': 'id-1'},
          {'event': r'$mobile_app_open', 'distinct_id': 'id-2'},
          {'event': 'third', 'distinct_id': 'id-3'},
        ]);
        config().setFlushBatchSize(token, 1);
        network
          ..mockResolvedValueOnce({'success': true, 'visitor_id': 'v1'})
          ..mockRejectedValueOnce(_http(429))
          ..mockResolvedValueOnce({'success': true, 'visitor_id': 'v1'});

        await newCore().flush(token);

        // The real queue normalizes a canonical `$mobile_*` row on load (as
        // RN's real queue does); RN's mocked getQueue returned it verbatim.
        expect(remaining(), [
          normalizeMobilePayload(
            {'event': r'$mobile_app_open', 'distinct_id': 'id-2'},
          ),
          {'event': 'third', 'distinct_id': 'id-3'},
        ]);
        expect(removals(), [
          {
            'ids': ['id-1'],
            'mode': 'legacy'
          },
        ]);
      });
    }

    test('retains HTTP 429 after a web token has produced an indexed result',
        () async {
      setPlatform('web');
      final remaining = await queueBatch([
        {'event': 'first', 'distinct_id': 'id-1'},
        {'event': 'appointment_booked', 'distinct_id': 'id-2'},
      ]);
      config().setFlushBatchSize(token, 1);
      network
        ..mockResolvedValueOnce({
          'success': true,
          'accepted': 1,
          'rejected': <Object?>[],
        })
        ..mockRejectedValueOnce(_http(429));

      await newCore().flush(token);

      expect(remaining(), [
        {'event': 'appointment_booked', 'distinct_id': 'id-2'},
      ]);
      expect(removals(), [
        {
          'ids': ['id-1'],
          'mode': 'indexed'
        },
      ]);
    });

    test(
        'accepts legacy ACKs after indexed responses and retains a later '
        'HTTP 429', () async {
      final remaining = await queueBatch([
        {'event': 'first', 'distinct_id': 'id-1'},
        {'event': 'second', 'distinct_id': 'id-2'},
        {'event': 'third', 'distinct_id': 'id-3'},
        {'event': 'appointment_booked', 'distinct_id': 'id-4'},
      ]);
      config().setFlushBatchSize(token, 1);
      network
        ..mockResolvedValueOnce({'success': true, 'visitor_id': 'v1'})
        ..mockResolvedValueOnce({
          'success': true,
          'accepted': 1,
          'rejected': <Object?>[],
        })
        ..mockResolvedValueOnce({'success': true, 'visitor_id': 'v1'})
        ..mockRejectedValueOnce(_http(429));
      final core = newCore();

      await core.flush(token);
      expect(remaining(), [
        {'event': 'appointment_booked', 'distinct_id': 'id-4'},
      ]);
      network.mockRejectedValueOnce(_http(429));
      await core.flush(token);

      expect(remaining(), [
        {'event': 'appointment_booked', 'distinct_id': 'id-4'},
      ]);
    });

    test(
        'retains HTTP 429 after a partial indexed response follows legacy '
        'mode', () async {
      setPlatform('web');
      final remaining = await queueBatch([
        {'event': 'first', 'distinct_id': 'id-1'},
        {'event': 'appointment_booked', 'distinct_id': 'id-2'},
      ]);
      config().setFlushBatchSize(token, 1);
      network
        ..mockResolvedValueOnce({'success': true, 'visitor_id': 'v1'})
        ..mockResolvedValueOnce({'success': true, 'accepted': 1})
        ..mockRejectedValueOnce(_http(429));
      final core = newCore();

      await core.flush(token);
      expect(remaining(), [
        {'event': 'appointment_booked', 'distinct_id': 'id-2'},
      ]);

      await core.flush(token);
      expect(remaining(), [
        {'event': 'appointment_booked', 'distinct_id': 'id-2'},
      ]);
      expect(removals(), hasLength(1));
    });

    test('keeps a failing token queued after another token succeeds', () async {
      setPlatform('web');
      final legacy = await queueBatch(
        [
          {'event': 'first', 'distinct_id': 'id-1'},
        ],
        queueToken: 'legacy-token',
      );
      final unknown = await queueBatch(
        [
          {'event': 'appointment_booked', 'distinct_id': 'id-2'},
        ],
        queueToken: 'unknown-token',
      );
      network
        ..mockResolvedValueOnce({'success': true, 'visitor_id': 'v1'})
        ..mockRejectedValueOnce(_http(429));
      final core = newCore();

      await core.flush('legacy-token');
      await core.flush('unknown-token');

      expect(legacy(), isEmpty);
      expect(unknown(), [
        {'event': 'appointment_booked', 'distinct_id': 'id-2'},
      ]);
    });

    test('waits for durable removal before reporting a rejection', () async {
      final remaining = await queueBatch([data]);
      listenForRejections();
      network.mockResolvedValue({
        'success': true,
        'accepted': 0,
        'rejected': [
          {'index': 0, 'code': 'invalid_session'},
        ],
      });
      var failedOnce = false;
      storage.setItemOverride = (key, value) {
        if (key == queueKey(token, type) && !failedOnce) {
          failedOnce = true;
          return Future<void>.error(StateError('write failed'));
        }
        return storage.baseSetItem(key, value);
      };

      await newCore().flush(token);
      expect(remaining(), [data]);
      expect(rejections, isEmpty);

      await newCore().flush(token);
      expect(remaining(), isEmpty);
      expect(rejections, hasLength(1));
      expect(reported(), [
        {'distinctId': 'event-1', 'code': 'invalid_session'},
      ]);
    });

    test('continues reporting acknowledged rejections when a callback throws',
        () async {
      final remaining = await queueBatch([
        {'event': 'first', 'distinct_id': 'id-1'},
        {'event': 'second', 'distinct_id': 'id-2'},
      ]);
      var calls = 0;
      listenForRejections((_) {
        calls += 1;
        if (calls == 1) throw StateError('host callback failed');
      });
      network.mockResolvedValueOnce({
        'success': true,
        'accepted': 0,
        'rejected': [
          {'index': 0, 'code': 'invalid_session'},
          {'index': 1, 'code': 'invalid_timestamp'},
        ],
      });

      await newCore().flush(token);
      await newCore().flush(token);

      expect(remaining(), isEmpty);
      expect(reported(), [
        {'distinctId': 'id-1', 'code': 'invalid_session'},
        {'distinctId': 'id-2', 'code': 'invalid_timestamp'},
      ]);
    });
  });
}
