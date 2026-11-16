// Drives real `AppLifecycleState` messages through the `flutter/lifecycle`
// platform channel into the SDK's default `FlutterLifecycleSource`
// (`AppLifecycleListener`), so the framework synthesizes the intermediate
// states exactly as on a device: going down from `resumed` to `paused` is
// `inactive -> hidden -> paused`; coming back is `hidden -> inactive ->
// resumed`. (`handleAppLifecycleStateChanged` alone would not synthesize
// them.)
//
// Only the lifecycle source is real here; the platform (iOS), clocks,
// timers and network are injected.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding;
import 'package:flutter_test/flutter_test.dart';
import 'package:ours_privacy/ours_privacy.dart';
import 'package:ours_privacy/src/testing.dart';

import 'helpers/session_harness.dart';

const String _token = 'channel-token';

/// Sends `AppLifecycleState.<state>` on the `flutter/lifecycle` channel, as
/// the engine does, and lets the SDK's serialized work settle.
Future<void> _send(String state) async {
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
    'flutter/lifecycle',
    const StringCodec().encodeMessage('AppLifecycleState.$state'),
    (_) {},
  );
  await settle();
}

class _Harness {
  _Harness() {
    sdk = SessionSdk(hourFlushIntervalTokens: const [_token]);
    op = createOursPrivacyForTesting(OursPrivacyEnvironment(
      deviceInfo: const StaticDeviceInfo.ios(),
      // No lifecycleSourceFactory: the real FlutterLifecycleSource.
      wallNow: sdk.timers.wallNow,
      monotonicNow: sdk.timers.monotonicNow,
      timerFactory: sdk.timers.createTimer,
      network: sdk.network,
    ));
  }

  late final SessionSdk sdk;
  late final OursPrivacy op;
  final SessionHookStorage storage = SessionHookStorage();

  Future<void> init() => op.init(
        _token,
        storage: storage,
        trackAutomaticEvents: true,
      );

  /// Uploaded events followed by those still queued.
  List<Map<String, Object?>> get events => [
        ...sdk.sentEvents,
        ...oursPrivacyImplOf(op)!.core.queueManager.getQueue(_token, '/ingest'),
      ];

  Future<void> dispose() => op.close();
}

String _sid(Map<String, Object?> event) =>
    (event['defaultProperties']! as Map)['sid']! as String;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Harness h;

  setUp(() {
    resetOursPrivacyForTesting();
    h = _Harness();
  });

  tearDown(() async {
    await h.dispose();
    // Leave the binding in a known state for the next test. Engines send
    // `paused` before `detached`; Flutter 3.13 (the package floor) asserts on
    // a direct `resumed -> detached` message instead of synthesizing the
    // intermediate states as later versions do.
    await _send('paused');
    await _send('detached');
    resetOursPrivacyForTesting();
  });

  test('cold start: an app already resumed when init runs opens a session',
      () async {
    await _send('resumed');
    expect(WidgetsBinding.instance.lifecycleState, AppLifecycleState.resumed);

    await h.init();

    expect(eventNames(h.events), [
      r'$mobile_first_open',
      r'$mobile_app_open',
      r'$mobile_session_start',
    ]);
    expect(_sid(h.events.first), '$sessionStart');
    expect(oursPrivacyImplOf(h.op)!.appForegrounded, isTrue);
  });

  test('cold start: a resumed message that arrives during init is applied once',
      () async {
    final gate = Completer<void>();
    var readStarted = false;
    h.storage.getItemOverride = (key) async {
      if (key.endsWith('_DEVICE_ID')) {
        readStarted = true;
        await gate.future;
      }
      return h.storage.readThrough(key);
    };
    final initializing = h.init();
    for (var i = 0; i < 100 && !readStarted; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(readStarted, isTrue);
    expect(eventNames(h.events), isEmpty);

    h.sdk.timers.tick(1000);
    await _send('resumed'); // buffered: init has not finished
    h.sdk.timers.tick(4000);
    gate.complete();
    await initializing;
    await settle();

    expect(eventNames(h.events), [
      r'$mobile_first_open',
      r'$mobile_app_open',
      r'$mobile_session_start',
    ]);
    // The session starts at the buffered callback time, not at init's end.
    expect(_sid(h.events.first), '${sessionStart + 1000}');
  });

  test('a headless (backgrounded) cold start emits nothing until resumed',
      () async {
    await _send('resumed');
    await _send('paused'); // binding now paused
    await h.init();
    expect(h.events, isEmpty);

    await _send('resumed'); // hidden -> inactive -> resumed
    expect(eventNames(h.events), [
      r'$mobile_first_open',
      r'$mobile_app_open',
      r'$mobile_session_start',
    ]);
  });

  test('inactive -> resumed pauses and resumes without a new app open',
      () async {
    await _send('resumed');
    await h.init();
    h.op.setFlushOnBackground(false);
    final mark = h.events.length;

    h.sdk.timers.tick(3000);
    await _send('inactive'); // shade, dialog or app switcher
    h.sdk.timers.tick(500);
    await _send('resumed');

    final added = h.events.sublist(mark);
    expect(eventNames(added), [r'$mobile_session_engagement']);
    expect(
      (added.single['eventProperties']! as Map)['engagement_duration_ms'],
      3000,
    );
    expect(
      h.events.where((e) => e['event'] == r'$mobile_app_open'),
      hasLength(1),
    );
    expect(oursPrivacyImplOf(h.op)!.appForegrounded, isTrue);
  });

  test('full background and return continues the session with one app open',
      () async {
    await _send('resumed');
    await h.init();
    h.op.setFlushOnBackground(false);
    final sid = _sid(h.events.first);
    final mark = h.events.length;

    h.sdk.timers.tick(4000);
    await _send('paused'); // inactive -> hidden -> paused
    expect(eventNames(h.events.sublist(mark)), [r'$mobile_session_engagement']);
    expect(oursPrivacyImplOf(h.op)!.appForegrounded, isFalse);

    h.sdk.timers.tick(60 * 1000);
    await _send('resumed'); // hidden -> inactive -> resumed
    final added = h.events.sublist(mark);
    expect(eventNames(added), [
      r'$mobile_session_engagement',
      r'$mobile_app_open',
    ]);
    expect(
      (added[0]['eventProperties']! as Map)['engagement_duration_ms'],
      4000,
    );
    expect(_sid(added[1]), sid);
    expect(oursPrivacyImplOf(h.op)!.appForegrounded, isTrue);
  });

  test('flushes once per trip to the background', () async {
    await _send('resumed');
    await h.init();
    expect(h.sdk.requests, isEmpty);

    await _send('paused'); // inactive, hidden (flush), paused (no flush)
    expect(h.sdk.requests, hasLength(1));
    expect(eventNames(h.sdk.sentEvents), [
      r'$mobile_first_open',
      r'$mobile_app_open',
      r'$mobile_session_start',
    ]);

    await _send('resumed'); // coming up never flushes
    expect(h.sdk.requests, hasLength(1));

    await _send('paused'); // second trip: inactive, hidden (flush), paused
    expect(h.sdk.requests, hasLength(2));
    expect(eventNames(h.sdk.sentEvents).skip(3), [r'$mobile_app_open']);

    // The engine sends `detached` after `paused` (Flutter 3.13 rejects a
    // direct `resumed -> detached` message); already backgrounded, so no
    // extra flush.
    await _send('detached');
    expect(h.sdk.requests, hasLength(2));
  });

  test('setFlushOnBackground(false) suppresses the background flush', () async {
    await _send('resumed');
    await h.init();
    h.op.setFlushOnBackground(false);
    await _send('paused');
    expect(h.sdk.requests, isEmpty);
  });
}
