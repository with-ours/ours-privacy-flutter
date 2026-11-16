// Persistence across a simulated process restart, and opt-out clearing
// unsent events. Not a port of a single React Native suite: it pins down
// the SDK's persistence contract (visitor ID, install marker, tracking
// decision and default, durable queue; link attribution is memory-only).
//
// A "restart" disposes the SDK instance, forgets every process-wide registry
// (`resetOursPrivacyForTesting()`, RN `jest.resetModules()`), and creates a
// new instance over the same storage.
import 'dart:convert';

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:ours_privacy/ours_privacy.dart';
import 'package:ours_privacy/src/constants.dart';
import 'package:ours_privacy/src/storage.dart' show SharedPreferencesStorage;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ours_privacy/src/testing.dart';

import 'helpers/core_harness.dart';

final String _indexedAck = jsonEncode({
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

  Future<void> restart() async {
    for (final client in clients) {
      await client.dispose();
    }
    clients.clear();
    resetOursPrivacyForTesting();
  }

  List<Object?> queuedEvents(CoreStorage storage, String token) =>
      coreQueue(storage, token).map((item) => item['event']).toList();

  setUp(() {
    resetOursPrivacyForTesting();
    fetch = CoreFetch();
    timers = CoreFakeTimers();
    clients.clear();
  });

  tearDown(restart);

  group('identity', () {
    test('visitor ID persists across a simulated restart', () async {
      const token = 'persist-visitor';
      final storage = CoreStorage();
      final first = newClient();
      await first.op.init(token, storage: storage);
      final visitorId = first.op.getVisitorId();
      expect(visitorId, isNotNull);
      expect(storage.values[visitorIdKey(token)], visitorId);

      await restart();
      final second = newClient();
      await second.op.init(token, storage: storage);
      expect(second.op.getVisitorId(), visitorId);

      await restart();
      final elsewhere = newClient();
      await elsewhere.op.init(token, storage: CoreStorage());
      expect(elsewhere.op.getVisitorId(), isNot(visitorId));
    });

    test('a visitor ID set by the host persists across a restart', () async {
      const token = 'persist-manual-visitor';
      final storage = CoreStorage();
      final first = newClient();
      await first.op.init(token, storage: storage);
      await first.op.setVisitorId('web-visitor-1');

      await restart();
      final second = newClient();
      await second.op.init(token, storage: storage);
      expect(second.op.getVisitorId(), 'web-visitor-1');
    });

    test('install marker is fresh for a new install and survives restart',
        () async {
      const token = 'install-fresh';
      final storage = CoreStorage();
      final first = newClient();
      await first.op.init(token, storage: storage, trackAutomaticEvents: true);
      expect(storage.values[mobileInstallKey(token)], 'fresh');
      expect(queuedEvents(storage, token), contains(r'$mobile_first_open'));

      await restart();
      final second = newClient();
      await second.op.init(token, storage: storage, trackAutomaticEvents: true);
      expect(storage.values[mobileInstallKey(token)], 'fresh');
      expect(
        queuedEvents(storage, token).where((e) => e == r'$mobile_first_open'),
        hasLength(1),
      );
    });

    test('install marker is legacy when a visitor ID predates it', () async {
      const token = 'install-legacy';
      final storage = CoreStorage({visitorIdKey(token): 'existing-visitor'});
      final client = newClient();
      await client.op.init(token, storage: storage, trackAutomaticEvents: true);
      expect(storage.values[mobileInstallKey(token)], 'legacy');
      expect(client.op.getVisitorId(), 'existing-visitor');
      expect(
        queuedEvents(storage, token),
        isNot(contains(r'$mobile_first_open')),
      );
      expect(queuedEvents(storage, token), contains(r'$mobile_app_open'));
    });
  });

  group('tracking decision', () {
    test('an opt-out decision persists across a restart', () async {
      const token = 'persist-opt-out';
      final storage = CoreStorage();
      final first = newClient();
      await first.op.init(token, storage: storage);
      await first.op.optOutTracking();
      expect(storage.values[optOutKey(token)], 'true');
      expect(storage.values[optOutDecisionKey(token)], 'true');

      await restart();
      final second = newClient();
      await second.op.init(token, storage: storage);
      expect(second.op.hasOptedOutTracking(), isTrue);
      await second.op.track('after-restart');
      await second.op.flush();
      expect(coreQueue(storage, token), isEmpty);
      expect(fetch.callCount, 0);
    });

    test('optOutTrackingByDefault applies while no choice is saved', () async {
      const token = 'default-only';
      final storage = CoreStorage();
      final first = newClient();
      await first.op.init(
        token,
        storage: storage,
        optOutTrackingByDefault: true,
      );
      expect(first.op.hasOptedOutTracking(), isTrue);
      expect(storage.values[optOutKey(token)], 'true');
      expect(storage.values[optOutDefaultKey(token)], 'true');
      expect(storage.values.containsKey(optOutDecisionKey(token)), isFalse);

      // The app drops the default: the stored default no longer applies.
      await restart();
      final second = newClient();
      await second.op.init(token, storage: storage);
      expect(second.op.hasOptedOutTracking(), isFalse);
      await second.op.track('tracked');
      expect(queuedEvents(storage, token), contains('tracked'));
    });

    test('a saved opt-in outlives optOutTrackingByDefault after restart',
        () async {
      const token = 'saved-opt-in';
      final storage = CoreStorage();
      final first = newClient();
      await first.op.init(
        token,
        storage: storage,
        optOutTrackingByDefault: true,
      );
      await first.op.optInTracking();
      expect(storage.values[optOutDecisionKey(token)], 'false');

      await restart();
      final second = newClient();
      await second.op.init(
        token,
        storage: storage,
        optOutTrackingByDefault: true,
      );
      expect(second.op.hasOptedOutTracking(), isFalse);
    });

    test('a saved opt-out outlives any later default', () async {
      const token = 'saved-opt-out';
      final storage = CoreStorage();
      final first = newClient();
      await first.op.init(token, storage: storage);
      await first.op.optOutTracking();

      await restart();
      final second = newClient();
      await second.op.init(token, storage: storage);
      expect(second.op.hasOptedOutTracking(), isTrue);

      await restart();
      final third = newClient();
      await third.op.init(
        token,
        storage: storage,
        optOutTrackingByDefault: true,
      );
      expect(third.op.hasOptedOutTracking(), isTrue);
      expect(storage.values[optOutDecisionKey(token)], 'true');
    });
  });

  group('event queue', () {
    test('unsent events survive a restart and upload afterwards', () async {
      const token = 'persist-queue';
      final storage = CoreStorage();
      final first = newClient();
      await first.op.init(token, storage: storage);
      await first.op.track('offline-event', {'step': 1});
      final distinctId = coreQueue(storage, token).single['distinct_id'];
      expect(
        storage.savedItems(token).map((row) => (row! as Map)['event']),
        ['offline-event'],
      );

      await restart();
      final second = newClient();
      await second.op.init(token, storage: storage);
      expect(queuedEvents(storage, token), ['offline-event']);
      fetch.mockResponse(_indexedAck);
      await second.op.flush();
      expect(fetch.callCount, 1);
      final sent = fetch.body(0)['data']! as List<Object?>;
      expect((sent.single! as Map)['event'], 'offline-event');
      expect((sent.single! as Map)['distinct_id'], distinctId);
      expect((sent.single! as Map)['eventProperties'], {
        'step': 1,
        'mobile_contract_version': 1,
        'mobile_occurred_at': coreIso(coreStartMs),
      });
      expect(coreQueue(storage, token), isEmpty);
      expect(storage.savedItems(token), isEmpty);
    });

    test('link attribution does not survive a restart', () async {
      const token = 'attribution-memory';
      final storage = CoreStorage();
      final first = newClient();
      await first.op.init(token, storage: storage);
      await first.op.trackDeepLink(
        'myapp://open?utm_source=newsletter&utm_campaign=spring&gclid=click-1',
      );
      await first.op.track('during-link');
      final during = coreQueue(storage, token)
          .singleWhere((item) => item['event'] == 'during-link');
      final duringDefaults = during['defaultProperties']! as Map;
      expect(duringDefaults['utm_source'], 'newsletter');
      expect(duringDefaults['utm_campaign'], 'spring');
      expect(duringDefaults['gclid'], 'click-1');
      // Only the queued events carry it; it is not stored on its own.
      for (final entry in storage.values.entries) {
        if (entry.key == queueKey(token, eventsQueueType)) continue;
        expect(entry.value, isNot(contains('newsletter')), reason: entry.key);
        expect(entry.value, isNot(contains('click-1')), reason: entry.key);
      }

      await restart();
      final second = newClient();
      await second.op.init(token, storage: storage);
      await second.op.track('after-restart');
      final after = coreQueue(storage, token)
          .singleWhere((item) => item['event'] == 'after-restart');
      final afterDefaults = after['defaultProperties']! as Map;
      expect(afterDefaults.containsKey('utm_source'), isFalse);
      expect(afterDefaults.containsKey('utm_campaign'), isFalse);
      expect(afterDefaults.containsKey('gclid'), isFalse);
    });
  });

  group('opt-out clears unsent events', () {
    test('empties the queue in memory and in storage', () async {
      const token = 'opt-out-clear';
      final storage = CoreStorage();
      final client = newClient();
      await client.op.init(token, storage: storage);
      await client.op.track('first');
      await client.op.track('second');
      expect(storage.savedItems(token), hasLength(2));

      await client.op.optOutTracking();

      expect(coreQueue(storage, token), isEmpty);
      expect(storage.savedItems(token), isEmpty);
    });

    test('cancels the in-flight upload and reports nothing', () async {
      const token = 'opt-out-in-flight';
      final storage = CoreStorage();
      final rejected = <OursPrivacyIngestRejection>[];
      final client = newClient();
      await client.op
          .init(token, storage: storage, onIngestRejected: rejected.add);
      await client.op.track('in-flight');
      fetch.mockImplementation(CoreFetch.pendingForever);

      final flushing = client.op.flush();
      await coreTickUntil(() => fetch.callCount == 1);
      final optingOut = client.op.optOutTracking();
      expect(fetch.callClients.single.closed, isTrue);
      await flushing;
      await optingOut;

      expect(coreQueue(storage, token), isEmpty);
      expect(storage.savedItems(token), isEmpty);
      expect(rejected, isEmpty);
      expect(fetch.callCount, 1);
    });

    test('sends nothing after opting out', () async {
      const token = 'opt-out-silent';
      final storage = CoreStorage();
      final client = newClient();
      await client.op.init(token, storage: storage, trackAutomaticEvents: true);
      await client.op.track('before');
      await client.op.optOutTracking();
      fetch.mockResponse(_indexedAck);

      await client.op.track('after');
      await client.op.identify({'externalId': 'user-1'});
      await client.op.trackScreen('Home');
      await client.op.trackDeepLink('myapp://open?utm_source=newsletter');
      client.emitBackground();
      await coreSettle();
      client.emit(const [
        OursAppState.hidden,
        OursAppState.inactive,
        OursAppState.resumed,
      ]);
      await coreSettle();
      await client.op.flush();
      await timers.advance(const Duration(minutes: 2));

      expect(fetch.callCount, 0);
      expect(coreQueue(storage, token), isEmpty);
      expect(storage.savedItems(token), isEmpty);
    });

    test('a restored queue is discarded when the stored decision is opt-out',
        () async {
      const token = 'opt-out-restored';
      final storage = CoreStorage({
        queueKey(token, eventsQueueType): jsonEncode([
          {'event': 'stored', 'distinct_id': 'stored-event'},
        ]),
        optOutKey(token): 'true',
        optOutDecisionKey(token): 'true',
      });
      final client = newClient();
      await client.op.init(token, storage: storage);
      expect(client.op.hasOptedOutTracking(), isTrue);
      expect(coreQueue(storage, token), isEmpty);
      expect(storage.savedItems(token), isEmpty);
      await client.op.flush();
      await timers.advance(const Duration(seconds: 30));
      expect(fetch.callCount, 0);
    });
  });

  group('storage backend', () {
    test('retries shared_preferences after a failed load', () async {
      // React Native sends every AsyncStorage call on its own, so a
      // transient native failure affects only that call. A failed
      // SharedPreferences.getInstance() must not be cached for the process.
      SharedPreferences.setMockInitialValues({'kept': 'value'});
      var loads = 0;
      final storage = SharedPreferencesStorage(() {
        loads++;
        if (loads == 1) {
          return Future<SharedPreferences>.error(
              PlatformException(code: 'channel-error'));
        }
        return SharedPreferences.getInstance();
      });

      await expectLater(
          storage.getItem('kept'), throwsA(isA<PlatformException>()));
      expect(await storage.getItem('kept'), 'value');
      await storage.setItem('added', 'later');
      expect(await storage.getItem('added'), 'later');
      expect(loads, 2);
    });
  });
}
