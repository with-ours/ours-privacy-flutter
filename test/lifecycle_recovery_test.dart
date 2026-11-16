// Port of __tests__/lifecycle-recovery.test.js (React Native SDK).
//
// Re-initialization, process restarts and consent changes around the app
// lifecycle, through the public facade.
//
// Mapping of the Jest setup:
// - `jest.useFakeTimers()` + `jest.setSystemTime(2026-10-05T12:00:00Z)` +
//   `jest.advanceTimersByTimeAsync` -> [SessionFakeTimers] (wall and
//   monotonic clocks plus the SDK's checkpoint and flush timers).
// - `getFlushInterval` mocked to one hour -> `setFlushInterval` for each
//   token used ([SessionSdk.hourFlushIntervalTokens]).
// - `appState(initial)` / `signal(state)` -> a shared
//   [ManualLifecycleSource]; RN 'background' is delivered as Flutter
//   `paused` (see [rnAppState]).
// - `jest.resetModules()` -> [SessionSdk.restart] (dispose, then
//   `resetOursPrivacyForTesting()`; storage contents survive).
// - `fetchMock` -> a recording MockClient behind the injected network.
// - `op.oursprivacyImpl.dispose()` -> `op.close()`.
// - The one RN case that inits without a `storage` option uses the default
//   backend (shared_preferences with mock initial values).
// - RN `while (!readStarted) await Promise.resolve()` polls microtasks; the
//   Dart port polls event-loop turns with a bound.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ours_privacy/ours_privacy.dart' show OursPrivacyException;
import 'package:ours_privacy/src/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/session_harness.dart';

const List<String> _tokens = [
  'default-token',
  'legacy-token',
  'failed-explicit-token',
  'partial-token',
  'toggle-token',
  'reopen-token',
  'fresh-token',
  'repeat-token',
  'before-token',
  'after-token',
  'resume-token',
  'queued-background-token',
  'delayed-link-token',
  'screen-token',
];

/// Waits (bounded) until [condition] holds, letting the event loop run.
Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 1000 && !condition(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(condition(), isTrue, reason: 'condition never became true');
}

/// A gate the RN tests build from `new Promise((resolve) => release = resolve)`.
class _Gate {
  final Completer<void> _completer = Completer<void>();
  Future<void> get future => _completer.future;
  void release() => _completer.complete();
}

List<int> _engagementDurations(List<Map<String, Object?>> events) => [
      for (final event in events)
        if (event['event'] == r'$mobile_session_engagement')
          (event['eventProperties']! as Map)['engagement_duration_ms']! as int,
    ];

void main() {
  late SessionSdk sdk;

  setUp(() {
    resetOursPrivacyForTesting();
    sdk = SessionSdk(hourFlushIntervalTokens: _tokens);
  });

  tearDown(() async {
    await sdk.disposeAll();
    resetOursPrivacyForTesting();
  });

  group('lifecycle recovery', () {
    test(
        'follows a changed default after restart without overriding explicit opt-out',
        () async {
      final storage = SessionHookStorage();
      final first = sdk.create();
      await first.init(
        'default-token',
        storage: storage,
        optOutTrackingByDefault: true,
      );
      expect(first.hasOptedOutTracking(), isTrue);
      await first.close();

      await sdk.restart();
      final second = sdk.create();
      await second.init(
        'default-token',
        storage: storage,
        optOutTrackingByDefault: false,
      );
      expect(second.hasOptedOutTracking(), isFalse);
      await second.optOutTracking();
      await second.close();

      await sdk.restart();
      final third = sdk.create();
      await third.init('default-token', storage: storage);
      expect(third.hasOptedOutTracking(), isTrue);
    });

    test(
        'keeps unmarked legacy opt-out closed when the configured default changes',
        () async {
      final storage =
          SessionHookStorage({'OURSPRIVACY_legacy-token_OPT_OUT': 'true'});
      final op = sdk.create();
      await op.init(
        'legacy-token',
        storage: storage,
        optOutTrackingByDefault: true,
      );
      await op.init(
        'legacy-token',
        storage: storage,
        optOutTrackingByDefault: false,
      );
      expect(op.hasOptedOutTracking(), isTrue);
    });

    test(
        'keeps a failed explicit opt-out closed when the same instance re-initializes',
        () async {
      final storage = SessionHookStorage();
      var failDecision = false;
      storage.setItemOverride = (key, value) async {
        if (failDecision && key.endsWith('_OPT_OUT_DECISION_V1')) {
          throw StateError('decision write failed');
        }
        return storage.writeThrough(key, value);
      };
      final op = sdk.create();
      await op.init(
        'failed-explicit-token',
        storage: storage,
        optOutTrackingByDefault: true,
      );
      await op.init('failed-explicit-token', storage: storage);
      expect(op.hasOptedOutTracking(), isFalse);
      failDecision = true;
      await expectLater(
        op.optOutTracking(),
        throwsA(isA<OursPrivacyException>().having(
          (error) => error.cause,
          'cause',
          isA<StateError>().having(
              (error) => error.message, 'message', 'decision write failed'),
        )),
      );
      await op.init('failed-explicit-token', storage: storage);
      expect(op.hasOptedOutTracking(), isTrue);
    });

    test('keeps a partial explicit opt-out closed after a process restart',
        () async {
      final storage = SessionHookStorage();
      final first = sdk.create();
      await first.init('partial-token', storage: storage);
      await first.optInTracking();
      await first.track('before-opt-out');
      storage.setItemOverride = (key, value) async {
        if (key.endsWith('_OPT_OUT_DECISION_V1')) {
          throw StateError('decision write failed');
        }
        return storage.writeThrough(key, value);
      };
      await expectLater(
        first.optOutTracking(),
        throwsA(isA<OursPrivacyException>().having(
          (error) => error.cause,
          'cause',
          isA<StateError>().having(
              (error) => error.message, 'message', 'decision write failed'),
        )),
      );
      expect(storage.values['OURSPRIVACY_partial-token_OPT_OUT'], 'true');
      expect(
        storage.values['OURSPRIVACY_partial-token_OPT_OUT_DECISION_V1'],
        'false',
      );
      await first.close();
      storage.setItemOverride = null;

      await sdk.restart();
      final second = sdk.create();
      await second.init('partial-token', storage: storage);
      await second.flush();
      expect(second.hasOptedOutTracking(), isTrue);
      expect(sdk.requests, isEmpty);
    });

    test(
        'restores mobile tracking when the same instance changes its default to open',
        () async {
      sdk.currentState = rnAppState('active');
      final op = sdk.create();
      final storage = SessionHookStorage();
      await op.init(
        'toggle-token',
        storage: storage,
        trackAutomaticEvents: true,
        optOutTrackingByDefault: true,
      );
      await op.init(
        'toggle-token',
        storage: storage,
        trackAutomaticEvents: true,
        optOutTrackingByDefault: false,
      );
      await op.trackScreen('Home');
      await op.track('manual');
      expect(op.hasOptedOutTracking(), isFalse);
      final queue = sdk.queue(op, 'toggle-token');
      expect(eventNames(queue), [
        r'$mobile_first_open',
        r'$mobile_app_open',
        r'$mobile_session_start',
        r'$mobile_screen_view',
        'manual',
      ]);
      expect(
        queue.last['defaultProperties'],
        matchesObject({'sid': matches(sessionIdPattern)}),
      );
      expect(
        queue.last['eventProperties'],
        matchesObject({'mobile_contract_version': 1}),
      );
    });

    test('does not reuse an earlier foreground timestamp when consent reopens',
        () async {
      sdk.currentState = rnAppState('background');
      final op = sdk.create();
      final storage = SessionHookStorage();
      await op.init(
        'reopen-token',
        storage: storage,
        trackAutomaticEvents: true,
      );
      op.setFlushOnBackground(false);
      await sdk.signal('active');
      await op.init(
        'reopen-token',
        storage: storage,
        trackAutomaticEvents: true,
        optOutTrackingByDefault: true,
      );
      await sdk.timers.advance(5000);
      await op.init(
        'reopen-token',
        storage: storage,
        trackAutomaticEvents: true,
        optOutTrackingByDefault: false,
      );
      op.setFlushOnBackground(false);
      await sdk.timers.advance(1000);
      await sdk.signal('background');
      expect(_engagementDurations(sdk.queue(op, 'reopen-token')), [1000]);
    });

    test(
        'retains first-open eligibility after a fresh background initialization and restart',
        () async {
      final storage = SessionHookStorage();
      sdk.currentState = rnAppState('background');
      final first = sdk.create();
      await first.init(
        'fresh-token',
        storage: storage,
        trackAutomaticEvents: true,
      );
      expect(sdk.queue(first, 'fresh-token'), isEmpty);
      await first.close();

      await sdk.restart();
      sdk.currentState = rnAppState('active');
      final second = sdk.create();
      await second.init(
        'fresh-token',
        storage: storage,
        trackAutomaticEvents: true,
      );
      expect(eventNames(sdk.queue(second, 'fresh-token')), [
        r'$mobile_first_open',
        r'$mobile_app_open',
        r'$mobile_session_start',
      ]);
    });

    test(
        'preserves one foreground open and all screen engagement across re-init',
        () async {
      sdk.currentState = rnAppState('active');
      final storage = SessionHookStorage();
      final op = sdk.create();
      await op.init(
        'repeat-token',
        storage: storage,
        trackAutomaticEvents: true,
      );
      op.setFlushOnBackground(false);
      await op.trackScreen('Schedule');
      await sdk.timers.advance(3000);
      await op.init(
        'repeat-token',
        storage: storage,
        trackAutomaticEvents: true,
      );
      op.setFlushOnBackground(false);
      await op.trackScreen('Schedule');
      await sdk.timers.advance(2000);
      await sdk.signal('background');
      final events = sdk.queue(op, 'repeat-token');
      expect(
        events.where((event) => event['event'] == r'$mobile_app_open'),
        hasLength(1),
      );
      expect(
        events.where((event) => event['event'] == r'$mobile_screen_view'),
        hasLength(1),
      );
      expect(
        [
          for (final event in events)
            if (event['event'] == r'$mobile_session_engagement')
              event['eventProperties'],
        ],
        [
          matchesObject({
            'screen_name': 'Schedule',
            'engagement_duration_ms': 5000,
          }),
        ],
      );
      await sdk.signal('active');
      expect(
        sdk
            .queue(op, 'repeat-token')
            .where((event) => event['event'] == r'$mobile_app_open'),
        hasLength(2),
      );
    });

    test(
        'does not count changing the source token as a physical foreground entry',
        () async {
      sdk.currentState = rnAppState('active');
      final storage = SessionHookStorage();
      final op = sdk.create();
      await op.init(
        'before-token',
        storage: storage,
        trackAutomaticEvents: true,
      );
      await op.init(
        'after-token',
        storage: storage,
        trackAutomaticEvents: true,
      );
      expect(
        sdk
            .queue(op, 'before-token')
            .where((event) => event['event'] == r'$mobile_app_open'),
        hasLength(1),
      );
      expect(eventNames(sdk.queue(op, 'after-token')), [
        r'$mobile_first_open',
        r'$mobile_session_start',
      ]);
    });

    test(
        'counts foreground time from an active callback while re-init is waiting on storage',
        () async {
      sdk.currentState = rnAppState('active');
      final storage = SessionHookStorage();
      final op = sdk.create();
      await op.init(
        'resume-token',
        storage: storage,
        trackAutomaticEvents: true,
      );
      op.setFlushOnBackground(false);
      await op.trackScreen('Home');
      await sdk.timers.advance(1000);
      await sdk.signal('inactive');
      final gate = _Gate();
      var readStarted = false;
      storage.getItemOverride = (key) async {
        if (key.endsWith('_DEVICE_ID')) {
          readStarted = true;
          await gate.future;
        }
        return storage.readThrough(key);
      };
      final initializing = op.init(
        'resume-token',
        storage: storage,
        trackAutomaticEvents: true,
      );
      await _until(() => readStarted);
      await sdk.timers.advance(1000);
      await sdk.signal('active');
      await sdk.timers.advance(5000);
      gate.release();
      await initializing;
      op.setFlushOnBackground(false);
      await sdk.timers.advance(1000);
      await sdk.signal('background');
      expect(
        _engagementDurations(sdk.queue(op, 'resume-token')),
        [1000, 6000],
      );
    });

    test(
        'applies a queued background receipt when re-init disposes its original listener',
        () async {
      sdk.currentState = rnAppState('active');
      final storage = SessionHookStorage();
      final op = sdk.create();
      await op.init(
        'queued-background-token',
        storage: storage,
        trackAutomaticEvents: true,
      );
      op.setFlushOnBackground(false);
      final gate = _Gate();
      var writeStarted = false;
      var hold = true;
      storage.setItemOverride = (key, value) async {
        if (hold && key.endsWith('_MOBILE_SESSION_V1')) {
          hold = false;
          writeStarted = true;
          await gate.future;
        }
        return storage.writeThrough(key, value);
      };
      final tracking = op.track('held');
      await _until(() => writeStarted);
      await sdk.timers.advance(1000);
      final background = sdk.signal('background');
      final initializing = op.init(
        'queued-background-token',
        storage: storage,
        trackAutomaticEvents: true,
      );
      await sdk.timers.advance(5000);
      gate.release();
      await Future.wait([tracking, background, initializing]);
      await settle();
      expect(
        _engagementDurations(sdk.queue(op, 'queued-background-token')),
        [1000],
      );
    });

    test(
        'does not start engagement before a delayed initial-link session exists',
        () async {
      sdk.currentState = rnAppState('background');
      final storage = SessionHookStorage();
      final gate = _Gate();
      var readStarted = false;
      storage.getItemOverride = (key) async {
        if (key.endsWith('_DEVICE_ID')) {
          readStarted = true;
          await gate.future;
        }
        return storage.readThrough(key);
      };
      final op = sdk.create();
      final initializing = op.init(
        'delayed-link-token',
        storage: storage,
        trackAutomaticEvents: true,
        initialURL: 'myapp://open?utm_source=demo',
      );
      await _until(() => readStarted);
      await sdk.timers.advance(1000);
      await sdk.signal('active');
      await sdk.timers.advance(5000);
      gate.release();
      await initializing;
      op.setFlushOnBackground(false);
      await sdk.timers.advance(1000);
      await sdk.signal('background');
      final engagement = sdk.queue(op, 'delayed-link-token').firstWhere(
          (event) => event['event'] == r'$mobile_session_engagement');
      final eventProperties = engagement['eventProperties']! as Map;
      final defaultProperties = engagement['defaultProperties']! as Map;
      expect(eventProperties['engagement_duration_ms'], 1000);
      expect(
        DateTime.parse(eventProperties['mobile_occurred_at']! as String)
                .millisecondsSinceEpoch -
            int.parse(defaultProperties['sid']! as String),
        1000,
      );
    });

    test(
        'clears the foreground screen at background so a manual background view is recorded',
        () async {
      // RN inits without a `storage` option (the default backend).
      SharedPreferences.setMockInitialValues(<String, Object>{});
      sdk.currentState = rnAppState('active');
      final op = sdk.create();
      await op.init('screen-token', trackAutomaticEvents: true);
      op.setFlushOnBackground(false);
      await op.trackScreen('Schedule');
      await sdk.timers.advance(1000);
      await sdk.signal('background');
      await op.trackScreen('Schedule');
      expect(
        sdk
            .queue(op, 'screen-token')
            .where((event) => event['event'] == r'$mobile_screen_view'),
        hasLength(2),
      );
      await sdk.signal('active');
      await op.trackScreen('Schedule');
      expect(
        sdk
            .queue(op, 'screen-token')
            .where((event) => event['event'] == r'$mobile_screen_view'),
        hasLength(3),
      );
    });
  });
}
