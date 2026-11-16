// Shared helpers for the queue, network, core, upload-recovery,
// compatibility and persistence suites. They stand in for what the React
// Native tests get from Jest:
// - [CoreFakeTimers]: `jest.useFakeTimers()` / `advanceTimersByTimeAsync`,
//   injected through the SDK's timer factories (network backoff, core flush
//   timer, engagement checkpoint).
// - [CoreFetch]: `jest-fetch-mock`. Uploads go through SDK-owned clients
//   created by [CoreFetch.network]; closing such a client is the Dart
//   equivalent of aborting the fetch `AbortSignal`.
// - [CoreStorage]: the tests' `memoryStorage()` whose `getItem`/`setItem` can
//   be replaced, like `storage.getItem = jest.fn(...)`.
// - [CoreClient]: an `OursPrivacy` on a forced iOS device with an active
//   (resumed) app state, matching `__tests__/jest_setup.js`.
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:ours_privacy/ours_privacy.dart';
import 'package:ours_privacy/src/constants.dart';
import 'package:ours_privacy/src/network.dart';
import 'package:ours_privacy/src/queue.dart';
import 'package:ours_privacy/src/testing.dart';
import 'package:ours_privacy/src/utils.dart';

/// 2026-10-05T12:00:00.000Z, the timestamp the RN fixtures use.
const int coreStartMs = 1791201600000;

/// Lets pending microtasks and zero-delay timers run (several turns of the
/// event loop), like awaiting a chain of resolved promises in Jest.
Future<void> coreSettle([int turns = 40]) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// RN `tickUntil`: spins the event loop until [predicate] holds.
Future<void> coreTickUntil(bool Function() predicate) async {
  for (var i = 0; i < 1000 && !predicate(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
  if (!predicate()) {
    throw StateError('coreTickUntil: condition never became true');
  }
}

// ---------------------------------------------------------------------------
// Timers

class _CoreFakeTimer implements Timer {
  _CoreFakeTimer(this._owner, this.dueMs, this.sequence, this._callback);

  final CoreFakeTimers _owner;
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
    _owner._timers.remove(this);
  }

  void _fire() {
    if (!_active) return;
    _active = false;
    _owner._timers.remove(this);
    _callback();
  }
}

/// A manual clock for the SDK's injectable timer factories.
class CoreFakeTimers {
  int nowMs = 0;
  int _sequence = 0;
  final List<_CoreFakeTimer> _timers = [];

  /// Use as an `OursPrivacyTimerFactory`.
  Timer create(Duration duration, void Function() callback) {
    final timer = _CoreFakeTimer(
      this,
      nowMs + duration.inMilliseconds,
      _sequence++,
      callback,
    );
    _timers.add(timer);
    return timer;
  }

  /// Number of scheduled, uncancelled timers (`jest.getTimerCount()`).
  int get activeCount => _timers.length;

  /// `jest.advanceTimersByTimeAsync(ms)`: fires every timer due within
  /// [duration] in order, letting async work settle after each one (so a
  /// retry scheduled by a fired timer is also fired if it falls due).
  Future<void> advance(Duration duration) async {
    final target = nowMs + duration.inMilliseconds;
    await coreSettle();
    while (true) {
      final due = _timers.where((timer) => timer.dueMs <= target).toList()
        ..sort((a, b) => a.dueMs != b.dueMs
            ? a.dueMs.compareTo(b.dueMs)
            : a.sequence.compareTo(b.sequence));
      if (due.isEmpty) break;
      final timer = due.first;
      nowMs = timer.dueMs;
      timer._fire();
      await coreSettle();
    }
    nowMs = target;
    await coreSettle();
  }
}

// ---------------------------------------------------------------------------
// Fetch

typedef CoreFetchHandler = Future<http.StreamedResponse> Function(
    http.Request request);

http.StreamedResponse coreStreamed(http.Response response) =>
    http.StreamedResponse(
      Stream<List<int>>.value(response.bodyBytes),
      response.statusCode,
      headers: response.headers,
    );

/// An SDK-owned HTTP client created by [CoreFetch.network]. [closed] after
/// the SDK closes it; closing aborts any request still in flight.
class CoreTrackedClient extends http.BaseClient {
  CoreTrackedClient(this._fetch);

  final CoreFetch _fetch;
  final Completer<void> _abort = Completer<void>();
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final bytes = await request.finalize().toBytes();
    final copy = http.Request(request.method, request.url)
      ..headers.addAll(request.headers)
      ..bodyBytes = bytes;
    if (closed) throw http.ClientException('aborted', request.url);
    final response = _fetch._handle(copy, this);
    return Future.any([
      response,
      _abort.future.then<http.StreamedResponse>(
        (_) => throw http.ClientException('aborted', request.url),
      ),
    ]);
  }

  @override
  void close() {
    closed = true;
    if (!_abort.isCompleted) _abort.complete();
  }
}

/// `jest-fetch-mock`: records every request and answers from one-shot
/// responses first, then the default response (an empty 200 by default).
class CoreFetch {
  final List<http.Request> calls = [];

  /// The SDK-owned client that sent each entry of [calls].
  final List<CoreTrackedClient> callClients = [];
  final List<CoreTrackedClient> clients = [];
  final List<CoreFetchHandler> _once = [];
  CoreFetchHandler? _default;

  int get callCount => calls.length;

  void mockResponseOnce(String body, {int status = 200}) =>
      _once.add((_) async => coreStreamed(http.Response(body, status)));

  void mockResponse(String body, {int status = 200}) =>
      _default = (_) async => coreStreamed(http.Response(body, status));

  void mockRejectOnce(Object error) =>
      _once.add((_) => Future<http.StreamedResponse>.error(error));

  void mockImplementation(CoreFetchHandler handler) => _default = handler;

  void mockImplementationOnce(CoreFetchHandler handler) => _once.add(handler);

  /// A handler that never answers; the request settles only when aborted.
  static Future<http.StreamedResponse> pendingForever(http.Request _) =>
      Completer<http.StreamedResponse>().future;

  Future<http.StreamedResponse> _handle(
    http.Request request,
    CoreTrackedClient client,
  ) {
    calls.add(request);
    callClients.add(client);
    final handler = _once.isNotEmpty ? _once.removeAt(0) : _default;
    if (handler == null) {
      return Future.value(coreStreamed(http.Response('', 200)));
    }
    return handler(request);
  }

  /// The JSON body of request [index].
  Map<String, Object?> body(int index) =>
      jsonDecode(calls[index].body) as Map<String, Object?>;

  /// `distinct_id`s sent by each request, in order.
  List<List<Object?>> get sentDistinctIds => [
        for (var i = 0; i < calls.length; i++)
          [
            for (final item in body(i)['data']! as List<Object?>)
              (item! as Map<String, Object?>)['distinct_id'],
          ],
      ];

  /// A network whose requests use fresh SDK-owned [CoreTrackedClient]s.
  OursPrivacyNetwork network(CoreFakeTimers timers) => OursPrivacyNetwork(
        clientFactory: () {
          final client = CoreTrackedClient(this);
          clients.add(client);
          return client;
        },
        timerFactory: timers.create,
      );
}

/// One recorded `sendRequest` call of [CoreScriptedNetwork].
typedef CoreSentRequest = ({
  String token,
  String endpoint,
  List<Object?> data,
  bool isManuallySetId,
});

/// RN core.test.js's `OursPrivacyNetwork.sendRequest` jest mock: resolves or
/// rejects from scripted one-shot results, then the default (which resolves
/// `null`, like a reset `jest.fn()` resolving `undefined`).
class CoreScriptedNetwork extends OursPrivacyNetwork {
  final List<CoreSentRequest> calls = [];
  final List<Future<Object?> Function()> _once = [];
  Future<Object?> Function()? _default;

  void mockResolvedValueOnce(Object? value) =>
      _once.add(() => Future<Object?>.value(value));

  void mockResolvedValue(Object? value) =>
      _default = () => Future<Object?>.value(value);

  void mockRejectedValueOnce(Object error) =>
      _once.add(() => Future<Object?>.error(error));

  @override
  Future<Object?> sendRequest({
    required String token,
    required String endpoint,
    required List<Object?> data,
    required String serverURL,
    bool isManuallySetId = false,
    int retryCount = 0,
    http.Client? client,
  }) {
    calls.add((
      token: token,
      endpoint: endpoint,
      data: data,
      isManuallySetId: isManuallySetId,
    ));
    final next = _once.isNotEmpty ? _once.removeAt(0) : _default;
    return next == null ? Future<Object?>.value() : next();
  }
}

// ---------------------------------------------------------------------------
// Storage

/// RN `memoryStorage(values)` with replaceable `getItem` / `setItem`.
class CoreStorage implements OursPrivacyStorage {
  CoreStorage([Map<String, String>? values]) : values = values ?? {};

  final Map<String, String> values;
  final List<String> getCalls = [];
  final List<(String, String)> setCalls = [];

  /// Writes that completed: (key, value, value before the write).
  final List<(String, String, String?)> committedWrites = [];

  /// Replaces `getItem` (call [baseGetItem] to fall through).
  Future<String?> Function(String key)? getItemOverride;

  /// Replaces `setItem` (call [baseSetItem] to fall through).
  Future<void> Function(String key, String value)? setItemOverride;

  Future<String?> baseGetItem(String key) async => values[key];

  Future<void> baseSetItem(String key, String value) async =>
      values[key] = value;

  @override
  Future<String?> getItem(String key) {
    getCalls.add(key);
    return (getItemOverride ?? baseGetItem)(key);
  }

  @override
  Future<void> setItem(String key, String value) async {
    setCalls.add((key, value));
    final previous = values[key];
    await (setItemOverride ?? baseSetItem)(key, value);
    committedWrites.add((key, value, previous));
  }

  @override
  Future<void> removeItem(String key) async => values.remove(key);

  /// The stored event rows for [token] (`[]` when none).
  List<Object?> savedItems(String token) =>
      jsonDecode(values[queueKey(token, eventsQueueType)] ?? '[]')
          as List<Object?>;

  /// Durable queue removals for [token] reconstructed from the writes: each
  /// entry is `{ids: removed distinct_ids, mode: response mode saved with
  /// them}` (RN `OursPrivacyQueueManager.removeByIds` calls).
  List<Map<String, Object?>> removals(String token) {
    final rowsKey = queueKey(token, eventsQueueType);
    final metadataKey = queueMetadataKey(token, eventsQueueType);
    final result = <Map<String, Object?>>[];
    List<Object?> ids(String? rows) => [
          for (final item in jsonDecode(rows ?? '[]') as List<Object?>)
            (item! as Map<String, Object?>)['distinct_id'],
        ];
    List<Object?>? pendingRemoved;
    for (final (key, value, previous) in committedWrites) {
      if (key == rowsKey) {
        final now = ids(value);
        final removed = ids(previous).where((id) => !now.contains(id)).toList();
        pendingRemoved = removed.isNotEmpty ? removed : null;
      } else if (key == metadataKey && pendingRemoved != null) {
        final metadata = jsonDecode(value) as Map<String, Object?>;
        result.add({'ids': pendingRemoved, 'mode': metadata['responseMode']});
        pendingRemoved = null;
      }
    }
    return result;
  }
}

// ---------------------------------------------------------------------------
// Facade client

/// An [OursPrivacy] on a forced device with an active app state, injected
/// fake timers, clocks and network (RN `new OursPrivacy()` under
/// `jest_setup.js`).
class CoreClient {
  CoreClient({
    required this.timers,
    required this.fetch,
    OursPrivacyDeviceInfo device = const StaticDeviceInfo.ios(),
    OursAppState? initialState = OursAppState.resumed,
  }) {
    op = createOursPrivacyForTesting(
      OursPrivacyEnvironment(
        deviceInfo: device,
        lifecycleSourceFactory: () {
          final source = ManualLifecycleSource(currentState);
          lifecycleSources.add(source);
          return source;
        },
        wallNow: () => coreStartMs + timers.nowMs + wallOffsetMs,
        monotonicNow: () => timers.nowMs + monotonicOffsetMs,
        timerFactory: timers.create,
        network: fetch.network(timers),
      ),
    );
    currentState = initialState;
  }

  final CoreFakeTimers timers;
  final CoreFetch fetch;
  late final OursPrivacy op;

  /// App state reported by lifecycle sources created from now on.
  OursAppState? currentState;

  /// Every lifecycle source created (one per `init`).
  final List<ManualLifecycleSource> lifecycleSources = [];

  /// `jest.setSystemTime(Date.now() + n)`.
  int wallOffsetMs = 0;
  int monotonicOffsetMs = 0;

  int get wallNow => coreStartMs + timers.nowMs + wallOffsetMs;

  /// The latest lifecycle source (the current instance's AppState listener).
  ManualLifecycleSource get lifecycle => lifecycleSources.last;

  /// Lifecycle sources still subscribed (RN registered AppState handlers).
  int get activeListenerCount =>
      lifecycleSources.where((s) => s.isStarted && !s.disposed).length;

  /// RN `client.oursprivacyImpl`.
  OursPrivacyMain get impl => oursPrivacyImplOf(op)!;

  /// Emits app states as Flutter delivers them (each state in turn).
  void emit(List<OursAppState> states) {
    currentState = states.last;
    for (final state in states) {
      lifecycle.emit(state);
    }
  }

  /// Going to the background in Flutter: inactive, hidden, paused (RN
  /// `onChange('background')`).
  void emitBackground() => emit(const [
        OursAppState.inactive,
        OursAppState.hidden,
        OursAppState.paused,
      ]);

  Future<void> dispose() => op.close();
}

/// The in-memory event queue for [token] on [storage].
List<QueueItem> coreQueue(OursPrivacyStorage storage, String token) =>
    OursPrivacyQueueManager.of(storage).getQueue(token, eventsQueueType);

/// `new Date(ms).toISOString()`.
String coreIso(int ms) => isoFromMilliseconds(ms);

/// A one-shot JSON body string.
String coreJson(Object? value) => jsonEncode(value);
