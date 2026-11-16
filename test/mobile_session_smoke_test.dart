// Smoke coverage for lib/src/mobile_session.dart and lib/src/lifecycle.dart,
// ported from the React Native SDK's __tests__/mobile-session.test.js.
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ours_privacy/src/lifecycle.dart';
import 'package:ours_privacy/src/mobile_session.dart';

final int start =
    DateTime.parse('2026-10-05T12:00:00.000Z').millisecondsSinceEpoch;
const String key = 'OURSPRIVACY_token-a_MOBILE_SESSION_V1';

class _MapStorage implements MobileSessionStorage {
  final Map<String, String> values = {};
  Object? failNextWrite;

  @override
  Future<String?> getItem(String key) async => values[key];

  @override
  Future<void> setItem(String key, String value) async {
    final failure = failNextWrite;
    if (failure != null) {
      failNextWrite = null;
      throw failure;
    }
    values[key] = value;
  }
}

class _Clock {
  _Clock([int? startMs]) : wallMs = startMs ?? start;

  final _MapStorage storage = _MapStorage();
  int wallMs;
  int monotonicMs = 0;

  void advance(int ms) {
    wallMs += ms;
    monotonicMs += ms;
  }

  void shiftWall(int ms) => wallMs += ms;

  MobileSession session({
    String token = 'token-a',
    String? appVersion,
    String? appBuild,
  }) =>
      MobileSession(
        token: token,
        storage: storage,
        wallNow: () => wallMs,
        monotonicNow: () => monotonicMs,
        appVersion: appVersion,
        appBuild: appBuild,
      );
}

List<String> events(List<MobileFact> facts) =>
    facts.map((fact) => fact.event).toList();

Future<void> acknowledgeAll(MobileSession session) async {
  for (final record in await session.pendingQueueFacts()) {
    await session.acknowledgeFact(record.id);
  }
}

void main() {
  group('MobileSession', () {
    test('keeps rapid numeric session rotations distinct', () async {
      final clock = _Clock();
      var session = clock.session();
      await session.foreground(automaticEnabled: true);
      await session.rotateSession();
      var startFact = (await session.announceRotatedSession()).single;
      expect(startFact.defaultProperties['sid'], '1791201600001');
      session = clock.session();
      await session.foreground(automaticEnabled: true);
      await session.rotateSession();
      startFact = (await session.announceRotatedSession()).single;
      expect(startFact.defaultProperties['sid'], '1791201600002');
      clock.shiftWall(-60000);
      await session.rotateSession();
      startFact = (await session.announceRotatedSession()).single;
      expect(startFact.defaultProperties['sid'], '1791201600003');
      clock.shiftWall(-300001);
      await session.rotateSession();
      startFact = (await session.announceRotatedSession()).single;
      expect(startFact.defaultProperties['sid'], '1791201239999');
    });

    test('emits one cold-open sequence with shared sid and UTC metadata',
        () async {
      final session = _Clock().session();
      await session.load();
      final facts = await session.foreground(automaticEnabled: true);
      expect(events(facts), [
        r'$mobile_first_open',
        r'$mobile_app_open',
        r'$mobile_session_start',
      ]);
      for (final fact in facts) {
        expect(fact.defaultProperties, {
          'sid': '$start',
          'mobile_occurred_at': '2026-10-05T12:00:00.000Z',
        });
      }
      expect(await session.foreground(automaticEnabled: true), isEmpty);
    });

    test('persists the RN record shape', () async {
      final clock = _Clock(start);
      final session = MobileSession(
        token: 'token-a',
        storage: clock.storage,
        wallNow: () => clock.wallMs,
        monotonicNow: () => clock.monotonicMs,
        appVersion: '1.0',
        getVisitorId: () => 'visitor-1',
        getIsManuallySetId: () => true,
      );
      await session.foreground(automaticEnabled: true);
      final record =
          jsonDecode(clock.storage.values[key]!) as Map<String, Object?>;
      expect(record.keys.toList(), [
        'sid',
        'startedAtMs',
        'lastActiveAtMs',
        'lastSessionEpochMs',
        'lastIssuedSessionMs',
        'firstOpenSent',
        'observedAppVersion',
        'observedAppBuild',
        'sessionStartSent',
        'foregroundDurationMs',
        'pendingEvents',
      ]);
      expect(record['sid'], '$start');
      expect(record['startedAtMs'], start);
      expect(record['observedAppVersion'], '1.0');
      expect(record['observedAppBuild'], isNull);
      final pending =
          (record['pendingEvents'] as List).cast<Map<String, Object?>>();
      expect(pending, hasLength(3));
      expect(pending[0].keys.toList(), [
        'id',
        'queueAccepted',
        'visitorId',
        'isManuallySetId',
        'appVersion',
        'fact',
      ]);
      expect(pending[0]['queueAccepted'], false);
      expect(pending[0]['visitorId'], 'visitor-1');
      expect(pending[0]['isManuallySetId'], true);
      expect(pending[1].containsKey('queueAccepted'), isFalse);
      expect(pending[1]['fact'], {
        'event': r'$mobile_app_open',
        'defaultProperties': {
          'sid': '$start',
          'mobile_occurred_at': '2026-10-05T12:00:00.000Z',
        },
      });
      final id = pending[0]['id'] as String;
      await session.markFactQueued(id);
      final updated =
          jsonDecode(clock.storage.values[key]!) as Map<String, Object?>;
      expect(
          ((updated['pendingEvents'] as List)[0]
              as Map<String, Object?>)['queueAccepted'],
          true);
    });

    test('retains the session before 30 minutes and rotates at equality',
        () async {
      final clock = _Clock();
      final session = clock.session();
      await session.load();
      await session.foreground(automaticEnabled: true);
      await session.background();
      clock.advance(30 * 60 * 1000 - 1);
      final warm = await session.foreground(automaticEnabled: true);
      expect(events(warm), [r'$mobile_app_open']);
      await session.background();
      clock.advance(30 * 60 * 1000);
      final rotated = await session.foreground(automaticEnabled: true);
      expect(events(rotated), [
        r'$mobile_session_end',
        r'$mobile_app_open',
        r'$mobile_session_start',
      ]);
      expect(rotated[0].defaultProperties['sid'], '$start');
      expect(rotated[1].defaultProperties['sid'], '${start + 3599999}');
    });

    test('emits nonoverlapping monotonic engagement', () async {
      final clock = _Clock();
      final session = clock.session();
      await session.load();
      await session.foreground(automaticEnabled: true);
      clock.advance(9999);
      expect(await session.checkpoint(), isEmpty);
      clock.advance(1);
      expect(await session.checkpoint(), [
        MobileFact(
          event: r'$mobile_session_engagement',
          eventProperties: {'engagement_duration_ms': 10000},
          defaultProperties: {
            'sid': '$start',
            'mobile_occurred_at': '2026-10-05T12:00:10.000Z',
          },
        ),
      ]);
      clock.advance(3000);
      final home = await session.screen('Home');
      expect(events(home),
          [r'$mobile_session_engagement', r'$mobile_screen_view']);
      expect(home[0].eventProperties, {'engagement_duration_ms': 3000});
      clock.advance(4000);
      final settings = await session.screen('Settings');
      expect(settings[0].eventProperties,
          {'engagement_duration_ms': 4000, 'screen_name': 'Home'});
      clock.advance(2000);
      final last = await session.background();
      expect(last.single.eventProperties,
          {'engagement_duration_ms': 2000, 'screen_name': 'Settings'});
      expect(await session.background(), isEmpty);
      expect(await session.checkpoint(), isEmpty);
    });

    test('remainingCheckpointMs counts to the next 10 s boundary', () async {
      final clock = _Clock();
      final session = clock.session();
      expect(session.remainingCheckpointMs(), isNull);
      await session.foreground(automaticEnabled: true);
      expect(session.remainingCheckpointMs(), 10000);
      clock.advance(9000);
      await session.screen('Home');
      expect(session.remainingCheckpointMs(), 1000);
      clock.advance(5000);
      expect(session.remainingCheckpointMs(), 1);
    });

    test('hands off a session end observed by a manual snapshot', () async {
      final clock = _Clock();
      final session = clock.session();
      await session.foreground(automaticEnabled: true);
      await session.background();
      clock.advance(30 * 60 * 1000);
      expect(
        await session.snapshot(),
        MobileSnapshot(
          sid: '${start + 1800000}',
          mobileOccurredAt: '2026-10-05T12:30:00.000Z',
        ),
      );
      expect(await session.drainPendingFacts(), [
        MobileFact(event: r'$mobile_session_end', defaultProperties: {
          'sid': '$start',
          'mobile_occurred_at': '2026-10-05T12:00:00.000Z',
        }),
      ]);
      expect(await session.drainPendingFacts(), isEmpty);
    });

    test('leaves first-open eligible after opt-out before emission', () async {
      final clock = _Clock();
      final session = clock.session();
      await session.foreground();
      expect(await session.disableTracking(), isEmpty);
      expect(await session.foreground(automaticEnabled: true), isEmpty);
      expect(await session.screen('Private'), isEmpty);
      expect(await session.snapshot(), isNull);
      final optedIn = clock.session();
      final facts = await optedIn.foreground(automaticEnabled: true);
      expect(events(facts), [
        r'$mobile_first_open',
        r'$mobile_app_open',
        r'$mobile_session_start',
      ]);
      expect(facts[0].defaultProperties['sid'], '1791201600001');
    });

    test('does not emit first-open again after opt-out and opt-in', () async {
      final clock = _Clock();
      final session = clock.session();
      await session.foreground(automaticEnabled: true);
      await acknowledgeAll(session);
      await session.disableTracking();
      final facts = await clock.session().foreground(automaticEnabled: true);
      expect(events(facts), [r'$mobile_app_open', r'$mobile_session_start']);
    });

    test('emits one update when app version or build changes', () async {
      final clock = _Clock();
      await clock
          .session(appVersion: '1.0', appBuild: '10')
          .foreground(automaticEnabled: true);
      final upgraded = clock.session(appVersion: '2.0', appBuild: '11');
      final facts = await upgraded.foreground(automaticEnabled: true);
      expect(events(facts), [r'$mobile_app_open', r'$mobile_app_update']);
      expect(facts[1].eventProperties,
          {'previous_app_version': '1.0', 'previous_app_build': '10'});
    });

    test('serializes concurrent foreground calls', () async {
      final clock = _Clock();
      final session = clock.session();
      final results = await Future.wait([
        session.foreground(automaticEnabled: true),
        session.foreground(automaticEnabled: true),
      ]);
      expect(events(results[0]), hasLength(3));
      expect(results[1], isEmpty);
    });

    test('keeps occurrence times and facts detached across queued calls',
        () async {
      final clock = _Clock();
      final session = clock.session();
      final foreground = session.foreground(automaticEnabled: true);
      clock.advance(1000);
      final snapshot = session.snapshot();
      clock.advance(5000);
      final facts = await foreground;
      expect(facts[0].defaultProperties['mobile_occurred_at'],
          '2026-10-05T12:00:00.000Z');
      expect((await snapshot)!.mobileOccurredAt, '2026-10-05T12:00:01.000Z');
      facts[0].defaultProperties['sid'] = 'tampered';
      expect(facts[1].defaultProperties['sid'], '$start');
      expect((await session.snapshot())!.sid, '$start');
    });

    for (final stored in ['{broken', 'null', '[]', '']) {
      test('recovers from an unusable persisted record ($stored)', () async {
        final clock = _Clock();
        clock.storage.values[key] = stored;
        final facts = await clock.session().foreground(automaticEnabled: true);
        expect(events(facts), hasLength(3));
      });
    }

    test('preserves first-open history while discarding invalid dates',
        () async {
      final clock = _Clock();
      clock.storage.values[key] = jsonEncode({
        'sid': 'stale',
        'startedAtMs': 'invalid',
        'lastActiveAtMs': null,
        'firstOpenSent': true,
        'sessionStartSent': true,
      });
      final facts = await clock.session().foreground(automaticEnabled: true);
      expect(events(facts), [r'$mobile_app_open', r'$mobile_session_start']);
      expect(facts[0].defaultProperties['sid'], '$start');
    });

    test('existing install without a record marks first-open sent', () async {
      final session = _Clock().session(appVersion: '1.0')
        ..existingInstall = true;
      final facts = await session.foreground(automaticEnabled: true);
      expect(events(facts), [r'$mobile_app_open', r'$mobile_session_start']);
    });

    test('does not consume first-open when persistence rejects', () async {
      final clock = _Clock();
      final session = clock.session();
      await session.load();
      clock.storage.failNextWrite = StateError('write failed');
      await expectLater(session.foreground(automaticEnabled: true),
          throwsA(isA<StateError>()));
      expect(session.foregrounded, isFalse);
      expect(events(await session.foreground(automaticEnabled: true)), [
        r'$mobile_first_open',
        r'$mobile_app_open',
        r'$mobile_session_start',
      ]);
    });

    test('rotates a paused session when resume observes a large rollback',
        () async {
      final clock = _Clock();
      final session = clock.session();
      await session.foreground(automaticEnabled: true);
      await session.pause();
      await acknowledgeAll(session);
      clock.shiftWall(-300001);
      expect(await session.resume(), isFalse);
      await session.foreground(automaticEnabled: true);
      final facts = (await session.pendingQueueFacts())
          .map((record) => record.fact)
          .toList();
      expect(events(facts), [
        r'$mobile_session_end',
        r'$mobile_app_open',
        r'$mobile_session_start',
      ]);
    });

    test('pause then resume continues without app-open', () async {
      final clock = _Clock();
      final session = clock.session();
      await session.foreground(automaticEnabled: true);
      clock.advance(2000);
      final paused = await session.pause();
      expect(paused.single.eventProperties, {'engagement_duration_ms': 2000});
      clock.advance(5000);
      expect(await session.resume(), isTrue);
      clock.advance(1000);
      expect((await session.background()).single.eventProperties,
          {'engagement_duration_ms': 1000});
    });

    for (final state in ['foreground', 'background']) {
      test('ends a $state session at its last active instant on rotation',
          () async {
        final clock = _Clock();
        final session = clock.session();
        await session.foreground(automaticEnabled: true);
        if (state == 'background') {
          clock.advance(2000);
          await session.background();
          clock.advance(5000);
        } else {
          clock.advance(5000);
        }
        final facts = await session.rotateSession();
        final end =
            facts.firstWhere((fact) => fact.event == r'$mobile_session_end');
        expect(
            end.defaultProperties['mobile_occurred_at'],
            state == 'foreground'
                ? '2026-10-05T12:00:05.000Z'
                : '2026-10-05T12:00:02.000Z');
      });
    }
  });

  group('LifecycleStateMachine', () {
    List<LifecycleTransition?> run(
            LifecycleStateMachine machine, List<OursAppState> states) =>
        states.map(machine.handle).toList();

    test('normal background and return', () {
      final machine = LifecycleStateMachine()..seed(OursAppState.resumed);
      expect(
        run(machine, [
          OursAppState.inactive,
          OursAppState.hidden,
          OursAppState.paused,
          OursAppState.hidden,
          OursAppState.inactive,
          OursAppState.resumed,
        ]),
        [
          LifecycleTransition.pause,
          LifecycleTransition.background,
          null,
          null,
          null,
          LifecycleTransition.foreground,
        ],
      );
    });

    test('full-screen native UI over the Flutter view is a background', () {
      // Known limitation, kept deliberate: the engine reports the same
      // states for a full-screen native view controller (iOS
      // viewDidDisappear) or another in-app Activity (Android onStop) as
      // for leaving the app, and Dart has no app-level signal to tell them
      // apart. Returning from it is a new `$mobile_app_open`.
      final machine = LifecycleStateMachine()..seed(OursAppState.resumed);
      expect(
        run(machine, [
          OursAppState.inactive, // viewWillDisappear / onPause
          OursAppState.hidden,
          OursAppState.paused, // viewDidDisappear / onStop
          OursAppState.hidden,
          OursAppState.inactive, // viewWillAppear / onStart
          OursAppState.resumed, // viewDidAppear / onResume
        ]),
        [
          LifecycleTransition.pause,
          LifecycleTransition.background,
          null,
          null,
          null,
          LifecycleTransition.foreground,
        ],
      );
    });

    test('dialog or shade resumes', () {
      final machine = LifecycleStateMachine()..seed(OursAppState.resumed);
      expect(run(machine, [OursAppState.inactive, OursAppState.resumed]), [
        LifecycleTransition.pause,
        LifecycleTransition.foregroundFromResume,
      ]);
      expect(machine.foregrounded, isTrue);
    });

    test('unsynthesized jump down emits one background', () {
      final machine = LifecycleStateMachine()..seed(OursAppState.resumed);
      expect(run(machine, [OursAppState.paused, OursAppState.detached]),
          [LifecycleTransition.background, null]);
    });

    test('a direct jump from resumed to detached emits one background', () {
      // Flutter 3.13 delivers `resumed -> detached` unsynthesized (later
      // versions insert inactive, hidden and paused first).
      final machine = LifecycleStateMachine()..seed(OursAppState.resumed);
      expect(run(machine, [OursAppState.detached, OursAppState.paused]),
          [LifecycleTransition.background, null]);
      expect(machine.foregrounded, isFalse);
    });

    test('headless cold start emits nothing until resumed', () {
      final machine = LifecycleStateMachine()..seed(OursAppState.paused);
      expect(
        run(machine, [
          OursAppState.hidden,
          OursAppState.inactive,
          OursAppState.resumed,
        ]),
        [null, null, LifecycleTransition.foreground],
      );
    });

    test('repeated state is ignored', () {
      final machine = LifecycleStateMachine();
      expect(run(machine, [OursAppState.resumed, OursAppState.resumed]),
          [LifecycleTransition.foreground, null]);
    });
  });

  group('FlutterLifecycleSource', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    Future<void> send(String state) async {
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        SystemChannels.lifecycle.name,
        SystemChannels.lifecycle.codec.encodeMessage(state),
        (_) {},
      );
    }

    test('delivers synthesized states from the flutter/lifecycle channel',
        () async {
      final source = FlutterLifecycleSource();
      expect(source.currentState, isNull);
      final received = <OursAppState>[];
      source.start(received.add);
      await send('AppLifecycleState.resumed');
      received.clear();
      await send('AppLifecycleState.paused');
      expect(received, [
        OursAppState.inactive,
        OursAppState.hidden,
        OursAppState.paused,
      ]);
      expect(source.currentState, OursAppState.paused);
      source.dispose();
      await send('AppLifecycleState.resumed');
      expect(received, hasLength(3));
    });
  });
}
