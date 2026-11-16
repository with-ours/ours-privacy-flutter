// Shared helpers for the session, lifecycle-recovery, mobile-contract,
// mobile-property-capacity, session-timing and lifecycle-channel tests.
//
// They stand in for what the React Native tests get from Jest:
// - [SessionFakeTimers]: `jest.useFakeTimers()` + `jest.setSystemTime()` +
//   `jest.advanceTimersByTimeAsync()` (wall clock, monotonic clock and the
//   SDK's checkpoint / flush timers move together).
// - [SessionMapStorage]: the `storage` object the RN MobileSession tests
//   build from a `Map`.
// - [SessionHookStorage]: `storageFor(values)` with patchable
//   `getItem` / `setItem` (RN tests reassign `storage.setItem = ...`).
// - [SessionSdk]: `require('../index')` with a mocked `AppState`
//   ([ManualLifecycleSource]), `Platform.OS` ([StaticDeviceInfo]) and
//   `fetchMock` (a recording [MockClient] behind an [OursPrivacyNetwork]).
// - [matchesObject]: Jest's `toMatchObject`.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ours_privacy/ours_privacy.dart';
import 'package:ours_privacy/src/config.dart';
import 'package:ours_privacy/src/constants.dart';
import 'package:ours_privacy/src/mobile_session.dart';
import 'package:ours_privacy/src/network.dart';
import 'package:ours_privacy/src/testing.dart';

/// `Date.parse('2026-10-05T12:00:00.000Z')`.
const int sessionStart = 1791201600000;

/// `new Date(sessionStart).toISOString()`.
const String sessionIso = '2026-10-05T12:00:00.000Z';

/// Matches a 13-digit epoch-millisecond session ID.
final RegExp sessionIdPattern = RegExp(r'^[1-9]\d{12}$');

/// Lets every pending microtask and zero-delay timer run (the Dart analogue
/// of awaiting `oursprivacyImpl._pendingOperation` when storage is in
/// memory: every serialized SDK operation settles within a few turns).
Future<void> settle([int turns = 20]) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Event names of a list of facts or queued/sent events.
List<String> eventNames(Iterable<Object?> items) => [
      for (final item in items)
        if (item is MobileFact)
          item.event
        else
          (item! as Map<Object?, Object?>)['event']! as String,
    ];

/// `toJson()` of a list of facts, for comparing with RN object literals.
List<Map<String, Object?>> factsJson(Iterable<MobileFact> facts) =>
    [for (final fact in facts) fact.toJson()];

/// Moves every durable pending fact out of the outbox (RN tests'
/// `for (const record of await session.pendingQueueFacts())
/// await session.acknowledgeFact(record.id)`).
Future<void> acknowledgeAll(MobileSession session) async {
  for (final record in await session.pendingQueueFacts()) {
    await session.acknowledgeFact(record.id);
  }
}

// ---------------------------------------------------------------------------
// Fake timers and clocks
// ---------------------------------------------------------------------------

class _SessionFakeTimer implements Timer {
  _SessionFakeTimer(this.dueMs, this.sequence, this.callback);

  final int dueMs;
  final int sequence;
  final void Function() callback;
  bool _active = true;
  int _tick = 0;

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => _tick;

  void fire() {
    if (!_active) return;
    _active = false;
    _tick = 1;
    callback();
  }
}

/// Jest modern fake timers: `Date.now()`, `performance.now()` and every timer
/// the SDK creates through its injected timer factory.
class SessionFakeTimers {
  SessionFakeTimers({int startMs = sessionStart}) : wallMs = startMs;

  int wallMs;
  int monotonicMs = 0;
  final List<_SessionFakeTimer> _timers = [];
  int _sequence = 0;

  int wallNow() => wallMs;
  int monotonicNow() => monotonicMs;

  /// [OursPrivacyTimerFactory] for the SDK's checkpoint and flush timers.
  Timer createTimer(Duration duration, void Function() callback) {
    final delay = duration.inMilliseconds < 0 ? 0 : duration.inMilliseconds;
    final timer = _SessionFakeTimer(monotonicMs + delay, _sequence++, callback);
    _timers.add(timer);
    return timer;
  }

  /// Active timers (for assertions).
  int get activeTimerCount => _timers.where((timer) => timer.isActive).length;

  /// RN `clock.shiftWall(ms)`: moves only the wall clock.
  void shiftWall(int ms) => wallMs += ms;

  /// RN `clock.advance(ms)` without firing timers.
  void tick(int ms) {
    wallMs += ms;
    monotonicMs += ms;
  }

  /// `jest.advanceTimersByTimeAsync(ms)`: fires each due timer at its due
  /// time, letting the SDK's async work settle between timers.
  Future<void> advance(int ms) async {
    final target = monotonicMs + ms;
    await settle();
    while (true) {
      _timers.removeWhere((timer) => !timer.isActive);
      final due = _timers.where((timer) => timer.dueMs <= target).toList()
        ..sort((a, b) => a.dueMs != b.dueMs
            ? a.dueMs.compareTo(b.dueMs)
            : a.sequence.compareTo(b.sequence));
      if (due.isEmpty) break;
      final next = due.first;
      if (next.dueMs > monotonicMs) tick(next.dueMs - monotonicMs);
      next.fire();
      await settle();
    }
    if (target > monotonicMs) tick(target - monotonicMs);
    await settle();
  }
}

// ---------------------------------------------------------------------------
// Storage doubles
// ---------------------------------------------------------------------------

/// The RN MobileSession tests' `storage` built over a `Map`.
class SessionMapStorage implements MobileSessionStorage {
  SessionMapStorage([Map<String, String>? values]) : values = values ?? {};

  final Map<String, String> values;

  /// Replaces `setItem` (RN: `clock.storage.setItem = async (...) => ...`).
  Future<void> Function(String key, String value)? setItemOverride;

  @override
  Future<String?> getItem(String key) async => values[key];

  @override
  Future<void> setItem(String key, String value) {
    final override = setItemOverride;
    if (override != null) return override(key, value);
    return writeThrough(key, value);
  }

  /// The original `setItem`.
  Future<void> writeThrough(String key, String value) async {
    values[key] = value;
  }
}

/// RN `storageFor(values)`: an AsyncStorage-shaped object over a `Map`, whose
/// methods tests can replace.
class SessionHookStorage implements OursPrivacyStorage {
  SessionHookStorage([Map<String, String>? values]) : values = values ?? {};

  final Map<String, String> values;

  /// Replaces `getItem`; call [readThrough] for the original.
  Future<String?> Function(String key)? getItemOverride;

  /// Replaces `setItem`; call [writeThrough] for the original.
  Future<void> Function(String key, String value)? setItemOverride;

  Future<String?> readThrough(String key) async => values[key];

  Future<void> writeThrough(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<String?> getItem(String key) {
    final override = getItemOverride;
    return override != null ? override(key) : readThrough(key);
  }

  @override
  Future<void> setItem(String key, String value) {
    final override = setItemOverride;
    return override != null ? override(key, value) : writeThrough(key, value);
  }

  @override
  Future<void> removeItem(String key) async {
    values.remove(key);
  }
}

// ---------------------------------------------------------------------------
// SDK harness
// ---------------------------------------------------------------------------

/// Maps React Native `AppState` names to [OursAppState].
///
/// RN's `'background'` is a single message; Flutter's equivalent single
/// state is `paused` (the state machine treats the first of
/// `hidden`/`paused`/`detached` as the background edge).
OursAppState rnAppState(String state) {
  switch (state) {
    case 'active':
      return OursAppState.resumed;
    case 'inactive':
      return OursAppState.inactive;
    case 'background':
      return OursAppState.paused;
  }
  throw ArgumentError.value(state, 'state');
}

/// One "process" of the RN SDK under test: fake timers, a mocked `AppState`,
/// a mocked platform and a recording `fetch`.
class SessionSdk {
  SessionSdk({
    this.device = const StaticDeviceInfo.ios(),
    OursAppState? initialState = OursAppState.resumed,
    SessionFakeTimers? timers,
    this.hourFlushIntervalTokens = const [],
  })  : timers = timers ?? SessionFakeTimers(),
        lifecycle = ManualLifecycleSource(initialState) {
    network = OursPrivacyNetwork(
      clientFactory: () => MockClient(_handle),
      timerFactory: this.timers.createTimer,
    );
    _applyFlushIntervals();
  }

  OursPrivacyDeviceInfo device;
  final SessionFakeTimers timers;

  /// The mocked `AppState`; shared by every instance, as RN's is global.
  final ManualLifecycleSource lifecycle;

  /// Tokens whose flush interval is one hour (RN `lifecycle-recovery`
  /// mocks `getFlushInterval` to 3_600_000 for every token).
  final List<String> hourFlushIntervalTokens;

  late final OursPrivacyNetwork network;

  /// Every request sent (RN `fetchMock.mock.calls`).
  final List<http.Request> requests = [];

  /// RN `fetchMock.mockResponse` / `mockImplementation`. Default: an empty
  /// 200 body, like jest-fetch-mock after `resetMocks()`.
  Future<http.Response> Function(http.Request request)? respond;

  final List<OursPrivacy> _instances = [];

  Future<http.Response> _handle(http.Request request) async {
    requests.add(request);
    final respond = this.respond;
    if (respond != null) return respond(request);
    return http.Response('', 200);
  }

  /// `fetchMock.mockResponse(JSON.stringify(body))`.
  void mockResponse(Object? body, [int status = 200]) {
    respond = (_) async => http.Response(jsonEncode(body), status);
  }

  void _applyFlushIntervals() {
    for (final token in hourFlushIntervalTokens) {
      OursPrivacyConfig.instance
          .setFlushInterval(token, const Duration(hours: 1));
    }
  }

  OursPrivacyEnvironment get environment => OursPrivacyEnvironment(
        deviceInfo: device,
        lifecycleSourceFactory: () => lifecycle,
        wallNow: timers.wallNow,
        monotonicNow: timers.monotonicNow,
        timerFactory: timers.createTimer,
        network: network,
      );

  /// `new OursPrivacy()`.
  OursPrivacy create() {
    final op = createOursPrivacyForTesting(environment);
    _instances.add(op);
    return op;
  }

  /// RN `AppState.currentState = state` (no event).
  set currentState(OursAppState? state) => lifecycle.currentState = state;

  /// RN `signal(state)`: delivers the change and waits for the handler.
  Future<void> signal(String state) async {
    lifecycle.emit(rnAppState(state));
    await settle();
  }

  /// RN `queue(token)` / `queued(token)`: the in-memory event queue rows.
  List<Map<String, Object?>> queue(OursPrivacy op, String token) =>
      oursPrivacyImplOf(op)!.core.queueManager.getQueue(token, eventsQueueType);

  /// Decoded request bodies (RN `requests()`).
  List<Map<String, Object?>> get bodies => [
        for (final request in requests)
          jsonDecode(request.body) as Map<String, Object?>,
      ];

  /// Every uploaded event, in order.
  List<Map<String, Object?>> get sentEvents => [
        for (final body in bodies)
          for (final item in body['data']! as List<Object?>)
            item! as Map<String, Object?>,
      ];

  /// Disposes every instance created so far.
  Future<void> disposeAll() async {
    for (final op in _instances) {
      await op.close();
    }
    _instances.clear();
  }

  /// `jest.resetModules()`: a new process. Disposes the live instances and
  /// forgets every process-wide registry; storage contents survive.
  Future<void> restart() async {
    await disposeAll();
    resetOursPrivacyForTesting();
    _applyFlushIntervals();
  }
}

// ---------------------------------------------------------------------------
// toMatchObject
// ---------------------------------------------------------------------------

/// Jest `toMatchObject`: maps match when every expected key is present and
/// matches recursively; lists match element-wise with equal length; a
/// [Matcher] value is applied; anything else uses `==`.
Matcher matchesObject(Object? expected) => _MatchesObject(expected);

class _MatchesObject extends Matcher {
  const _MatchesObject(this.expected);

  final Object? expected;

  static bool _subset(Object? expected, Object? actual) {
    if (expected is Matcher) {
      return expected.matches(actual, <Object?, Object?>{});
    }
    if (expected is Map) {
      if (actual is! Map) return false;
      for (final entry in expected.entries) {
        if (!actual.containsKey(entry.key)) return false;
        if (!_subset(entry.value, actual[entry.key])) return false;
      }
      return true;
    }
    if (expected is List) {
      if (actual is! List || actual.length != expected.length) return false;
      for (var i = 0; i < expected.length; i++) {
        if (!_subset(expected[i], actual[i])) return false;
      }
      return true;
    }
    return expected == actual;
  }

  @override
  bool matches(Object? item, Map<Object?, Object?> matchState) =>
      _subset(expected, item);

  @override
  Description describe(Description description) =>
      description.add('matches object ').addDescriptionOf(expected);
}
