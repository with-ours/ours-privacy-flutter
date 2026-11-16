// Port of __tests__/mobile-session.test.js (React Native SDK).
//
// Exercises MobileSession directly with a map-backed storage and hand-driven
// wall and monotonic clocks.
//
// Adaptations:
// - RN `session.foreground(true, true, at)` is
//   `foreground(automaticEnabled: true, emitOpenFacts: true, at: ...)`.
// - Facts are [MobileFact] objects; RN object literals are compared with
//   `toJson()`.
// - 'ignores empty screen names without creating a session' cannot pass the
//   number 42: `screen` takes a `String?`, so the type system already
//   rejects it. The other three values (null, '', '   ') are kept.
import 'package:flutter_test/flutter_test.dart';
import 'package:ours_privacy/src/mobile_session.dart';

import 'helpers/session_harness.dart';

const String _sessionKey = 'OURSPRIVACY_token-a_MOBILE_SESSION_V1';

/// RN `setup()`: storage, dependencies and the two clocks.
class _Setup {
  _Setup({int startMs = sessionStart, this.appVersion, this.appBuild})
      : wallMs = startMs;

  final SessionMapStorage storage = SessionMapStorage();
  int wallMs;
  int monotonicMs = 0;
  final String? appVersion;
  final String? appBuild;

  void advance(int ms) {
    wallMs += ms;
    monotonicMs += ms;
  }

  void shiftWall(int ms) => wallMs += ms;

  /// `new MobileSession({...dependencies, ...overrides})`.
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
        appVersion: appVersion ?? this.appVersion,
        appBuild: appBuild ?? this.appBuild,
      );
}

MobileTimePoint _at(int wallMs, int monotonicMs) =>
    MobileTimePoint(wallMs: wallMs, monotonicMs: monotonicMs);

void main() {
  group('MobileSession', () {
    test(
        'keeps rapid numeric session rotations distinct across restart and clock rollback',
        () async {
      final clock = _Setup();
      var session = clock.session();
      await session.foreground(automaticEnabled: true);
      await session.rotateSession();
      var start = (await session.announceRotatedSession()).first;
      expect(start.defaultProperties['sid'], '1791201600001');
      session = clock.session();
      await session.foreground(automaticEnabled: true);
      await session.rotateSession();
      start = (await session.announceRotatedSession()).first;
      expect(start.defaultProperties['sid'], '1791201600002');
      clock.shiftWall(-60000);
      await session.rotateSession();
      start = (await session.announceRotatedSession()).first;
      expect(start.defaultProperties['sid'], '1791201600003');
      clock.shiftWall(-300001);
      await session.rotateSession();
      start = (await session.announceRotatedSession()).first;
      expect(start.defaultProperties['sid'], '1791201239999');
    });

    test(
        'emits one cold-open sequence with a shared session ID and UTC metadata',
        () async {
      final session = _Setup().session();
      await session.load();

      final facts = await session.foreground(automaticEnabled: true);

      expect(eventNames(facts), [
        r'$mobile_first_open',
        r'$mobile_app_open',
        r'$mobile_session_start',
      ]);
      for (final fact in facts) {
        expect(fact.defaultProperties, {
          'sid': '$sessionStart',
          'mobile_occurred_at': '2026-10-05T12:00:00.000Z',
        });
      }
      expect(await session.foreground(automaticEnabled: true), isEmpty);
    });

    test(
        'reuses a persisted session after restart without repeating first-open or session-start',
        () async {
      final clock = _Setup();
      final first = clock.session();
      await first.load();
      await first.foreground(automaticEnabled: true);

      clock.advance(5000);
      final restarted = clock.session();
      await restarted.load();
      final facts = await restarted.foreground(automaticEnabled: true);

      expect(eventNames(facts), [r'$mobile_app_open']);
      expect(facts[0].defaultProperties['sid'], '$sessionStart');
    });

    test(
        'retains the session before 30 minutes of inactivity and rotates at equality',
        () async {
      final clock = _Setup();
      final session = clock.session();
      await session.load();
      await session.foreground(automaticEnabled: true);
      await session.background();

      clock.advance(30 * 60 * 1000 - 1);
      final warmFacts = await session.foreground(automaticEnabled: true);
      expect(eventNames(warmFacts), [r'$mobile_app_open']);
      expect(warmFacts[0].defaultProperties['sid'], '$sessionStart');

      await session.background();
      clock.advance(30 * 60 * 1000);
      final rotatedFacts = await session.foreground(automaticEnabled: true);
      expect(eventNames(rotatedFacts), [
        r'$mobile_session_end',
        r'$mobile_app_open',
        r'$mobile_session_start',
      ]);
      expect(rotatedFacts[0].defaultProperties['sid'], '$sessionStart');
      expect(
        rotatedFacts[1].defaultProperties['sid'],
        '${sessionStart + 3599999}',
      );
      expect(
        rotatedFacts[2].defaultProperties['sid'],
        '${sessionStart + 3599999}',
      );
    });

    test(
        'uses callback times after a processing delay and retains the visible screen on rotation',
        () async {
      final clock = _Setup();
      final session = clock.session();
      await session.load();
      await session.foreground(automaticEnabled: true);
      await session.screen('Schedule');

      clock.advance(5000);
      final backgroundAt = _at(sessionStart + 5000, 5000);
      clock.advance(15000);
      final background = await session.background(at: backgroundAt);
      expect(background[0].eventProperties, {
        'engagement_duration_ms': 5000,
        'screen_name': 'Schedule',
      });
      expect(
        background[0].defaultProperties['mobile_occurred_at'],
        '2026-10-05T12:00:05.000Z',
      );

      final activeAt = _at(
        backgroundAt.wallMs + 30 * 60 * 1000 - 1,
        backgroundAt.monotonicMs + 30 * 60 * 1000 - 1,
      );
      clock.advance(30 * 60 * 1000);
      final warm = await session.foreground(
        automaticEnabled: true,
        emitOpenFacts: true,
        at: activeAt,
      );
      expect(eventNames(warm), [r'$mobile_app_open']);
      expect(warm[0].defaultProperties['sid'], '$sessionStart');

      await session.screen('Schedule');
      await session.rotateSession();
      clock.advance(10000);
      final checkpoint = await session.checkpoint();
      expect(checkpoint[0].eventProperties!['screen_name'], 'Schedule');
    });

    test(
        'emits nonoverlapping monotonic engagement at checkpoint, screen change, and background',
        () async {
      final clock = _Setup();
      final session = clock.session();
      await session.load();
      await session.foreground(automaticEnabled: true);

      clock.advance(9999);
      expect(await session.checkpoint(), isEmpty);
      clock.advance(1);
      final firstDelta = await session.checkpoint();
      expect(factsJson(firstDelta), [
        {
          'event': r'$mobile_session_engagement',
          'eventProperties': {'engagement_duration_ms': 10000},
          'defaultProperties': {
            'sid': '$sessionStart',
            'mobile_occurred_at': '2026-10-05T12:00:10.000Z',
          },
        },
      ]);

      clock.advance(3000);
      final home = await session.screen('Home');
      expect(eventNames(home), [
        r'$mobile_session_engagement',
        r'$mobile_screen_view',
      ]);
      expect(home[0].eventProperties, {'engagement_duration_ms': 3000});
      expect(home[1].eventProperties, {'screen_name': 'Home'});

      clock.advance(4000);
      final settings = await session.screen('Settings');
      expect(settings[0].eventProperties, {
        'engagement_duration_ms': 4000,
        'screen_name': 'Home',
      });

      clock.advance(2000);
      final lastDelta = await session.background();
      expect(lastDelta, hasLength(1));
      expect(lastDelta[0].eventProperties, {
        'engagement_duration_ms': 2000,
        'screen_name': 'Settings',
      });
      expect(await session.background(), isEmpty);
      expect(await session.checkpoint(), isEmpty);
    });

    test(
        'checkpoints at ten accumulated foreground seconds after a screen delta',
        () async {
      final clock = _Setup();
      final session = clock.session();
      await session.load();
      await session.foreground(automaticEnabled: true);

      clock.advance(9000);
      final screenFacts = await session.screen('Home');
      expect(screenFacts[0].eventProperties, {'engagement_duration_ms': 9000});

      clock.advance(1000);
      final checkpointFacts = await session.checkpoint();
      expect(factsJson(checkpointFacts), [
        {
          'event': r'$mobile_session_engagement',
          'eventProperties': {
            'engagement_duration_ms': 1000,
            'screen_name': 'Home',
          },
          'defaultProperties': {
            'sid': '$sessionStart',
            'mobile_occurred_at': '2026-10-05T12:00:10.000Z',
          },
        },
      ]);
      expect(
        (screenFacts[0].eventProperties!['engagement_duration_ms']! as int) +
            (checkpointFacts[0].eventProperties!['engagement_duration_ms']!
                as int),
        10000,
      );
      expect(await session.checkpoint(), isEmpty);
    });

    test('carries emitted foreground duration across a process restart',
        () async {
      final clock = _Setup();
      final first = clock.session();
      await first.load();
      await first.foreground(automaticEnabled: true);
      clock.advance(9000);
      expect((await first.background())[0].eventProperties, {
        'engagement_duration_ms': 9000,
      });

      final restarted = clock.session();
      await restarted.load();
      await restarted.foreground(automaticEnabled: true);
      clock.advance(1000);
      expect((await restarted.checkpoint())[0].eventProperties, {
        'engagement_duration_ms': 1000,
      });
      expect(await restarted.checkpoint(), isEmpty);
    });

    test(
        'uses monotonic time when wall time changes during an active foreground',
        () async {
      final clock = _Setup();
      final session = clock.session();
      await session.load();
      await session.foreground(automaticEnabled: true);

      clock.shiftWall(60 * 60 * 1000);
      clock.advance(10000);

      final facts = await session.checkpoint();
      expect(facts[0].eventProperties!['engagement_duration_ms'], 10000);
    });

    test('supports manual snapshots and screens with automatic tracking off',
        () async {
      final clock = _Setup();
      final session = clock.session();
      await session.load();

      expect(await session.foreground(), isEmpty);
      clock.advance(2000);
      expect((await session.snapshot())!.toJson(), {
        'sid': '$sessionStart',
        'mobile_occurred_at': '2026-10-05T12:00:02.000Z',
      });
      final screenFacts = await session.screen('Appointments');
      expect(factsJson(screenFacts), [
        {
          'event': r'$mobile_screen_view',
          'eventProperties': {'screen_name': 'Appointments'},
          'defaultProperties': {
            'sid': '$sessionStart',
            'mobile_occurred_at': '2026-10-05T12:00:02.000Z',
          },
        },
      ]);
      expect(await session.screen('Appointments'), isEmpty);
      clock.advance(10000);
      expect(await session.background(), isEmpty);
    });

    test('leaves first-open eligible after opt-out before its first emission',
        () async {
      final clock = _Setup();
      final session = clock.session();
      await session.load();
      expect(await session.foreground(), isEmpty);
      expect(await session.disableTracking(), isEmpty);
      expect(await session.foreground(automaticEnabled: true), isEmpty);
      expect(await session.screen('Private'), isEmpty);
      expect(await session.snapshot(), isNull);

      final optedIn = clock.session();
      await optedIn.load();
      final facts = await optedIn.foreground(automaticEnabled: true);
      expect(eventNames(facts), [
        r'$mobile_first_open',
        r'$mobile_app_open',
        r'$mobile_session_start',
      ]);
      expect(facts[0].defaultProperties['sid'], '1791201600001');
    });

    test('rotates on reset without restoring first-open eligibility', () async {
      final clock = _Setup();
      final session = clock.session();
      await session.load();
      await session.foreground(automaticEnabled: true);

      clock.advance(1);
      expect(
          eventNames(await session.resetSession()), [r'$mobile_session_end']);
      final snapshot = await session.snapshot();
      expect(snapshot!.sid, '${sessionStart + 1}');
      final facts = await session.foreground(automaticEnabled: true);
      expect(eventNames(facts), [
        r'$mobile_app_open',
        r'$mobile_session_start',
      ]);
      expect(facts[0].defaultProperties['sid'], '${sessionStart + 1}');
    });

    test(
        'emits one update on a later tracked open when app version or build changes',
        () async {
      final clock = _Setup(appVersion: '1.0', appBuild: '10');
      final first = clock.session();
      await first.load();
      expect(eventNames(await first.foreground(automaticEnabled: true)), [
        r'$mobile_first_open',
        r'$mobile_app_open',
        r'$mobile_session_start',
      ]);

      final unchanged = clock.session();
      await unchanged.load();
      expect(
        eventNames(await unchanged.foreground(automaticEnabled: true)),
        [r'$mobile_app_open'],
      );

      final upgraded = clock.session(appVersion: '2.0', appBuild: '11');
      await upgraded.load();
      final facts = await upgraded.foreground(automaticEnabled: true);
      expect(eventNames(facts), [
        r'$mobile_app_open',
        r'$mobile_app_update',
      ]);
      expect(facts[1].eventProperties, {
        'previous_app_version': '1.0',
        'previous_app_build': '10',
      });
      expect(facts[1].defaultProperties['sid'], '$sessionStart');

      await upgraded.background();
      clock.advance(1000);
      expect(
        eventNames(await upgraded.foreground(automaticEnabled: true)),
        [r'$mobile_app_open'],
      );
    });

    test('keeps the UTC session start date across midnight', () async {
      final clock = _Setup(
        startMs:
            DateTime.parse('2026-10-05T23:59:59.000Z').millisecondsSinceEpoch,
      );
      final session = clock.session();
      await session.load();
      await session.foreground();
      clock.advance(2000);

      expect((await session.snapshot())!.toJson(), {
        'sid': '1791244799000',
        'mobile_occurred_at': '2026-10-06T00:00:01.000Z',
      });
    });

    test(
        'rotates manual snapshots at the inactivity boundary without lifecycle facts',
        () async {
      final clock = _Setup();
      final session = clock.session();
      await session.load();
      await session.foreground();
      await session.background();

      clock.advance(30 * 60 * 1000 - 1);
      expect((await session.snapshot())!.sid, '$sessionStart');
      clock.advance(30 * 60 * 1000);
      expect((await session.snapshot())!.sid, '${sessionStart + 3599999}');
      expect(
        (await session.screen('Appointments'))[0].defaultProperties['sid'],
        '${sessionStart + 3599999}',
      );
    });

    test(
        'hands off an announced session end when a manual snapshot observes timeout',
        () async {
      final clock = _Setup();
      final session = clock.session();
      await session.load();
      await session.foreground(automaticEnabled: true);
      await session.background();
      clock.advance(30 * 60 * 1000);

      final manualTrack = <String, Object?>{
        'event': 'appointment_booked',
        'defaultProperties': (await session.snapshot())!.toJson(),
      };
      expect(manualTrack['defaultProperties'], {
        'sid': '${sessionStart + 1800000}',
        'mobile_occurred_at': '2026-10-05T12:30:00.000Z',
      });
      expect(factsJson(await session.drainPendingFacts()), [
        {
          'event': r'$mobile_session_end',
          'defaultProperties': {
            'sid': '$sessionStart',
            'mobile_occurred_at': '2026-10-05T12:00:00.000Z',
          },
        },
      ]);
      expect(await session.drainPendingFacts(), isEmpty);
      expect((await session.snapshot())!.sid, '${sessionStart + 1800000}');
    });

    test('clears a pending automatic end on full tracking opt-out', () async {
      final clock = _Setup();
      final session = clock.session();
      await session.load();
      await session.foreground(automaticEnabled: true);
      await session.background();
      clock.advance(30 * 60 * 1000);
      await session.snapshot();

      expect(await session.disableTracking(), isEmpty);
      expect(await session.drainPendingFacts(), isEmpty);
      expect(await session.snapshot(), isNull);
    });

    test(
        'does not rotate an active foreground after 30 minutes without a checkpoint',
        () async {
      final clock = _Setup();
      final session = clock.session();
      await session.load();
      await session.foreground(automaticEnabled: true);
      clock.advance(31 * 60 * 1000);

      expect((await session.snapshot())!.sid, '$sessionStart');
      final facts = await session.screen('Appointments');
      expect(
        facts.every((fact) => fact.defaultProperties['sid'] == '$sessionStart'),
        isTrue,
      );
    });

    test(
        'starts a manual screen session before automatic tracking becomes enabled',
        () async {
      final clock = _Setup();
      final session = clock.session();
      await session.load();
      expect(
        (await session.screen('Appointments'))[0].defaultProperties['sid'],
        '$sessionStart',
      );

      final facts = await session.foreground(automaticEnabled: true);
      expect(eventNames(facts), [
        r'$mobile_first_open',
        r'$mobile_app_open',
        r'$mobile_session_start',
      ]);
      expect(facts[2].defaultProperties['sid'], '$sessionStart');
    });

    test(
        'serializes concurrent foreground calls without duplicate lifecycle facts',
        () async {
      final clock = _Setup();
      final session = clock.session();
      final results = await Future.wait([
        session.foreground(automaticEnabled: true),
        session.foreground(automaticEnabled: true),
      ]);
      final first = results[0];
      final duplicate = results[1];

      expect(eventNames(first), [
        r'$mobile_first_open',
        r'$mobile_app_open',
        r'$mobile_session_start',
      ]);
      expect(duplicate, isEmpty);
      final reloaded = clock.session();
      await reloaded.load();
      expect(
        eventNames(await reloaded.foreground(automaticEnabled: true)),
        [r'$mobile_app_open'],
      );
    });

    test('keeps occurrence times and facts detached across queued calls',
        () async {
      final clock = _Setup();
      final session = clock.session();
      final foreground = session.foreground(automaticEnabled: true);
      clock.advance(1000);
      final snapshot = session.snapshot();
      clock.advance(5000);

      final facts = await foreground;
      expect(
        facts[0].defaultProperties['mobile_occurred_at'],
        '2026-10-05T12:00:00.000Z',
      );
      expect(
        (await snapshot)!.mobileOccurredAt,
        '2026-10-05T12:00:01.000Z',
      );
      facts[0].defaultProperties['sid'] = 'tampered';
      expect(facts[1].defaultProperties['sid'], '$sessionStart');
      expect((await session.snapshot())!.sid, '$sessionStart');
    });

    test('keeps sessions and first-open markers scoped to the source token',
        () async {
      final clock = _Setup();
      final a = clock.session();
      final b = clock.session(token: 'token-b');
      await a.load();
      await b.load();

      expect(
        (await a.foreground(automaticEnabled: true))[0]
            .defaultProperties['sid'],
        '$sessionStart',
      );
      expect(
        (await b.foreground(automaticEnabled: true))[0]
            .defaultProperties['sid'],
        '$sessionStart',
      );
      final reloadedA = clock.session();
      await reloadedA.load();
      expect(
        eventNames(await reloadedA.foreground(automaticEnabled: true)),
        [r'$mobile_app_open'],
      );
    });

    test(
        'does not emit a session end for a session never announced by automatic tracking',
        () async {
      final clock = _Setup();
      final session = clock.session();
      await session.load();
      await session.foreground();
      await session.background();
      clock.advance(30 * 60 * 1000);

      expect(eventNames(await session.foreground(automaticEnabled: true)), [
        r'$mobile_first_open',
        r'$mobile_app_open',
        r'$mobile_session_start',
      ]);
    });

    test(
        'does not send an occurrence time before session start if the wall clock moves backward',
        () async {
      final clock = _Setup();
      final session = clock.session();
      await session.load();
      await session.foreground(automaticEnabled: true);
      clock.shiftWall(-1000);

      expect(
        (await session.snapshot())!.mobileOccurredAt,
        '2026-10-05T12:00:00.000Z',
      );
    });

    test('starts a new session for the same screen after inactivity expires',
        () async {
      final clock = _Setup();
      final session = clock.session();
      await session.load();
      await session.foreground(automaticEnabled: true);
      await session.screen('Appointments');
      await session.background();
      clock.advance(30 * 60 * 1000);

      final facts = await session.screen('Appointments');
      expect(eventNames(facts), [
        r'$mobile_session_end',
        r'$mobile_screen_view',
      ]);
      expect(facts[0].defaultProperties['sid'], '$sessionStart');
      expect(facts[1].defaultProperties['sid'], '${sessionStart + 1800000}');
    });

    test('emits an explicit screen view again after a warm foreground entry',
        () async {
      final clock = _Setup();
      final session = clock.session();
      await session.load();
      await session.foreground(automaticEnabled: true);
      expect(
          eventNames(await session.screen('Home')), [r'$mobile_screen_view']);
      expect(await session.screen('Home'), isEmpty);

      await session.background();
      clock.advance(1000);
      await session.foreground(automaticEnabled: true);
      final screenFacts = await session.screen('Home');
      expect(eventNames(screenFacts), [r'$mobile_screen_view']);
      expect(screenFacts[0].defaultProperties['sid'], '$sessionStart');
      expect(await session.screen('Home'), isEmpty);
    });

    test('defaults automatic lifecycle and engagement tracking off', () async {
      final clock = _Setup();
      final session = clock.session();
      await session.load();
      expect(await session.foreground(), isEmpty);
      clock.advance(10000);
      expect(await session.checkpoint(), isEmpty);
      expect(await session.background(), isEmpty);

      final restarted = clock.session();
      await restarted.load();
      expect(eventNames(await restarted.foreground(automaticEnabled: true)), [
        r'$mobile_first_open',
        r'$mobile_app_open',
        r'$mobile_session_start',
      ]);
    });

    test('does not emit first-open again after opt-out and opt-in', () async {
      final clock = _Setup();
      final session = clock.session();
      await session.load();
      await session.foreground(automaticEnabled: true);
      await acknowledgeAll(session);
      expect(await session.disableTracking(), isEmpty);

      final optedIn = clock.session();
      await optedIn.load();
      final facts = await optedIn.foreground(automaticEnabled: true);
      expect(eventNames(facts), [
        r'$mobile_app_open',
        r'$mobile_session_start',
      ]);
      expect(facts[0].defaultProperties['sid'], '1791201600001');
    });

    test(
        'emits an app update for a build-only change with only known prior fields',
        () async {
      final clock = _Setup(appBuild: '10');
      final first = clock.session();
      await first.load();
      await first.foreground(automaticEnabled: true);

      final changed = clock.session(appBuild: '11');
      await changed.load();
      final facts = await changed.foreground(automaticEnabled: true);
      expect(facts[1].toJson(), {
        'event': r'$mobile_app_update',
        'eventProperties': {'previous_app_build': '10'},
        'defaultProperties': {
          'sid': '$sessionStart',
          'mobile_occurred_at': '2026-10-05T12:00:00.000Z',
        },
      });
    });

    test('ignores empty screen names without creating a session', () async {
      final clock = _Setup();
      final session = clock.session();
      await session.load();
      // RN also passes the number 42; `screen` takes a String? in Dart.
      for (final name in <String?>[null, '', '   ']) {
        expect(await session.screen(name), isEmpty);
      }
      expect(
        (await session.screen('Home'))[0].defaultProperties['sid'],
        '$sessionStart',
      );
    });

    for (final stored in ['{broken', 'null']) {
      test('recovers from an unusable persisted session record ($stored)',
          () async {
        final clock = _Setup();
        await clock.storage.setItem(_sessionKey, stored);
        final session = clock.session();
        await session.load();

        expect(eventNames(await session.foreground(automaticEnabled: true)), [
          r'$mobile_first_open',
          r'$mobile_app_open',
          r'$mobile_session_start',
        ]);
      });
    }

    test(
        'preserves first-open history while discarding invalid stored session dates',
        () async {
      final clock = _Setup();
      await clock.storage.setItem(
        _sessionKey,
        '{"sid":"stale","startedAtMs":"invalid","lastActiveAtMs":null,'
        '"firstOpenSent":true,"sessionStartSent":true}',
      );
      final session = clock.session();
      await session.load();

      final facts = await session.foreground(automaticEnabled: true);
      expect(eventNames(facts), [
        r'$mobile_app_open',
        r'$mobile_session_start',
      ]);
      expect(facts[0].defaultProperties['sid'], '$sessionStart');
    });

    test('does not expire early after a backward wall-clock correction',
        () async {
      final clock = _Setup();
      final session = clock.session();
      await session.load();
      await session.foreground(automaticEnabled: true);
      clock.shiftWall(-1000);
      await session.snapshot();
      clock.shiftWall(30 * 60 * 1000);

      final restarted = clock.session();
      await restarted.load();
      final facts = await restarted.foreground(automaticEnabled: true);
      expect(eventNames(facts), [r'$mobile_app_open']);
      expect(facts[0].defaultProperties['sid'], '$sessionStart');
    });

    test(
        'does not consume first-open when persistence rejects before facts are returned',
        () async {
      final clock = _Setup();
      var rejectNextWrite = true;
      clock.storage.setItemOverride = (key, value) async {
        if (rejectNextWrite) {
          rejectNextWrite = false;
          throw StateError('write failed');
        }
        await clock.storage.writeThrough(key, value);
      };
      final session = clock.session();
      await session.load();

      await expectLater(
        session.foreground(automaticEnabled: true),
        throwsA(isA<StateError>()
            .having((error) => error.message, 'message', 'write failed')),
      );
      expect(eventNames(await session.foreground(automaticEnabled: true)), [
        r'$mobile_first_open',
        r'$mobile_app_open',
        r'$mobile_session_start',
      ]);
    });
  });

  Future<void> invoke(MobileSession session, String method) async {
    switch (method) {
      case 'snapshot':
        await session.snapshot();
      case 'screen':
        await session.screen('Home');
      case 'foreground':
        await session.foreground(automaticEnabled: true);
      case 'rotateSession':
        await session.rotateSession();
      case 'resetSession':
        await session.resetSession();
      case 'checkpoint':
        await session.checkpoint();
      default:
        throw ArgumentError.value(method, 'method');
    }
  }

  for (final method in [
    'snapshot',
    'screen',
    'foreground',
    'rotateSession',
    'resetSession',
  ]) {
    test(
        'ends an announced session at its last activity when a cold $method replaces it',
        () async {
      final clock = _Setup();
      final original = clock.session();
      await original.foreground(automaticEnabled: true);
      clock.advance(2000);
      await original.background();
      await acknowledgeAll(original);
      clock.advance(31 * 60 * 1000);
      final cold = clock.session();
      await cold.load();
      await invoke(cold, method);
      final ends = (await cold.pendingQueueFacts())
          .where((record) => record.fact.event == r'$mobile_session_end')
          .toList();
      expect(ends, hasLength(1));
      expect(ends[0].fact.defaultProperties, {
        'sid': '$sessionStart',
        'mobile_occurred_at': '2026-10-05T12:00:02.000Z',
      });
    });
  }

  for (final method in [
    'snapshot',
    'screen',
    'foreground',
    'rotateSession',
    'resetSession',
  ]) {
    test(
        'does not end an unannounced headless session during $method replacement',
        () async {
      final clock = _Setup();
      final original = clock.session();
      await original.snapshot();
      clock.advance(31 * 60 * 1000);
      final cold = clock.session();
      await invoke(cold, method);
      expect(
        (await cold.pendingQueueFacts())
            .where((record) => record.fact.event == r'$mobile_session_end')
            .toList(),
        isEmpty,
      );
    });
  }

  for (final method in ['snapshot', 'screen', 'checkpoint']) {
    test(
        'rotates a foreground session after a large clock rollback observed by $method',
        () async {
      final clock = _Setup();
      final session = clock.session();
      await session.foreground(automaticEnabled: true);
      await acknowledgeAll(session);
      clock.shiftWall(-5 * 60 * 1000 - 1);
      await invoke(session, method);
      final facts = [
        for (final record in await session.pendingQueueFacts()) record.fact,
      ];
      expect(
        factsJson(facts.where((fact) => fact.event == r'$mobile_session_end')),
        [
          {
            'event': r'$mobile_session_end',
            'defaultProperties': {
              'sid': '$sessionStart',
              'mobile_occurred_at': '2026-10-05T12:00:00.000Z',
            },
          },
        ],
      );
      expect((await session.snapshot())!.sid, '${sessionStart - 300001}');
    });
  }

  test('rotates a paused session when resume observes a large clock rollback',
      () async {
    final clock = _Setup();
    final session = clock.session();
    await session.foreground(automaticEnabled: true);
    await session.pause();
    await acknowledgeAll(session);
    clock.shiftWall(-300001);
    expect(await session.resume(), isFalse);
    await session.foreground(automaticEnabled: true);
    final facts = [
      for (final record in await session.pendingQueueFacts()) record.fact,
    ];
    expect(eventNames(facts), [
      r'$mobile_session_end',
      r'$mobile_app_open',
      r'$mobile_session_start',
    ]);
    expect(facts[0].defaultProperties, {
      'sid': '$sessionStart',
      'mobile_occurred_at': '2026-10-05T12:00:00.000Z',
    });
  });

  for (final (state, elapsed, expectedEnd) in [
    ('foreground', 5000, '2026-10-05T12:00:05.000Z'),
    ('background', 7000, '2026-10-05T12:00:02.000Z'),
  ]) {
    test(
        'ends a $state session at its last active instant during identity rotation',
        () async {
      final clock = _Setup();
      final session = clock.session();
      await session.foreground(automaticEnabled: true);
      if (state == 'background') {
        clock.advance(2000);
        await session.background();
        clock.advance(elapsed - 2000);
      } else {
        clock.advance(elapsed);
      }
      final facts = await session.rotateSession();
      expect(
        facts
            .firstWhere((fact) => fact.event == r'$mobile_session_end')
            .defaultProperties,
        {'sid': '$sessionStart', 'mobile_occurred_at': expectedEnd},
      );
      if (state == 'foreground') {
        expect(
          facts
              .firstWhere((fact) => fact.event == r'$mobile_session_engagement')
              .toJson(),
          matchesObject({
            'eventProperties': {'engagement_duration_ms': 5000},
            'defaultProperties': {'mobile_occurred_at': expectedEnd},
          }),
        );
      } else {
        expect(eventNames(facts), [r'$mobile_session_end']);
      }
    });
  }
}
