// Port of javascript/oursprivacy-mobile-session.js (React Native SDK).
//
// The mobile session state machine: session IDs, first-open / app-open /
// session-start / session-end / engagement / screen-view facts, and the
// durable "pending facts" outbox that survives a crash between recording a
// fact and handing it to the event queue.
//
// Every public operation is serialized. A failed operation (for example a
// storage write that throws) restores the in-memory state captured before it
// ran, so a rejected write never consumes first-open or a session start.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show mapEquals;

import 'constants.dart';
import 'storage.dart';
import 'utils.dart';

const String _firstOpenEvent = r'$mobile_first_open';
const String _appOpenEvent = r'$mobile_app_open';
const String _appUpdateEvent = r'$mobile_app_update';
const String _sessionStartEvent = r'$mobile_session_start';
const String _sessionEndEvent = r'$mobile_session_end';
const String _sessionEngagementEvent = r'$mobile_session_engagement';
const String _screenViewEvent = r'$mobile_screen_view';

/// JavaScript `Number.MAX_SAFE_INTEGER` (2^53 - 1).
const int _maxSafeInteger = 9007199254740991;

final RegExp _sessionIdPattern = RegExp(r'^[1-9]\d{12}$');

/// Private copy of `isSessionId` from oursprivacy-mobile-payload.js: a
/// 13-digit epoch-millisecond string without a leading zero.
bool _isSessionId(Object? value) =>
    value is String && _sessionIdPattern.hasMatch(value);

/// JavaScript `Number.isSafeInteger(value) ? value : null`. JSON numbers
/// written as `1.0` decode to a Dart double but are safe integers in JS.
int? _safeInteger(Object? value) {
  if (value is int) {
    return value.abs() <= _maxSafeInteger ? value : null;
  }
  if (value is double &&
      value.isFinite &&
      value == value.truncateToDouble() &&
      value.abs() <= _maxSafeInteger) {
    return value.toInt();
  }
  return null;
}

Map<String, Object?>? _jsonMap(Object? value) =>
    value is Map ? Map<String, Object?>.from(value) : null;

final Stopwatch _monotonicClock = Stopwatch()..start();

/// Default monotonic clock: milliseconds since the first read in this
/// process (the Dart analogue of `performance.now()`). Shared by every
/// session so callback timestamps stay comparable across re-initialization.
int defaultMonotonicNow() => _monotonicClock.elapsedMilliseconds;

/// Default wall clock: epoch milliseconds (`Date.now()`).
int defaultWallNow() => DateTime.now().millisecondsSinceEpoch;

/// Storage used by [MobileSession]. Both methods must throw on failure
/// (strict), so a failed write rolls the operation back.
abstract class MobileSessionStorage {
  Future<String?> getItem(String key);
  Future<void> setItem(String key, String value);
}

/// [MobileSessionStorage] over the strict methods of a [StorageAdapter],
/// matching RN's `{ getItem: getItemStrict, setItem: setItemStrict }`.
class StrictMobileSessionStorage implements MobileSessionStorage {
  StrictMobileSessionStorage(this.adapter);

  final StorageAdapter adapter;

  @override
  Future<String?> getItem(String key) => adapter.getItemStrict(key);

  @override
  Future<void> setItem(String key, String value) =>
      adapter.setItemStrict(key, value);
}

/// A wall-clock and monotonic-clock reading captured together, normally
/// synchronously in a lifecycle callback before the work is serialized
/// (RN's `at = { wallMs, monotonicMs }`).
class MobileTimePoint {
  const MobileTimePoint({required this.wallMs, required this.monotonicMs});

  final int wallMs;
  final int monotonicMs;

  @override
  bool operator ==(Object other) =>
      other is MobileTimePoint &&
      other.wallMs == wallMs &&
      other.monotonicMs == monotonicMs;

  @override
  int get hashCode => Object.hash(wallMs, monotonicMs);

  @override
  String toString() =>
      'MobileTimePoint(wallMs: $wallMs, monotonicMs: $monotonicMs)';
}

/// Session metadata attached to an event: `{sid, mobile_occurred_at}`.
class MobileSnapshot {
  const MobileSnapshot({required this.sid, required this.mobileOccurredAt});

  /// 13-digit epoch-millisecond session ID.
  final String sid;

  /// ISO-8601 UTC with milliseconds, never earlier than the session start.
  final String mobileOccurredAt;

  /// RN's plain-object shape; a new map on every call.
  Map<String, Object?> toJson() =>
      <String, Object?>{'sid': sid, 'mobile_occurred_at': mobileOccurredAt};

  @override
  bool operator ==(Object other) =>
      other is MobileSnapshot &&
      other.sid == sid &&
      other.mobileOccurredAt == mobileOccurredAt;

  @override
  int get hashCode => Object.hash(sid, mobileOccurredAt);

  @override
  String toString() => 'MobileSnapshot(${toJson()})';
}

/// A canonical mobile fact (`$mobile_*` event) as produced by the session:
/// `{event, eventProperties?, defaultProperties: {sid, mobile_occurred_at}}`.
/// Pass [toJson] to `normalizeMobilePayload` before queueing.
class MobileFact {
  MobileFact({
    required this.event,
    this.eventProperties,
    required this.defaultProperties,
  });

  factory MobileFact._fromSnapshot(
    String event,
    MobileSnapshot snapshot, [
    Map<String, Object?>? eventProperties,
  ]) =>
      MobileFact(
        event: event,
        eventProperties: eventProperties,
        defaultProperties: snapshot.toJson(),
      );

  static MobileFact? _fromJson(Object? value) {
    final json = _jsonMap(value);
    if (json == null) return null;
    final event = json['event'];
    if (event is! String) return null;
    return MobileFact(
      event: event,
      eventProperties: _jsonMap(json['eventProperties']),
      defaultProperties:
          _jsonMap(json['defaultProperties']) ?? <String, Object?>{},
    );
  }

  final String event;
  final Map<String, Object?>? eventProperties;
  final Map<String, Object?> defaultProperties;

  /// Detached copy (new maps), like RN's object spreads.
  MobileFact copy() => MobileFact(
        event: event,
        eventProperties: eventProperties == null
            ? null
            : Map<String, Object?>.from(eventProperties!),
        defaultProperties: Map<String, Object?>.from(defaultProperties),
      );

  /// RN's fact object; `eventProperties` is omitted when absent.
  Map<String, Object?> toJson() => <String, Object?>{
        'event': event,
        if (eventProperties != null)
          'eventProperties': Map<String, Object?>.from(eventProperties!),
        'defaultProperties': Map<String, Object?>.from(defaultProperties),
      };

  @override
  bool operator ==(Object other) =>
      other is MobileFact &&
      other.event == event &&
      mapEquals(other.eventProperties, eventProperties) &&
      mapEquals(other.defaultProperties, defaultProperties);

  @override
  int get hashCode => Object.hash(
        event,
        Object.hashAllUnordered(
            eventProperties?.entries.map((e) => Object.hash(e.key, e.value)) ??
                const <int>[]),
        Object.hashAllUnordered(
            defaultProperties.entries.map((e) => Object.hash(e.key, e.value))),
      );

  @override
  String toString() => 'MobileFact(${toJson()})';
}

/// A durable outbox record (`pendingEvents[]` in the persisted session):
/// the fact plus the identity and app version captured when it was recorded.
class MobilePendingFact {
  const MobilePendingFact({
    required this.id,
    this.queueAccepted,
    this.visitorId,
    this.isManuallySetId = false,
    this.appVersion,
    this.appBuild,
    required this.fact,
  });

  static MobilePendingFact? _fromJson(Object? value) {
    final json = _jsonMap(value);
    if (json == null) return null;
    final id = json['id'];
    final fact = MobileFact._fromJson(json['fact']);
    if (id is! String || fact == null) return null;
    final queueAccepted = json['queueAccepted'];
    final visitorId = json['visitorId'];
    final appVersion = json['appVersion'];
    final appBuild = json['appBuild'];
    return MobilePendingFact(
      id: id,
      queueAccepted: queueAccepted is bool ? queueAccepted : null,
      visitorId: visitorId is String ? visitorId : null,
      isManuallySetId: json['isManuallySetId'] == true,
      appVersion: appVersion is String ? appVersion : null,
      appBuild: appBuild is String ? appBuild : null,
      fact: fact,
    );
  }

  /// Fact UUID; reused as the queued event's `distinct_id`.
  final String id;

  /// `false` for an unqueued `$mobile_first_open`, `true` once the queue
  /// accepted it; null (omitted) for every other fact.
  final bool? queueAccepted;
  final String? visitorId;
  final bool isManuallySetId;
  final String? appVersion;
  final String? appBuild;
  final MobileFact fact;

  MobilePendingFact _withQueueAccepted(bool value) => MobilePendingFact(
        id: id,
        queueAccepted: value,
        visitorId: visitorId,
        isManuallySetId: isManuallySetId,
        appVersion: appVersion,
        appBuild: appBuild,
        fact: fact,
      );

  MobilePendingFact copy() => MobilePendingFact(
        id: id,
        queueAccepted: queueAccepted,
        visitorId: visitorId,
        isManuallySetId: isManuallySetId,
        appVersion: appVersion,
        appBuild: appBuild,
        fact: fact.copy(),
      );

  /// Persisted shape, field names identical to RN. `undefined` fields
  /// (queueAccepted on non-first-open facts, absent app version/build) are
  /// omitted the way `JSON.stringify` omits them.
  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        if (queueAccepted != null) 'queueAccepted': queueAccepted,
        'visitorId': visitorId,
        'isManuallySetId': isManuallySetId,
        if (appVersion != null) 'appVersion': appVersion,
        if (appBuild != null) 'appBuild': appBuild,
        'fact': fact.toJson(),
      };

  @override
  String toString() => 'MobilePendingFact(${toJson()})';
}

/// Persisted session record (`OURSPRIVACY_<token>_MOBILE_SESSION_V1`).
class _SessionState {
  _SessionState({
    required this.sid,
    required this.startedAtMs,
    required this.lastActiveAtMs,
    required this.lastSessionEpochMs,
    required this.lastIssuedSessionMs,
    required this.firstOpenSent,
    required this.observedAppVersion,
    required this.observedAppBuild,
    required this.sessionStartSent,
    required this.foregroundDurationMs,
    required this.pendingEvents,
  });

  String? sid;
  int? startedAtMs;
  int? lastActiveAtMs;
  int? lastSessionEpochMs;
  int? lastIssuedSessionMs;
  bool firstOpenSent;
  String? observedAppVersion;
  String? observedAppBuild;
  bool sessionStartSent;
  int foregroundDurationMs;
  List<MobilePendingFact> pendingEvents;

  /// Shallow copy with a new pendingEvents list (records are immutable),
  /// mirroring `{ ...this.state, pendingEvents: [...pendingEvents] }`.
  _SessionState copy() => _SessionState(
        sid: sid,
        startedAtMs: startedAtMs,
        lastActiveAtMs: lastActiveAtMs,
        lastSessionEpochMs: lastSessionEpochMs,
        lastIssuedSessionMs: lastIssuedSessionMs,
        firstOpenSent: firstOpenSent,
        observedAppVersion: observedAppVersion,
        observedAppBuild: observedAppBuild,
        sessionStartSent: sessionStartSent,
        foregroundDurationMs: foregroundDurationMs,
        pendingEvents: List<MobilePendingFact>.of(pendingEvents),
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'sid': sid,
        'startedAtMs': startedAtMs,
        'lastActiveAtMs': lastActiveAtMs,
        'lastSessionEpochMs': lastSessionEpochMs,
        'lastIssuedSessionMs': lastIssuedSessionMs,
        'firstOpenSent': firstOpenSent,
        'observedAppVersion': observedAppVersion,
        'observedAppBuild': observedAppBuild,
        'sessionStartSent': sessionStartSent,
        'foregroundDurationMs': foregroundDurationMs,
        'pendingEvents':
            pendingEvents.map((record) => record.toJson()).toList(),
      };
}

/// In-memory fields restored when a serialized operation fails.
class _Memento {
  _Memento(MobileSession session)
      : state = session._state?.copy(),
        foregrounded = session._foregrounded,
        paused = session._paused,
        automaticEnabled = session._automaticEnabled,
        engagementMarkMs = session._engagementMarkMs,
        activeScreen = session._activeScreen,
        disabled = session._disabled,
        pendingFacts = List<MobileFact>.of(session._pendingFacts);

  final _SessionState? state;
  final bool foregrounded;
  final bool paused;
  final bool automaticEnabled;
  final int? engagementMarkMs;
  final String? activeScreen;
  final bool disabled;
  final List<MobileFact> pendingFacts;

  void restore(MobileSession session) {
    session._state = state;
    session._foregrounded = foregrounded;
    session._paused = paused;
    session._automaticEnabled = automaticEnabled;
    session._engagementMarkMs = engagementMarkMs;
    session._activeScreen = activeScreen;
    session._disabled = disabled;
    session._pendingFacts = pendingFacts;
  }
}

/// Mobile session state machine (port of RN `MobileSession`).
///
/// * A session continues until 30 minutes pass without activity while the
///   app is not in the foreground ([sessionTimeoutMs]); an active foreground
///   never times out.
/// * A wall clock moved back more than 5 minutes ([clockRollbackMs]) behind
///   the last activity ends the session and starts a new one.
/// * Engagement is measured on the monotonic clock and emitted at screen
///   changes, pause/background, and every 10 accumulated foreground seconds
///   ([engagedMs]) via [checkpoint].
/// * Session IDs are the 13-digit epoch ms of the start; a rotation within
///   the rollback tolerance always issues a strictly larger ID.
class MobileSession {
  MobileSession({
    required this.token,
    required this.storage,
    int Function()? wallNow,
    int Function()? monotonicNow,
    this.appVersion,
    this.appBuild,
    String? Function()? getVisitorId,
    bool Function()? getIsManuallySetId,
  })  : wallNow = wallNow ?? defaultWallNow,
        monotonicNow = monotonicNow ?? defaultMonotonicNow,
        _getVisitorId = getVisitorId,
        _getIsManuallySetId = getIsManuallySetId;

  static const int sessionTimeoutMs = 30 * 60 * 1000;
  static const int clockRollbackMs = 5 * 60 * 1000;
  static const int engagedMs = 10 * 1000;

  final String token;
  final MobileSessionStorage storage;

  /// Epoch milliseconds.
  final int Function() wallNow;

  /// Monotonic milliseconds; only differences are meaningful.
  final int Function() monotonicNow;

  /// Host app version/build, set by the orchestrator before [load]. Stamped
  /// on each recorded fact and compared with the observed version for
  /// `$mobile_app_update`.
  String? appVersion;
  String? appBuild;

  /// Whether persistent storage already held SDK state when no session
  /// record exists (an install that predates mobile sessions). Read only by
  /// the first [load]; it marks first-open as already sent.
  bool existingInstall = false;

  final String? Function()? _getVisitorId;
  final bool Function()? _getIsManuallySetId;

  _SessionState? _state;
  bool _foregrounded = false;
  bool _paused = false;
  bool _automaticEnabled = false;
  int? _engagementMarkMs;
  String? _activeScreen;
  bool _disabled = false;
  List<MobileFact> _pendingFacts = <MobileFact>[];
  final Set<String> _acceptedFactIds = <String>{};
  Future<void> _pending = Future<void>.value();

  String get _storageKey => mobileSessionKey(token);

  /// True after a successful [load] (or any operation that loads).
  bool get isLoaded => _state != null;
  bool get foregrounded => _foregrounded;
  bool get paused => _paused;
  bool get automaticEnabled => _automaticEnabled;
  bool get disabled => _disabled;
  String? get activeScreen => _activeScreen;

  /// Current session ID, or null when there is no session (or not loaded).
  String? get sid => _state?.sid;

  /// Start of the current session in epoch ms (RN `state.startedAtMs`).
  int? get startedAtMs => _state?.startedAtMs;

  Future<T> _serialize<T>(FutureOr<T> Function() action) {
    final result = _pending.then((_) async {
      final previous = _Memento(this);
      try {
        return await action();
      } catch (_) {
        previous.restore(this);
        rethrow;
      }
    });
    _pending = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<void> _load() async {
    if (_state != null) return;
    final stored = await storage.getItem(_storageKey);
    final hasStored = stored != null && stored.isNotEmpty;
    Object? parsed;
    try {
      parsed = hasStored ? jsonDecode(stored) : null;
    } catch (_) {
      parsed = null;
    }
    final record =
        parsed is Map<String, Object?> ? parsed : <String, Object?>{};
    final startedAtMs = _safeInteger(record['startedAtMs']);
    final lastActiveAtMs = _safeInteger(record['lastActiveAtMs']);
    final validSession = _isSessionId(record['sid']) &&
        startedAtMs != null &&
        _isSessionId(startedAtMs.toString()) &&
        lastActiveAtMs != null &&
        lastActiveAtMs >= startedAtMs;
    final storedDuration = _safeInteger(record['foregroundDurationMs']);
    final storedEvents = record['pendingEvents'];
    _state = _SessionState(
      sid: validSession ? startedAtMs.toString() : null,
      startedAtMs: validSession ? startedAtMs : null,
      lastActiveAtMs: validSession ? lastActiveAtMs : null,
      lastSessionEpochMs: _safeInteger(record['lastSessionEpochMs']) ??
          (validSession ? startedAtMs : null),
      lastIssuedSessionMs: _safeInteger(record['lastIssuedSessionMs']) ??
          (validSession ? startedAtMs : null),
      firstOpenSent:
          record['firstOpenSent'] == true || (!hasStored && existingInstall),
      observedAppVersion: _observed(
          record['observedAppVersion'], hasStored ? null : appVersion),
      observedAppBuild:
          _observed(record['observedAppBuild'], hasStored ? null : appBuild),
      sessionStartSent: validSession && record['sessionStartSent'] == true,
      foregroundDurationMs: validSession && storedDuration != null
          ? (storedDuration < 0 ? 0 : storedDuration)
          : 0,
      pendingEvents: storedEvents is List
          ? storedEvents
              .map(MobilePendingFact._fromJson)
              .whereType<MobilePendingFact>()
              .toList()
          : <MobilePendingFact>[],
    );
  }

  /// `record.observedX ?? (!stored && existingInstall ? (appX ?? null) : null)`.
  String? _observed(Object? stored, String? current) {
    if (stored is String) return stored;
    if (stored != null) return null;
    return existingInstall ? current : null;
  }

  /// Reads the persisted session (once). Throws if storage throws.
  Future<void> load() => _serialize(_load);

  Future<void> _persist() =>
      storage.setItem(_storageKey, jsonEncode(_state!.toJson()));

  void _recordFacts(List<MobileFact> facts) {
    if (facts.isEmpty) return;
    for (final fact in facts) {
      _state!.pendingEvents.add(MobilePendingFact(
        id: uuidv4(),
        queueAccepted: fact.event == _firstOpenEvent ? false : null,
        visitorId: _getVisitorId?.call(),
        isManuallySetId: _getIsManuallySetId?.call() ?? false,
        appVersion: appVersion,
        appBuild: appBuild,
        fact: fact.copy(),
      ));
    }
  }

  /// Detached copies of the durable outbox, oldest first.
  Future<List<MobilePendingFact>> pendingQueueFacts() => _serialize(() async {
        await _load();
        return _state!.pendingEvents.map((record) => record.copy()).toList();
      });

  /// Records that the queue accepted a `$mobile_first_open` fact. A no-op
  /// for any other fact. The in-memory acceptance is recorded synchronously
  /// so a concurrent [disableTracking] sees it.
  Future<void> markFactQueued(String id) {
    MobilePendingFact? record;
    for (final item in _state?.pendingEvents ?? const <MobilePendingFact>[]) {
      if (item.id == id) {
        record = item;
        break;
      }
    }
    if (record?.fact.event != _firstOpenEvent) return Future<void>.value();
    _acceptedFactIds.add(id);
    return _serialize(() async {
      await _load();
      _state!.pendingEvents = _state!.pendingEvents
          .map((record) =>
              record.id == id ? record._withQueueAccepted(true) : record)
          .toList();
      await _persist();
    });
  }

  /// Removes a fact from the durable outbox once it is in the event queue.
  Future<void> acknowledgeFact(String id) => _serialize(() async {
        await _load();
        _state!.pendingEvents =
            _state!.pendingEvents.where((record) => record.id != id).toList();
        await _persist();
        _acceptedFactIds.remove(id);
      });

  MobileSnapshot _snapshot(int atMs) {
    final startedAtMs = _state!.startedAtMs!;
    return MobileSnapshot(
      sid: _state!.sid!,
      mobileOccurredAt:
          isoFromMilliseconds(atMs > startedAtMs ? atMs : startedAtMs),
    );
  }

  MobileFact? _engagementFact(int atMs, int monotonicMs, int minimumMs) {
    if (!_foregrounded || !_automaticEnabled) return null;
    final durationMs = monotonicMs - (_engagementMarkMs ?? monotonicMs);
    if (durationMs <= 0) return null;
    final state = _state!;
    if (minimumMs > 0 &&
        (state.foregroundDurationMs + durationMs) ~/ minimumMs ==
            state.foregroundDurationMs ~/ minimumMs) {
      return null;
    }
    _engagementMarkMs = monotonicMs;
    state.foregroundDurationMs += durationMs;
    final eventProperties = <String, Object?>{
      'engagement_duration_ms': durationMs,
    };
    final activeScreen = _activeScreen;
    if (activeScreen != null && activeScreen.isNotEmpty) {
      eventProperties['screen_name'] = activeScreen;
    }
    return MobileFact._fromSnapshot(
        _sessionEngagementEvent, _snapshot(atMs), eventProperties);
  }

  /// Milliseconds until the next 10-second engagement boundary, or null
  /// when no checkpoint should be scheduled (not foregrounded, automatic
  /// events off, or not loaded). Never less than 1.
  int? remainingCheckpointMs() {
    final state = _state;
    if (!_foregrounded || !_automaticEnabled || state == null) return null;
    final now = monotonicNow();
    final elapsed = now - (_engagementMarkMs ?? now);
    final elapsedMs = elapsed < 0 ? 0 : elapsed;
    final remaining =
        engagedMs - (state.foregroundDurationMs % engagedMs) - elapsedMs;
    return remaining < 1 ? 1 : remaining;
  }

  void _startSession(int atMs) {
    final state = _state!;
    final lastSessionEpochMs = state.lastSessionEpochMs;
    final lastIssuedSessionMs = state.lastIssuedSessionMs;
    final int issuedAt;
    if (lastSessionEpochMs != null &&
        lastIssuedSessionMs != null &&
        lastSessionEpochMs - atMs <= clockRollbackMs) {
      final next = lastIssuedSessionMs + 1;
      issuedAt = atMs > next ? atMs : next;
    } else {
      issuedAt = atMs;
    }
    state.sid = issuedAt.toString();
    state.startedAtMs = issuedAt;
    state.lastActiveAtMs = issuedAt;
    state.lastSessionEpochMs = atMs;
    state.lastIssuedSessionMs = issuedAt;
    state.sessionStartSent = false;
    state.foregroundDurationMs = 0;
  }

  void _touch(int atMs) {
    final state = _state!;
    var value = atMs;
    final startedAtMs = state.startedAtMs;
    final lastActiveAtMs = state.lastActiveAtMs;
    if (startedAtMs != null && startedAtMs > value) value = startedAtMs;
    if (lastActiveAtMs != null && lastActiveAtMs > value) {
      value = lastActiveAtMs;
    }
    state.lastActiveAtMs = value;
  }

  void _discardSession({bool clearPending = true}) {
    final state = _state!;
    _foregrounded = false;
    _paused = false;
    _automaticEnabled = false;
    _engagementMarkMs = null;
    _activeScreen = null;
    state.sid = null;
    state.startedAtMs = null;
    state.lastActiveAtMs = null;
    state.sessionStartSent = false;
    state.foregroundDurationMs = 0;
    if (clearPending) state.pendingEvents = <MobilePendingFact>[];
    _pendingFacts = <MobileFact>[];
  }

  MobileFact? _sessionEnd() {
    final state = _state!;
    final sid = state.sid;
    if (sid == null || sid.isEmpty || !state.sessionStartSent) return null;
    return MobileFact._fromSnapshot(
        _sessionEndEvent, _snapshot(state.lastActiveAtMs!));
  }

  List<MobileFact> _replaceExpiredSession(int atMs, [bool? allowTimeout]) {
    final timeoutAllowed = allowTimeout ?? (!_foregrounded && !_paused);
    final state = _state!;
    final sid = state.sid;
    final lastActiveAtMs = state.lastActiveAtMs;
    final rollback = sid != null &&
        sid.isNotEmpty &&
        lastActiveAtMs != null &&
        lastActiveAtMs - atMs > clockRollbackMs;
    if (!rollback && !(timeoutAllowed && _sessionExpired(atMs))) {
      return <MobileFact>[];
    }
    final end = _sessionEnd();
    _startSession(atMs);
    _activeScreen = null;
    final facts = <MobileFact>[if (end != null) end];
    if (_foregrounded && _automaticEnabled) {
      _engagementMarkMs = monotonicNow();
      facts.add(MobileFact._fromSnapshot(_sessionStartEvent, _snapshot(atMs)));
      state.sessionStartSent = true;
    }
    return facts;
  }

  bool _sessionExpired(int atMs) {
    final state = _state!;
    final sid = state.sid;
    final lastActiveAtMs = state.lastActiveAtMs;
    return sid != null &&
        sid.isNotEmpty &&
        lastActiveAtMs != null &&
        atMs - lastActiveAtMs >= sessionTimeoutMs;
  }

  /// App entered the foreground (RN `foreground(automaticEnabled,
  /// emitOpenFacts, at, emitAppOpen)`).
  ///
  /// With [automaticEnabled], returns (and records) first-open, app-open,
  /// session-start and app-update facts as applicable. [emitOpenFacts] false
  /// suppresses first-open/app-open/app-update (session-start still emits);
  /// [emitAppOpen] false suppresses only app-open (a continuing foreground
  /// across re-init). No-op while already foregrounded or disabled.
  Future<List<MobileFact>> foreground({
    bool automaticEnabled = false,
    bool emitOpenFacts = true,
    MobileTimePoint? at,
    bool emitAppOpen = true,
  }) {
    final atMs = at?.wallMs ?? wallNow();
    final monotonicMs = at?.monotonicMs ?? monotonicNow();
    return _serialize(() async {
      await _load();
      if (_disabled || _foregrounded) return <MobileFact>[];
      final facts = _replaceExpiredSession(atMs, true);
      _foregrounded = true;
      _paused = false;
      _automaticEnabled = automaticEnabled;
      _engagementMarkMs = monotonicMs;
      _activeScreen = null;
      final state = _state!;
      if (state.sid == null || state.sid!.isEmpty) {
        _startSession(atMs);
      }
      _touch(atMs);
      if (automaticEnabled) {
        final snapshot = _snapshot(atMs);
        final previousVersion = state.observedAppVersion;
        final previousBuild = state.observedAppBuild;
        final updated = state.firstOpenSent &&
            ((appVersion != null &&
                    previousVersion != null &&
                    appVersion != previousVersion) ||
                (appBuild != null &&
                    previousBuild != null &&
                    appBuild != previousBuild));
        if (emitOpenFacts && !state.firstOpenSent) {
          facts.add(MobileFact._fromSnapshot(_firstOpenEvent, snapshot));
          state.firstOpenSent = true;
        }
        if (emitOpenFacts && emitAppOpen) {
          facts.add(MobileFact._fromSnapshot(_appOpenEvent, snapshot));
        }
        if (!state.sessionStartSent) {
          facts.add(MobileFact._fromSnapshot(_sessionStartEvent, snapshot));
          state.sessionStartSent = true;
        }
        if (emitOpenFacts && updated) {
          final eventProperties = <String, Object?>{};
          if (previousVersion != null) {
            eventProperties['previous_app_version'] = previousVersion;
          }
          if (previousBuild != null) {
            eventProperties['previous_app_build'] = previousBuild;
          }
          facts.add(MobileFact._fromSnapshot(
              _appUpdateEvent, snapshot, eventProperties));
        }
        if (emitOpenFacts) {
          if (appVersion != null) state.observedAppVersion = appVersion;
          if (appBuild != null) state.observedAppBuild = appBuild;
        }
      }
      _recordFacts(facts);
      await _persist();
      return facts;
    });
  }

  /// App went to the background. Emits the final engagement delta unless
  /// the app was already paused (the pause emitted it); then it only clears
  /// the paused flag and the active screen.
  Future<List<MobileFact>> background({MobileTimePoint? at}) {
    final atMs = at?.wallMs ?? wallNow();
    final monotonicMs = at?.monotonicMs ?? monotonicNow();
    return _serialize(() async {
      await _load();
      if (_paused) {
        _paused = false;
        _activeScreen = null;
        return <MobileFact>[];
      }
      if (!_foregrounded) return <MobileFact>[];
      final engagement = _engagementFact(atMs, monotonicMs, 0);
      _foregrounded = false;
      _activeScreen = null;
      _touch(atMs);
      if (engagement != null) _recordFacts(<MobileFact>[engagement]);
      await _persist();
      return <MobileFact>[if (engagement != null) engagement];
    });
  }

  /// App became inactive while foregrounded (dialog, shade, app switcher).
  /// Emits the engagement delta and keeps the active screen for [resume].
  Future<List<MobileFact>> pause({MobileTimePoint? at}) {
    final atMs = at?.wallMs ?? wallNow();
    final monotonicMs = at?.monotonicMs ?? monotonicNow();
    return _serialize(() async {
      await _load();
      if (!_foregrounded || _disabled) return <MobileFact>[];
      final engagement = _engagementFact(atMs, monotonicMs, 0);
      _foregrounded = false;
      _paused = true;
      _engagementMarkMs = null;
      _touch(atMs);
      if (engagement != null) _recordFacts(<MobileFact>[engagement]);
      await _persist();
      return <MobileFact>[if (engagement != null) engagement];
    });
  }

  /// Returns to the foreground from a [pause] without an app-open. Returns
  /// false when not paused, disabled, or the session expired/rolled back
  /// while paused (any session-end is recorded); the caller then calls
  /// [foreground].
  Future<bool> resume({MobileTimePoint? at}) {
    final atMs = at?.wallMs ?? wallNow();
    final monotonicMs = at?.monotonicMs ?? monotonicNow();
    return _serialize(() async {
      await _load();
      if (!_paused || _disabled) return false;
      final previousSid = _state!.sid;
      final facts = _replaceExpiredSession(atMs, true);
      if (_state!.sid != previousSid) {
        _paused = false;
        _recordFacts(facts);
        await _persist();
        return false;
      }
      _paused = false;
      _foregrounded = true;
      _engagementMarkMs = monotonicMs;
      _touch(atMs);
      await _persist();
      return true;
    });
  }

  /// Periodic foreground checkpoint: rotates an expired or rolled-back
  /// session and emits engagement when a 10-second boundary was crossed.
  Future<List<MobileFact>> checkpoint() {
    final atMs = wallNow();
    final monotonicMs = monotonicNow();
    return _serialize(() async {
      await _load();
      final facts = _replaceExpiredSession(atMs);
      final engagement = _engagementFact(atMs, monotonicMs, engagedMs);
      if (engagement != null) facts.add(engagement);
      if (facts.isEmpty) return <MobileFact>[];
      _touch(atMs);
      _recordFacts(facts);
      await _persist();
      return facts;
    });
  }

  /// Explicit screen view. The label is trimmed; an empty label is ignored
  /// (label validation is the facade's job). Repeating the visible screen is
  /// a no-op. Emits the previous screen's engagement first.
  Future<List<MobileFact>> screen(String? name, {MobileTimePoint? at}) {
    final atMs = at?.wallMs ?? wallNow();
    final monotonicMs = at?.monotonicMs ?? monotonicNow();
    return _serialize(() async {
      await _load();
      if (_disabled) return <MobileFact>[];
      final screenName = name?.trim() ?? '';
      if (screenName.isEmpty) return <MobileFact>[];
      final facts = _replaceExpiredSession(atMs);
      if (screenName == _activeScreen) return <MobileFact>[];
      final engagement = _engagementFact(atMs, monotonicMs, 0);
      final state = _state!;
      if (state.sid == null || state.sid!.isEmpty) _startSession(atMs);
      _activeScreen = screenName;
      if (!_paused) _touch(atMs);
      final view = MobileFact._fromSnapshot(
        _screenViewEvent,
        _snapshot(atMs),
        <String, Object?>{'screen_name': screenName},
      );
      if (engagement != null) facts.add(engagement);
      facts.add(view);
      _recordFacts(facts);
      await _persist();
      return facts;
    });
  }

  /// Session metadata for a manual event at [atMs] (defaults to now, read
  /// synchronously). Starts a session if needed. A session-end produced by
  /// an observed timeout is held for [drainPendingFacts]. Null when
  /// disabled.
  Future<MobileSnapshot?> snapshot([int? atMs]) {
    final at = atMs ?? wallNow();
    return _serialize(() async {
      await _load();
      if (_disabled) return null;
      final facts = _replaceExpiredSession(at);
      _pendingFacts.addAll(
          facts.where((fact) => fact.event == _sessionEndEvent).toList());
      _recordFacts(facts);
      final state = _state!;
      if (state.sid == null || state.sid!.isEmpty) _startSession(at);
      if (!_paused) _touch(at);
      final snapshot = _snapshot(at);
      await _persist();
      return snapshot;
    });
  }

  /// Takes the facts held by [snapshot] (does not load).
  Future<List<MobileFact>> drainPendingFacts() => _serialize(() {
        final facts = _pendingFacts;
        _pendingFacts = <MobileFact>[];
        return facts;
      });

  /// Ends the current session (if announced) and clears it; the next
  /// activity starts a new one. Keeps the durable outbox.
  Future<List<MobileFact>> resetSession() => _serialize(() async {
        await _load();
        final end = _sessionEnd();
        if (end != null) _recordFacts(<MobileFact>[end]);
        _discardSession(clearPending: false);
        await _persist();
        return <MobileFact>[if (end != null) end];
      });

  /// Identity rotation: emits engagement and session-end for the current
  /// session, then, if foregrounded, starts a new session immediately with
  /// the same screen. Call [announceRotatedSession] afterwards to emit its
  /// session-start under the new identity.
  Future<List<MobileFact>> rotateSession() {
    final atMs = wallNow();
    final monotonicMs = monotonicNow();
    return _serialize(() async {
      await _load();
      final wasForegrounded = _foregrounded;
      final automaticEnabled = _automaticEnabled;
      final activeScreen = _activeScreen;
      final engagement = _engagementFact(atMs, monotonicMs, 0);
      if (wasForegrounded) _touch(atMs);
      final end = _sessionEnd();
      final facts = <MobileFact>[
        if (engagement != null) engagement,
        if (end != null) end,
      ];
      _recordFacts(facts);
      _discardSession(clearPending: false);
      if (wasForegrounded) {
        _startSession(atMs);
        _foregrounded = true;
        _automaticEnabled = automaticEnabled;
        _engagementMarkMs = monotonicMs;
        _activeScreen = activeScreen;
      }
      await _persist();
      return facts;
    });
  }

  /// Emits the session-start for a session created by [rotateSession], once.
  Future<List<MobileFact>> announceRotatedSession() => _serialize(() async {
        await _load();
        final state = _state!;
        if (_disabled ||
            !_foregrounded ||
            !_automaticEnabled ||
            state.sessionStartSent) {
          return <MobileFact>[];
        }
        final fact = MobileFact._fromSnapshot(
            _sessionStartEvent, _snapshot(state.startedAtMs!));
        state.sessionStartSent = true;
        _recordFacts(<MobileFact>[fact]);
        await _persist();
        return <MobileFact>[fact];
      });

  /// Full tracking opt-out: discards the session and the durable outbox.
  /// First-open stays eligible unless it was accepted by the queue
  /// ([firstOpenAccepted], or a [markFactQueued] in this process).
  Future<List<MobileFact>> disableTracking({bool firstOpenAccepted = false}) =>
      _serialize(() async {
        await _load();
        final state = _state!;
        if (firstOpenAccepted) {
          state.firstOpenSent = true;
        } else if (state.pendingEvents.any((record) =>
            record.fact.event == _firstOpenEvent &&
            record.queueAccepted != true &&
            !_acceptedFactIds.contains(record.id))) {
          state.firstOpenSent = false;
        }
        _disabled = true;
        _discardSession();
        await _persist();
        _acceptedFactIds.clear();
        return <MobileFact>[];
      });
}
