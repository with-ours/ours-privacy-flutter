// Session timing through the public facade, driven by fake_async: the
// 30-minute inactivity boundary, the 10-second engagement checkpoint, the
// 5-minute clock-rollback tolerance and session ID shape.
//
// The wall clock is `sessionStart + elapsed + wallOffset` (so a test can
// move only the wall clock back), the monotonic clock is `elapsed`, and the
// SDK's checkpoint timer is a real `Timer` inside the fake zone. Lifecycle
// changes follow Flutter's synthesized order: going down is
// `inactive -> hidden -> paused`, coming up is `hidden -> inactive ->
// resumed`.
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ours_privacy/ours_privacy.dart';
import 'package:ours_privacy/src/config.dart';
import 'package:ours_privacy/src/constants.dart';
import 'package:ours_privacy/src/network.dart';
import 'package:ours_privacy/src/testing.dart';

import 'helpers/session_harness.dart';

const String _token = 'timing-token';
const int _minute = 60 * 1000;

class _Timing {
  _Timing(this.async) {
    op = createOursPrivacyForTesting(OursPrivacyEnvironment(
      deviceInfo: const StaticDeviceInfo.ios(),
      lifecycleSourceFactory: () => lifecycle,
      wallNow: wallNow,
      monotonicNow: monotonicNow,
      network: OursPrivacyNetwork(
        clientFactory: () => MockClient((_) async => http.Response('', 200)),
      ),
    ));
  }

  final FakeAsync async;
  final ManualLifecycleSource lifecycle =
      ManualLifecycleSource(OursAppState.resumed);
  final InMemoryStorage storage = InMemoryStorage();
  late final OursPrivacy op;
  int wallOffset = 0;

  int wallNow() => sessionStart + async.elapsed.inMilliseconds + wallOffset;
  int monotonicNow() => async.elapsed.inMilliseconds;

  /// Runs [future] to completion inside the fake zone.
  T run<T>(Future<T> future) {
    var done = false;
    Object? error;
    late T value;
    unawaited(future.then<void>((result) {
      value = result;
      done = true;
    }, onError: (Object e) {
      error = e;
      done = true;
    }));
    async.flushMicrotasks();
    if (error != null) throw error!;
    expect(done, isTrue, reason: 'operation did not settle');
    return value;
  }

  void init({bool trackAutomaticEvents = true}) {
    // Keep the periodic upload out of the way: these tests read the queue.
    OursPrivacyConfig.instance
        .setFlushInterval(_token, const Duration(days: 1));
    run(op.init(
      _token,
      storage: storage,
      trackAutomaticEvents: trackAutomaticEvents,
    ));
    op.setFlushOnBackground(false);
  }

  void emit(OursAppState state) {
    lifecycle.emit(state);
    async.flushMicrotasks();
  }

  void goToBackground() {
    emit(OursAppState.inactive);
    emit(OursAppState.hidden);
    emit(OursAppState.paused);
  }

  void returnToForeground() {
    emit(OursAppState.hidden);
    emit(OursAppState.inactive);
    emit(OursAppState.resumed);
  }

  void elapse(int ms) => async.elapse(Duration(milliseconds: ms));

  List<Map<String, Object?>> get queue => oursPrivacyImplOf(op)!
      .core
      .queueManager
      .getQueue(_token, eventsQueueType);

  /// Queue rows added since [from].
  List<Map<String, Object?>> since(int from) => queue.sublist(from);

  void dispose() {
    run(op.close());
  }
}

String _sid(Map<String, Object?> event) =>
    (event['defaultProperties']! as Map)['sid']! as String;

Map<Object?, Object?> _props(Map<String, Object?> event) =>
    event['eventProperties']! as Map;

int _occurredMs(Map<String, Object?> event) =>
    DateTime.parse(_props(event)['mobile_occurred_at']! as String)
        .millisecondsSinceEpoch;

void main() {
  setUp(resetOursPrivacyForTesting);
  tearDown(resetOursPrivacyForTesting);

  test(
      'returning to the foreground at 29m59s continues the session with a new app open',
      () {
    fakeAsync((async) {
      final t = _Timing(async)..init();
      expect(eventNames(t.queue), [
        r'$mobile_first_open',
        r'$mobile_app_open',
        r'$mobile_session_start',
      ]);
      final sid = _sid(t.queue.first);
      expect(sid, '$sessionStart');

      t.elapse(2000);
      t.goToBackground();
      final mark = t.queue.length;
      t.elapse(30 * _minute - 1000);
      t.returnToForeground();

      final added = t.since(mark);
      expect(eventNames(added), [r'$mobile_app_open']);
      expect(_sid(added.single), sid);
      expect(
        t.queue.where((e) => e['event'] == r'$mobile_session_start'),
        hasLength(1),
      );
      expect(
          t.queue.where((e) => e['event'] == r'$mobile_session_end'), isEmpty);
      t.dispose();
    });
  });

  test(
      'returning to the foreground at 30m00s ends the announced session and starts a new one',
      () {
    fakeAsync((async) {
      final t = _Timing(async)..init();
      final oldSid = _sid(t.queue.first);

      t.elapse(2000);
      t.goToBackground();
      final mark = t.queue.length;
      t.elapse(30 * _minute);
      t.returnToForeground();

      final added = t.since(mark);
      expect(eventNames(added), [
        r'$mobile_session_end',
        r'$mobile_app_open',
        r'$mobile_session_start',
      ]);
      // The end is stamped at the old session's last activity (the pause).
      expect(_sid(added[0]), oldSid);
      expect(
          _props(added[0])['mobile_occurred_at'], '2026-10-05T12:00:02.000Z');
      const newSid = '${sessionStart + 2000 + 30 * _minute}';
      expect(_sid(added[1]), newSid);
      expect(_sid(added[2]), newSid);
      t.dispose();
    });
  });

  test(
      'a manual-only session (never announced) rotates at 30m00s without a session end',
      () {
    fakeAsync((async) {
      final t = _Timing(async)..init(trackAutomaticEvents: false);
      t.run(t.op.track('first'));
      final oldSid = _sid(t.queue.single);
      t.goToBackground();
      t.elapse(30 * _minute);
      t.returnToForeground();
      t.run(t.op.track('second'));

      expect(eventNames(t.queue), ['first', 'second']);
      expect(_sid(t.queue[1]), isNot(oldSid));
      expect(_sid(t.queue[1]), '${sessionStart + 30 * _minute}');
      t.dispose();
    });
  });

  test('the engagement checkpoint fires at 10 s of foreground and not before',
      () {
    fakeAsync((async) {
      final t = _Timing(async)..init();
      final mark = t.queue.length;
      expect(oursPrivacyImplOf(t.op)!.hasCheckpointTimer, isTrue);

      t.elapse(9999);
      expect(t.since(mark), isEmpty);

      t.elapse(1);
      final added = t.since(mark);
      expect(eventNames(added), [r'$mobile_session_engagement']);
      expect(_props(added.single)['engagement_duration_ms'], 10000);
      expect(
        _props(added.single)['mobile_occurred_at'],
        '2026-10-05T12:00:10.000Z',
      );

      // And again every further 10 s while foregrounded.
      t.elapse(9999);
      expect(t.since(mark), hasLength(1));
      t.elapse(1);
      expect(
        [for (final e in t.since(mark)) _props(e)['engagement_duration_ms']],
        [10000, 10000],
      );
      t.dispose();
    });
  });

  test('engagement accumulates across foreground spans', () {
    fakeAsync((async) {
      final t = _Timing(async)..init();
      final mark = t.queue.length;

      t.elapse(6000);
      t.goToBackground(); // the pause emits the 6 s span
      t.elapse(20 * 1000); // background time is not engagement
      t.returnToForeground();

      // The next checkpoint lands on the 10 s accumulated boundary: 4 s in.
      t.elapse(3999);
      expect(
        [
          for (final e in t.since(mark))
            if (e['event'] == r'$mobile_session_engagement')
              _props(e)['engagement_duration_ms'],
        ],
        [6000],
      );
      t.elapse(1);
      final engagement = [
        for (final e in t.since(mark))
          if (e['event'] == r'$mobile_session_engagement') e,
      ];
      expect(
        [for (final e in engagement) _props(e)['engagement_duration_ms']],
        [6000, 4000],
      );
      expect(_sid(engagement[0]), _sid(engagement[1]));
      expect(
        t.storage.values['OURSPRIVACY_${_token}_MOBILE_SESSION_V1'],
        contains('"foregroundDurationMs":10000'),
      );
      t.dispose();
    });
  });

  test('a wall clock moved back exactly 5 minutes keeps the session', () {
    fakeAsync((async) {
      final t = _Timing(async)..init();
      final sid = _sid(t.queue.first);
      t.elapse(1000);
      t.wallOffset = -(5 * _minute + 1000); // wall = start - 5 min
      final mark = t.queue.length;
      t.run(t.op.track('after_rollback'));

      final added = t.since(mark);
      expect(eventNames(added), ['after_rollback']);
      expect(_sid(added.single), sid);
      t.dispose();
    });
  });

  test('a wall clock moved back more than 5 minutes starts a new session', () {
    fakeAsync((async) {
      final t = _Timing(async)..init();
      final oldSid = _sid(t.queue.first);
      t.elapse(1000);
      t.wallOffset = -(5 * _minute + 1001); // wall = start - 5 min - 1 ms
      final mark = t.queue.length;
      t.run(t.op.track('after_rollback'));

      final added = t.since(mark);
      expect(eventNames(added), [
        r'$mobile_session_end',
        r'$mobile_session_start',
        'after_rollback',
      ]);
      expect(_sid(added[0]), oldSid);
      const newSid = '${sessionStart - 5 * _minute - 1}';
      expect(_sid(added[1]), newSid);
      expect(_sid(added[2]), newSid);
      expect(newSid, matches(sessionIdPattern));
      t.dispose();
    });
  });

  test('sid is 13 digits and strictly increasing across rapid sessions', () {
    fakeAsync((async) {
      final t = _Timing(async)..init();
      // Three identity resets in the same millisecond each rotate the
      // foreground session.
      for (var i = 0; i < 3; i++) {
        t.run(t.op.reset());
      }
      final starts = [
        for (final e in t.queue)
          if (e['event'] == r'$mobile_session_start') e,
      ];
      final sids = [for (final e in starts) _sid(e)];
      expect(sids, [
        '$sessionStart',
        '${sessionStart + 1}',
        '${sessionStart + 2}',
        '${sessionStart + 3}',
      ]);
      for (var i = 0; i < sids.length; i++) {
        expect(sids[i], matches(sessionIdPattern));
        if (i > 0) {
          expect(int.parse(sids[i]), greaterThan(int.parse(sids[i - 1])));
        }
        // The session ID is never later than the event it is attached to.
        expect(int.parse(sids[i]), lessThanOrEqualTo(_occurredMs(starts[i])));
      }
      // Every event carries a 13-digit sid no later than its occurrence.
      for (final e in t.queue) {
        expect(_sid(e), matches(sessionIdPattern));
        expect(int.parse(_sid(e)), lessThanOrEqualTo(_occurredMs(e)));
      }
      t.dispose();
    });
  });
}
