// Shared harness for the facade-level ports of the React Native SDK tests
// (index, main, screen, attribution, integration, public API, platform).
//
// It replaces what the React Native suites get from Jest:
// - `jest.useFakeTimers()` + `Date.now()` / `performance.now()`: a
//   [FacadeClock] whose wall and monotonic clocks only move when a test calls
//   [FacadeClock.advance] (`jest.advanceTimersByTimeAsync`) or
//   [FacadeClock.setSystemTime] (`jest.setSystemTime`). The SDK's checkpoint,
//   periodic-flush and network-backoff timers are created through
//   [FacadeClock.createTimer], so they fire in due order as the clock moves.
// - `jest-fetch-mock`: a `package:http/testing.dart` MockClient behind an
//   injected [OursPrivacyNetwork]; every request is recorded and answered by
//   [FacadeHarness.respond] (default: an empty 200 body, like fetchMock's
//   default) or by a one-shot responder queued with
//   [FacadeHarness.respondOnce] (`fetchMock.mockResponseOnce`).
// - React Native's global `AppState`: a [FacadeAppState] that every SDK
//   instance's lifecycle source subscribes to (`installAppStateCapture`).
// - `Platform.OS`: the injected [OursPrivacyDeviceInfo] (iOS by default, as
//   in jest_setup.js).
// - `jest.resetModules()` (a process restart): [FacadeHarness.restart], which
//   disposes the live instances and forgets every process-wide registry
//   while the storage the test owns survives.
// - `console.log` / `console.warn`: [FacadeHarness.printed] captures what the
//   logger prints when logging is enabled for a token (`debugPrint`), and
//   [FacadeHarness.logs] captures every log line regardless of that setting.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ours_privacy/ours_privacy.dart';
import 'package:ours_privacy/src/config.dart';
import 'package:ours_privacy/src/constants.dart';
import 'package:ours_privacy/src/network.dart';
import 'package:ours_privacy/src/testing.dart';

/// 2026-10-05T12:00:00.000Z, the fake "now" used by the React Native suites.
const int facadeStartMs = 1791201600000;

/// A v4 UUID, as produced by the SDK for visitor and event IDs.
final RegExp facadeUuidV4 = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

/// Lets every pending microtask and zero-delay timer run (RN
/// `flushAsyncWork`). The SDK's own timers only fire through [FacadeClock].
Future<void> facadeSettle([int turns = 20]) async {
  for (var index = 0; index < turns; index++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// A single JSON object from a decoded payload.
Map<String, Object?> facadeMap(Object? value) =>
    (value! as Map).cast<String, Object?>();

/// `item[key]` as a JSON object (null when absent or null).
Map<String, Object?>? facadeSection(Map<String, Object?> item, String key) {
  final value = item[key];
  return value == null ? null : facadeMap(value);
}

/// `item.eventProperties` (must be present).
Map<String, Object?> eventPropsOf(Map<String, Object?> item) =>
    facadeSection(item, 'eventProperties')!;

/// `item.defaultProperties` (must be present).
Map<String, Object?> defaultPropsOf(Map<String, Object?> item) =>
    facadeSection(item, 'defaultProperties')!;

/// `item.userProperties` (may be null).
Map<String, Object?>? userPropsOf(Map<String, Object?> item) =>
    facadeSection(item, 'userProperties');

/// Event names of [items], in order.
List<String> facadeEventNames(Iterable<Map<String, Object?>> items) => [
      for (final item in items) item['event']! as String,
    ];

/// Rows of a persisted queue value (a bare array, or an `{items}` envelope).
List<Map<String, Object?>> facadePersistedQueueItems(String value) {
  final parsed = jsonDecode(value);
  final rows = parsed is List ? parsed : (parsed as Map)['items'] as List;
  return [for (final row in rows) facadeMap(row)];
}

class _FacadeTimer implements Timer {
  _FacadeTimer(this._clock, this.dueMs, this.sequence, this._callback);

  final FacadeClock _clock;
  final int dueMs;
  final int sequence;
  final void Function() _callback;
  bool _active = true;

  @override
  bool get isActive => _active;

  @override
  int get tick => _active ? 0 : 1;

  @override
  void cancel() {
    _active = false;
    _clock._timers.remove(this);
  }

  void _fire() {
    if (!_active) return;
    cancel();
    _callback();
  }
}

/// Fake wall and monotonic clocks plus the timers created on them.
class FacadeClock {
  FacadeClock([this.wallMs = facadeStartMs]);

  /// Epoch milliseconds (`Date.now()`).
  int wallMs;

  /// Monotonic milliseconds (`performance.now()`).
  int monotonicMs = 0;

  int _sequence = 0;
  final List<_FacadeTimer> _timers = [];

  /// Number of scheduled timers (for diagnostics).
  int get pendingTimers => _timers.length;

  /// An [OursPrivacyTimerFactory] on this clock.
  Timer createTimer(Duration duration, void Function() callback) {
    final timer = _FacadeTimer(
      this,
      monotonicMs + (duration.inMilliseconds < 0 ? 0 : duration.inMilliseconds),
      _sequence++,
      callback,
    );
    _timers.add(timer);
    return timer;
  }

  /// `jest.setSystemTime(Date.now() + deltaMs)`: moves only the wall clock;
  /// no timer fires.
  void shiftWallClock(int deltaMs) => wallMs += deltaMs;

  void _moveTo(int monotonic) {
    wallMs += monotonic - monotonicMs;
    monotonicMs = monotonic;
  }

  /// `jest.advanceTimersByTimeAsync(ms)`: fires every timer that comes due,
  /// in order, letting async work settle after each one.
  Future<void> advance(int ms) async {
    final target = monotonicMs + ms;
    await facadeSettle();
    while (true) {
      _FacadeTimer? next;
      for (final timer in _timers) {
        if (timer.dueMs > target) continue;
        if (next == null ||
            timer.dueMs < next.dueMs ||
            (timer.dueMs == next.dueMs && timer.sequence < next.sequence)) {
          next = timer;
        }
      }
      if (next == null) break;
      _moveTo(next.dueMs);
      next._fire();
      await facadeSettle();
    }
    _moveTo(target);
    await facadeSettle();
  }
}

/// React Native's process-global `AppState`: every SDK instance's lifecycle
/// source listens to it.
class FacadeAppState {
  FacadeAppState([this.currentState = OursAppState.resumed]);

  /// `AppState.currentState` (the state a freshly started source reports).
  OursAppState? currentState;

  final List<_FacadeLifecycleSource> _sources = [];

  /// Number of sources currently started (RN: a captured handler exists).
  int get listenerCount => _sources.where((s) => s._onChange != null).length;

  LifecycleSource createSource() => _FacadeLifecycleSource(this);

  /// Delivers [state] synchronously to every started source, like the
  /// platform callback. Await [facadeSettle] (or the harness) to let the
  /// SDK's serialized handler run.
  void emit(OursAppState state) {
    currentState = state;
    for (final source in List.of(_sources)) {
      source._onChange?.call(state);
    }
  }
}

class _FacadeLifecycleSource implements LifecycleSource {
  _FacadeLifecycleSource(this._appState);

  final FacadeAppState _appState;
  void Function(OursAppState state)? _onChange;

  @override
  OursAppState? get currentState => _appState.currentState;

  @override
  void start(void Function(OursAppState state) onChange) {
    _onChange = onChange;
    if (!_appState._sources.contains(this)) _appState._sources.add(this);
  }

  @override
  void dispose() {
    _onChange = null;
    _appState._sources.remove(this);
  }
}

/// Answers one HTTP request.
typedef FacadeResponder = Future<http.Response> Function(http.Request request);

/// jest-fetch-mock's default response: 200 with an empty body (a legacy
/// acknowledgment).
Future<http.Response> facadeEmptyResponse(http.Request request) async =>
    http.Response('', 200);

/// `mockIndexedMobileSuccess`: every row of the batch accepted.
Future<http.Response> facadeIndexedSuccess(http.Request request) async {
  final body = jsonDecode(request.body) as Map<String, Object?>;
  return http.Response(
    jsonEncode({
      'success': true,
      'accepted': (body['data']! as List<Object?>).length,
      'rejected': <Object?>[],
    }),
    200,
  );
}

/// A responder that always answers [body] with [status].
FacadeResponder facadeJson(Object? body, [int status = 200]) =>
    (request) async => http.Response(jsonEncode(body), status);

/// Storage with hooks, the Dart counterpart of the `{getItem, setItem,
/// removeItem}` objects the React Native tests pass as `storage`.
class FacadeStorage implements OursPrivacyStorage {
  FacadeStorage({this.persistWrites = true});

  /// When false, writes succeed without storing anything (RN storage whose
  /// `setItem` is `async () => {}`).
  final bool persistWrites;

  final Map<String, String> values = {};

  /// Every key read, in order.
  final List<String> reads = [];

  /// Called before every read; throw to fail the read.
  FutureOr<void> Function(String key)? onGet;

  /// Called before every write; throw to fail it, or return a pending future
  /// to hold it.
  FutureOr<void> Function(String key, String value)? onSet;

  @override
  Future<String?> getItem(String key) async {
    reads.add(key);
    await onGet?.call(key);
    return values[key];
  }

  @override
  Future<void> setItem(String key, String value) async {
    await onSet?.call(key, value);
    if (persistWrites) values[key] = value;
  }

  @override
  Future<void> removeItem(String key) async {
    values.remove(key);
  }
}

/// One test's fake platform: clock, app state, network, device and logs.
class FacadeHarness {
  FacadeHarness({
    this.device = const StaticDeviceInfo.ios(),
    OursAppState? appState = OursAppState.resumed,
    int startMs = facadeStartMs,
  })  : clock = FacadeClock(startMs),
        appState = FacadeAppState(appState) {
    resetOursPrivacyForTesting();
    _originalDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) printed.add(message);
    };
    _installLogSink();
  }

  /// Platform the next created instance runs on (`Platform.OS`).
  OursPrivacyDeviceInfo device;
  final FacadeClock clock;
  final FacadeAppState appState;

  /// Every HTTP request the SDK sent, in order.
  final List<http.Request> requests = [];

  /// Default responder (`fetchMock.mockImplementation`).
  FacadeResponder respond = facadeEmptyResponse;

  /// One-shot responders used first, in order (`mockResponseOnce`).
  final List<FacadeResponder> respondOnce = [];

  /// Lines the logger printed (only when logging is enabled for a token).
  final List<String> printed = [];

  /// Every log line, regardless of the logging setting, as `level: message`.
  final List<String> logs = [];

  final List<OursPrivacy> _ops = [];
  final List<OursPrivacyMain> _mains = [];
  late final DebugPrintCallback _originalDebugPrint;

  void _installLogSink() {
    oursPrivacyLogSink =
        (level, message) => logs.add('${level.name}: $message');
  }

  Future<http.Response> _handle(http.Request request) {
    requests.add(request);
    final responder =
        respondOnce.isNotEmpty ? respondOnce.removeAt(0) : respond;
    return responder(request);
  }

  /// A fresh environment ("process"): its own network, on this harness's
  /// clock, app state and device.
  OursPrivacyEnvironment environment() => OursPrivacyEnvironment(
        deviceInfo: device,
        lifecycleSourceFactory: appState.createSource,
        wallNow: () => clock.wallMs,
        monotonicNow: () => clock.monotonicMs,
        timerFactory: clock.createTimer,
        network: OursPrivacyNetwork(
          clientFactory: () => MockClient(_handle),
          timerFactory: clock.createTimer,
        ),
      );

  /// `new OursPrivacy()` in this fake platform.
  OursPrivacy create() {
    final op = createOursPrivacyForTesting(environment());
    _ops.add(op);
    return op;
  }

  /// `new OursPrivacyMain(token, storage)` in this fake platform.
  OursPrivacyMain createMain(String token, {OursPrivacyStorage? storage}) {
    final main = OursPrivacyMain(
      token,
      storage: storage ?? InMemoryStorage(),
      environment: environment(),
    );
    _mains.add(main);
    return main;
  }

  /// `op.oursprivacyImpl`.
  OursPrivacyMain impl(OursPrivacy op) => oursPrivacyImplOf(op)!;

  /// `OursPrivacyQueueManager.getQueue(token, EVENTS)` for [op]'s token.
  List<Map<String, Object?>> queue(OursPrivacy op) => queueOfMain(impl(op));

  List<Map<String, Object?>> queueOfMain(OursPrivacyMain main) =>
      main.core.queueManager.getQueue(main.token, eventsQueueType);

  /// Decoded request bodies.
  List<Map<String, Object?>> get bodies => [
        for (final request in requests)
          jsonDecode(request.body) as Map<String, Object?>,
      ];

  /// Every item sent, across requests.
  List<Map<String, Object?>> get sentEvents => [
        for (final body in bodies)
          for (final item in body['data']! as List<Object?>) facadeMap(item),
      ];

  /// `suspendPeriodicNetworkFlush()`: a one-hour flush interval for [token].
  /// Process-wide config, so apply it again after [restart].
  void suspendPeriodicNetworkFlush(String token) => OursPrivacyConfig.instance
      .setFlushInterval(token, const Duration(hours: 1));

  /// `waitForFetchCalls(count)`.
  Future<void> waitForRequests(int count, {int attempts = 200}) async {
    for (var attempt = 0; attempt < attempts; attempt++) {
      if (requests.length >= count) {
        await facadeSettle();
        return;
      }
      await facadeSettle(1);
    }
    expect(requests.length, greaterThanOrEqualTo(count));
  }

  /// `jest.resetModules()`: the process restarts. Live instances are
  /// disposed (the old process is gone) and every process-wide registry is
  /// forgotten; storage objects owned by the test survive.
  Future<void> restart() async {
    await _disposeInstances();
    resetOursPrivacyForTesting();
    _installLogSink();
  }

  Future<void> _disposeInstances() async {
    final disposals = <Future<void>>[
      for (final op in _ops) op.close(),
      for (final main in _mains) main.dispose(),
    ];
    _ops.clear();
    _mains.clear();
    await Future.wait(disposals).timeout(
      const Duration(seconds: 5),
      onTimeout: () => const [],
    );
  }

  /// Tear down: dispose instances, restore `debugPrint`, reset registries.
  Future<void> dispose() async {
    await _disposeInstances();
    debugPrint = _originalDebugPrint;
    resetOursPrivacyForTesting();
  }
}
