// Port of javascript/oursprivacy-main.js (React Native SDK).
//
// The orchestrator behind the public `OursPrivacy` facade: initialization,
// the serialized operation chain, the mobile session and lifecycle wiring,
// the engagement checkpoint timer, default and attribution properties, the
// user-property wire map, identity rotation, consent (opt-in / opt-out) and
// event composition.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;

import 'attribution.dart';
import 'config.dart';
import 'constants.dart';
import 'core.dart';
import 'device_info.dart';
import 'errors.dart';
import 'lifecycle.dart';
import 'logger.dart';
import 'mobile_payload.dart';
import 'mobile_session.dart';
import 'network.dart';
import 'persistent.dart';
import 'storage.dart';
import 'utils.dart';

/// Retry delay for a failed engagement checkpoint (RN
/// `CHECKPOINT_INTERVAL_MS`).
final int _checkpointIntervalMs = checkpointInterval.inMilliseconds;

// Caller-facing user-property field names are camelCase. The wire format
// (and server schema in @ours/types) is snake_case. Translate at the wire
// boundary here so the rest of the SDK and the queue payload stay snake_case.
const Map<String, String> userPropsWireMap = {
  'externalId': 'external_id',
  'phoneNumber': 'phone_number',
  'firstName': 'first_name',
  'lastName': 'last_name',
  'dateOfBirth': 'date_of_birth',
  'companyName': 'company_name',
  'jobTitle': 'job_title',
  'customProperties': 'custom_properties',
};

/// Renames caller-facing user-property keys to their wire names.
Map<String, Object?>? toWireUserProperties(Map<String, Object?>? userProps) {
  if (userProps == null) return null;
  final wire = <String, Object?>{};
  for (final key in userProps.keys) {
    final wireKey = userPropsWireMap[key] ?? key;
    wire[wireKey] = userProps[key];
  }
  return wire;
}

/// JavaScript truthiness for a property value.
bool _truthy(Object? value) =>
    value != null &&
    value != false &&
    value != '' &&
    !(value is num && (value == 0 || value.isNaN));

/// `{...value}` for a JSON value: a map spreads its entries, anything else
/// spreads nothing.
Map<String, Object?> _spreadable(Object? value) {
  if (value is Map<String, Object?>) return value;
  if (value is Map) {
    return {
      for (final entry in value.entries)
        if (entry.key is String) entry.key as String: entry.value,
    };
  }
  return const {};
}

/// Session metadata attached to an event: RN's `{sid, mobile_occurred_at}`
/// snapshot object. Either field may be missing for a stored fact whose
/// metadata did not survive normalization.
typedef OursPrivacyEventSnapshot = ({String? sid, String? mobileOccurredAt});

/// App release metadata for a canonical fact (RN `appMetadata`).
typedef _AppMetadata = ({String? appVersion, String? appBuild});

/// Options accepted by `OursPrivacy.init`, as one object (RN's options bag).
class OursPrivacyInitOptions {
  const OursPrivacyInitOptions({
    this.trackAutomaticEvents = false,
    this.appVersion,
    this.appBuild,
    this.onIngestRejected,
    this.optOutTrackingByDefault = false,
    this.serverURL,
    this.visitorId,
    this.initialURL,
    this.defaultEventProperties,
    this.defaultUserCustomProperties,
    this.defaultUserConsentProperties,
    this.storage,
    this.httpClient,
  });

  final bool trackAutomaticEvents;
  final String? appVersion;
  final String? appBuild;
  final OursPrivacyIngestRejectedCallback? onIngestRejected;
  final bool optOutTrackingByDefault;
  final String? serverURL;
  final String? visitorId;
  final String? initialURL;
  final Map<String, Object?>? defaultEventProperties;
  final Map<String, Object?>? defaultUserCustomProperties;
  final Map<String, Object?>? defaultUserConsentProperties;
  final OursPrivacyStorage? storage;
  final http.Client? httpClient;
}

/// Injectable platform seams. Every field defaults to the real platform; tests
/// replace them (see `lib/src/testing.dart`).
class OursPrivacyEnvironment {
  const OursPrivacyEnvironment({
    this.deviceInfo,
    this.lifecycleSourceFactory,
    this.wallNow,
    this.monotonicNow,
    this.timerFactory,
    this.network,
  });

  /// Device facts and the mobile-platform gate. Default:
  /// `OursPrivacyDeviceInfo.current`, read at call time.
  final OursPrivacyDeviceInfo? deviceInfo;

  /// Creates the app-lifecycle source for each SDK instance (one per
  /// `init`). Default: `FlutterLifecycleSource.new`.
  final LifecycleSource Function()? lifecycleSourceFactory;

  /// Epoch milliseconds (RN `Date.now()`). Default: `defaultWallNow`.
  final int Function()? wallNow;

  /// Monotonic milliseconds (RN `performance.now()`). Default:
  /// `defaultMonotonicNow`.
  final int Function()? monotonicNow;

  /// Creates the checkpoint and flush timers. Default: `Timer.new` (works
  /// with fake_async).
  final OursPrivacyTimerFactory? timerFactory;

  /// Network used for uploads. Default: `OursPrivacyNetwork.shared`.
  final OursPrivacyNetwork? network;
}

/// Facade object -> its current [OursPrivacyMain]. Lets tests reach the
/// implementation (RN tests use `op.oursprivacyImpl`) without widening the
/// public API.
final Expando<OursPrivacyMain> oursPrivacyImpls =
    Expando<OursPrivacyMain>('OursPrivacyMain');

/// Facade object -> the environment its next `init` uses.
final Expando<OursPrivacyEnvironment> oursPrivacyEnvironments =
    Expando<OursPrivacyEnvironment>('OursPrivacyEnvironment');

/// Environment used by every facade without its own entry in
/// [oursPrivacyEnvironments]. Null in production.
OursPrivacyEnvironment? oursPrivacyDefaultEnvironment;

class OursPrivacyMain {
  OursPrivacyMain(
    this.token, {
    OursPrivacyStorage? storage,
    http.Client? httpClient,
    OursPrivacyEnvironment environment = const OursPrivacyEnvironment(),
  })  : _environment = environment,
        _timerFactory = environment.timerFactory ?? Timer.new,
        core = OursPrivacyCore(
          storage: storage,
          network: environment.network,
          httpClient: httpClient,
          timerFactory: environment.timerFactory,
        ) {
    persistent = core.persistent;
    _coreReady = core.initialize(token);
    unawaited(_coreReady.then<void>((_) {}, onError: (Object _) {}));
    _mobileSession = _createMobileSession(token);
    _lifecycleSource =
        (environment.lifecycleSourceFactory ?? FlutterLifecycleSource.new)();
    _subscribeToAppState(token);
    _latestAppState = _lifecycleSource.currentState;
    _lifecycle.seed(_latestAppState);
  }

  final String token;
  final OursPrivacyEnvironment _environment;
  final OursPrivacyTimerFactory _timerFactory;
  final OursPrivacyCore core;
  late final OursPrivacyPersistent persistent;
  late final Future<void> _coreReady;
  late MobileSession _mobileSession;
  late final LifecycleSource _lifecycleSource;

  OursPrivacyConfig get config => OursPrivacyConfig.instance;

  Future<void> _pendingOperation = Future<void>.value();
  int _consentRevision = 0;
  bool _disposed = false;
  bool _trackAutomaticEvents = false;
  String? _appVersion;
  String? _appBuild;
  OursAppState? _latestAppState;
  bool _hasAppStateEvent = false;
  MobileTimePoint? _latestAppStateAt;
  bool _continuingForeground = false;
  bool _reusedSession = false;
  // RN `_appForegrounded` / `_appInactive` live in the state machine.
  final LifecycleStateMachine _lifecycle = LifecycleStateMachine();
  Timer? _checkpointTimer;
  bool _initialized = false;
  final Map<String, Map<String, Object?>> _defaultEventProperties = {};
  final Map<String, Map<String, Object?>> _defaultUserCustomProperties = {};
  final Map<String, Map<String, Object?>> _defaultUserConsentProperties = {};
  final Map<String, Map<String, Object?>> _attributionDefaultProperties = {};
  bool _flushOnBackgroundEnabled = true;
  bool _subscribed = false;

  // ---- Test-visible state -------------------------------------------------

  /// The current mobile session.
  @visibleForTesting
  MobileSession get mobileSession => _mobileSession;

  /// True once [initialize] finished (and until dispose or a failed init).
  @visibleForTesting
  bool get isInitialized => _initialized;

  @visibleForTesting
  bool get isDisposed => _disposed;

  /// RN `_appForegrounded`.
  @visibleForTesting
  bool get appForegrounded => _lifecycle.foregrounded;

  /// RN `_appInactive`.
  @visibleForTesting
  bool get appInactive => _lifecycle.inactive;

  @visibleForTesting
  bool get trackAutomaticEvents => _trackAutomaticEvents;

  /// True while an engagement checkpoint timer is scheduled or running.
  @visibleForTesting
  bool get hasCheckpointTimer => _checkpointTimer != null;

  /// True when this instance took over its predecessor's session on re-init.
  @visibleForTesting
  bool get reusedSession => _reusedSession;

  @visibleForTesting
  bool get flushOnBackgroundEnabled => _flushOnBackgroundEnabled;

  /// The lifecycle source this instance listens to.
  @visibleForTesting
  LifecycleSource get lifecycleSource => _lifecycleSource;

  /// Memory-only link attribution (UTM parameters and click IDs).
  @visibleForTesting
  Map<String, Object?> attributionDefaultProperties(String token) =>
      Map.unmodifiable(_attributionDefaultProperties[token] ?? const {});

  @visibleForTesting
  Map<String, Object?> defaultEventProperties(String token) =>
      Map.unmodifiable(_defaultEventProperties[token] ?? const {});

  // -------------------------------------------------------------------------

  OursPrivacyDeviceInfo get _deviceInfo =>
      _environment.deviceInfo ?? OursPrivacyDeviceInfo.current;

  int _wallNow() => (_environment.wallNow ?? defaultWallNow)();

  bool _shouldLog(String token) =>
      oursPrivacyLogSink != null || config.getLoggingEnabled(token);

  /// Initialize the SDK from a single options bag. All caller-facing keys
  /// are camelCase; this is the entry point that converts/applies them.
  Future<void> initialize(String token, OursPrivacyInitOptions options) {
    return _serialize(() async {
      OursPrivacyLogger.log(token, 'Initializing OursPrivacy');

      await _coreReady;
      await persistent.initializationComplete(token);

      final serverURL =
          options.serverURL != null && options.serverURL!.isNotEmpty
              ? options.serverURL!
              : defaultServerURL;
      setServerURL(token, serverURL);
      config.setOnIngestRejected(token, options.onIngestRejected);

      // Set opt-out flag BEFORE applying options so that initialURL processing
      // (which may fire $deep_link_opened) respects the opted-out state.
      if (!persistent.hasStoredOptOutDecision(token) &&
          (persistent.hasStoredOptOutDefault(token) ||
              (options.optOutTrackingByDefault &&
                  !persistent.getOptedOut(token)))) {
        await _setOptedOutTrackingFlag(
          token,
          options.optOutTrackingByDefault,
          explicitDecision: false,
        );
      }

      _trackAutomaticEvents = options.trackAutomaticEvents;
      _appVersion = options.appVersion;
      _appBuild = options.appBuild;
      _mobileSession.appVersion = _appVersion;
      _mobileSession.appBuild = _appBuild;
      _mobileSession.existingInstall = persistent.hasExistingInstall(token);
      await _mobileSession.load();
      await _applyInitializationOptions(token, options);

      // AppLifecycleListener does not replay the current state: use the
      // latest state received while initializing, or ask the binding.
      final currentState =
          _hasAppStateEvent ? _latestAppState : _lifecycleSource.currentState;
      final startedAtMs = _mobileSession.startedAtMs;
      final latestAt = _latestAppStateAt;
      final currentStateAt = startedAtMs != null &&
              latestAt != null &&
              latestAt.wallMs < startedAtMs
          ? null
          : latestAt;
      _lifecycle.seed(currentState);
      _initialized = true;
      try {
        if (persistent.getOptedOut(token)) {
          await _mobileSession.disableTracking(
            firstOpenAccepted: core.queueManager.hasAcceptedFirstOpen(
              token,
              eventsQueueType,
            ),
          );
          await core.queueManager.clearQueue(token, eventsQueueType);
        } else {
          await _enqueuePendingFacts(token);
          if (_lifecycle.foregrounded && _isMobilePlatform()) {
            final resumed = _reusedSession &&
                await _mobileSession.resume(at: currentStateAt);
            if (!resumed) {
              await _mobileSession.foreground(
                automaticEnabled: _trackAutomaticEvents,
                at: currentStateAt,
                emitAppOpen: !_continuingForeground,
              );
            }
            await _enqueuePendingFacts(token);
            _startCheckpoint(token);
          } else if (_reusedSession && _isMobilePlatform()) {
            if (_lifecycle.inactive) {
              await _mobileSession.pause(at: currentStateAt);
            } else {
              await _mobileSession.background(at: currentStateAt);
            }
            await _enqueuePendingFacts(token);
          }
        }
        core.startProcessingQueue(token);
      } catch (_) {
        _initialized = false;
        _stopCheckpoint();
        rethrow;
      }
    });
  }

  /// Chains this (new) instance's operations after [previousDisposal] and
  /// then takes over [previous]'s lifecycle state (RN `init` re-init path).
  void restoreAfter(
    Future<void> previousDisposal,
    OursPrivacyMain previous,
    OursPrivacyInitOptions options,
  ) {
    _pendingOperation =
        previousDisposal.then((_) => restoreLifecycle(previous, options));
  }

  /// Chains this (new) instance's operations after [previousDisposal]
  /// without taking over any state (re-initialization after `close`).
  void startAfter(Future<void> previousDisposal) {
    _pendingOperation = previousDisposal.then<void>(
      (_) {},
      onError: (Object _) {},
    );
  }

  void restoreLifecycle(
    OursPrivacyMain previous,
    OursPrivacyInitOptions options,
  ) {
    if (!_hasAppStateEvent && previous._hasAppStateEvent) {
      _latestAppState = previous._latestAppState;
      _hasAppStateEvent = true;
    }
    _continuingForeground = previous._lifecycle.foregrounded &&
        previous._trackAutomaticEvents &&
        previous._mobileSession.foregrounded &&
        !previous._mobileSession.disabled;
    if (previous.token == token &&
        identical(previous.persistent.storage, persistent.storage) &&
        previous._trackAutomaticEvents == options.trackAutomaticEvents &&
        !previous._mobileSession.disabled) {
      _mobileSession = previous._mobileSession;
      _reusedSession = true;
    }
  }

  /// Stops this instance: cancels uploads, detaches the lifecycle listener and
  /// stops the timers. Completes after every queued operation has run.
  Future<void> dispose() {
    _disposed = true;
    core.cancelPendingUploads(token);
    _initialized = false;
    if (_subscribed) {
      _lifecycleSource.dispose();
      _subscribed = false;
    }
    _stopCheckpoint();
    core.stopProcessingQueue();
    return _pendingOperation.then((_) {
      _stopCheckpoint();
      core.stopProcessingQueue();
    });
  }

  Future<T> _serialize<T>(FutureOr<T> Function() action) {
    final result = _pendingOperation.then((_) => action());
    _pendingOperation = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  /// Mobile = an iOS or Android app build (never a web build, even in a
  /// mobile browser). Read at call time through the injectable device info.
  bool _isMobilePlatform() => _deviceInfo.isMobilePlatform;

  MobileSession _createMobileSession(String token) {
    return MobileSession(
      token: token,
      storage: StrictMobileSessionStorage(persistent.storageAdapter),
      wallNow: _environment.wallNow ?? defaultWallNow,
      monotonicNow: _environment.monotonicNow ?? defaultMonotonicNow,
      getVisitorId: () => persistent.getVisitorId(token),
      getIsManuallySetId: () => config.getIsManuallySetId(token),
    );
  }

  void _startCheckpoint(String token, [int? retryDelayMs]) {
    if (_disposed ||
        _checkpointTimer != null ||
        !_trackAutomaticEvents ||
        !_lifecycle.foregrounded ||
        persistent.getOptedOut(token) ||
        !_isMobilePlatform()) {
      return;
    }
    final delayMs = retryDelayMs ?? _mobileSession.remainingCheckpointMs();
    if (delayMs == null) return;
    late final Timer timer;
    timer = _timerFactory(Duration(milliseconds: delayMs), () {
      var failed = false;
      unawaited(_serialize(() async {
        if (!identical(_checkpointTimer, timer) || !_lifecycle.foregrounded) {
          return;
        }
        await _mobileSession.checkpoint();
        await _enqueuePendingFacts(token);
      }).then<void>((_) {}, onError: (Object error) {
        failed = true;
        OursPrivacyLogger.error(token, '$error');
      }).whenComplete(() {
        if (!identical(_checkpointTimer, timer)) return;
        _checkpointTimer = null;
        _startCheckpoint(token, failed ? _checkpointIntervalMs : null);
      }));
    });
    _checkpointTimer = timer;
  }

  void _stopCheckpoint() {
    _checkpointTimer?.cancel();
    _checkpointTimer = null;
  }

  Future<void> _enqueuePendingFacts(String token) async {
    if (persistent.getOptedOut(token)) return;
    final pending = await _mobileSession.pendingQueueFacts();
    for (final record in pending) {
      final fact = normalizeMobileEvent(record.fact.toJson());
      final eventProperties = _spreadable(fact['eventProperties']);
      final defaultProperties = _spreadable(fact['defaultProperties']);
      final sid = defaultProperties['sid'];
      final occurredAt = eventProperties['mobile_occurred_at'];
      final appVersion = eventProperties['app_version'];
      final appBuild = eventProperties['app_build'];
      final queued = await _enqueueEvent(
        token,
        fact['event']! as String,
        fact['eventProperties'] is Map ? eventProperties : null,
        null,
        (
          sid: sid is String ? sid : null,
          mobileOccurredAt: occurredAt is String ? occurredAt : null,
        ),
        distinctId: record.id,
        visitorId: record.visitorId,
        includeEventDefaults: false,
        appMetadata: (
          appVersion:
              record.appVersion ?? (appVersion is String ? appVersion : null),
          appBuild: record.appBuild ?? (appBuild is String ? appBuild : null),
        ),
        isCanonicalFact: true,
        isManuallySetId: record.isManuallySetId,
      );
      if (!queued) {
        if (persistent.getOptedOut(token)) return;
        throw const OursPrivacyException('Mobile fact was not queued');
      }
      await _mobileSession.markFactQueued(record.id);
      await _mobileSession.acknowledgeFact(record.id);
    }
  }

  void _subscribeToAppState(String token) {
    if (_subscribed) return;
    _subscribed = true;
    _lifecycleSource.start((nextState) {
      _latestAppState = nextState;
      _hasAppStateEvent = true;
      final at = MobileTimePoint(
        wallMs: _mobileSession.wallNow(),
        monotonicMs: _mobileSession.monotonicNow(),
      );
      _latestAppStateAt = at;
      if (!_initialized) return;
      unawaited(_serialize(() async {
        // Drain receipts queued before disposal so background time stays out
        // of engagement.
        if (!_initialized && !_disposed) return;
        final transition = _lifecycle.handle(nextState);
        switch (transition) {
          case LifecycleTransition.pause:
            _stopCheckpoint();
            if (!persistent.getOptedOut(token) && _isMobilePlatform()) {
              await _mobileSession.pause(at: at);
              await _enqueuePendingFacts(token);
            }
          case LifecycleTransition.background:
            _stopCheckpoint();
            if (!persistent.getOptedOut(token) && _isMobilePlatform()) {
              await _mobileSession.background(at: at);
              await _enqueuePendingFacts(token);
            }
            if (_flushOnBackgroundEnabled) {
              unawaited(flush(token).then<void>(
                (_) {},
                onError: (Object error) =>
                    OursPrivacyLogger.error(token, '$error'),
              ));
            }
          case LifecycleTransition.foreground:
          case LifecycleTransition.foregroundFromResume:
            if (!persistent.getOptedOut(token) && _isMobilePlatform()) {
              final wasInactive =
                  transition == LifecycleTransition.foregroundFromResume;
              final resumed =
                  wasInactive && await _mobileSession.resume(at: at);
              if (!resumed) {
                await _mobileSession.foreground(
                  automaticEnabled: _trackAutomaticEvents,
                  at: at,
                );
              }
              await _enqueuePendingFacts(token);
              _startCheckpoint(token);
            }
          case null:
            break;
        }
      }).then<void>(
        (_) {},
        onError: (Object error) => OursPrivacyLogger.error(token, '$error'),
      ));
    });
  }

  // Ingest strips unknown defaults, so mobile metadata belongs in
  // eventProperties.
  Map<String, Object?> getDefaultProperties(
    String token,
    OursPrivacyEventSnapshot? mobileSnapshot, {
    bool includeAttribution = true,
  }) {
    final props = _deviceInfo.defaultProperties();

    final attribution = _attributionDefaultProperties[token];
    if (includeAttribution && attribution != null && attribution.isNotEmpty) {
      props.addAll(attribution);
    }

    final sid = mobileSnapshot?.sid;
    if (mobileSnapshot != null && sid != null && _isMobilePlatform()) {
      props['sid'] = sid;
    }

    return props;
  }

  Future<void> reset(String token) {
    return _serialize(() async {
      final resumeForeground = _lifecycle.foregrounded &&
          _initialized &&
          !persistent.getOptedOut(token) &&
          _isMobilePlatform();
      _stopCheckpoint();
      if (resumeForeground) {
        await _mobileSession.rotateSession();
        await _enqueuePendingFacts(token);
      } else {
        await _mobileSession.resetSession();
        await _enqueuePendingFacts(token);
      }
      await persistent.reset(token);
      config.setIsManuallySetId(token, false);
      _defaultEventProperties[token] = {};
      _defaultUserCustomProperties[token] = {};
      _defaultUserConsentProperties[token] = {};
      _attributionDefaultProperties[token] = {};
      if (resumeForeground) {
        await _mobileSession.announceRotatedSession();
        await _enqueuePendingFacts(token);
        _startCheckpoint(token);
      }
    });
  }

  Future<void> track(
    String token,
    String eventName, [
    Map<String, Object?>? properties,
    Map<String, Object?>? userProperties,
  ]) {
    if (eventName.startsWith(r'$mobile_')) {
      OursPrivacyLogger.warn(
        token,
        r'Event names starting with $mobile_ are reserved',
      );
      return Future<void>.value();
    }
    final atMs = _wallNow();
    return _serialize(
      () => _track(
        token,
        eventName,
        properties,
        userProperties,
        atMs: atMs,
      ),
    );
  }

  Future<void> trackScreen(String token, String screenName) {
    final at = MobileTimePoint(
      wallMs: _wallNow(),
      monotonicMs: _mobileSession.monotonicNow(),
    );
    return _serialize(() async {
      if (persistent.getOptedOut(token) || !_isMobilePlatform()) {
        return;
      }
      await _mobileSession.screen(screenName, at: at);
      await _enqueuePendingFacts(token);
    });
  }

  Future<void> _track(
    String token,
    String eventName,
    Map<String, Object?>? properties,
    Map<String, Object?>? userProperties, {
    bool includeEventDefaults = true,
    int? atMs,
  }) async {
    if (persistent.getOptedOut(token)) {
      OursPrivacyLogger.log(
        token,
        'User has opted out of tracking, skipping tracking.',
      );
      return;
    }

    if (_shouldLog(token)) {
      OursPrivacyLogger.log(
        token,
        "Track '$eventName' with properties "
        '${properties == null ? 'undefined' : jsonEncode(properties)}',
      );
    }

    final snapshot = _isMobilePlatform()
        ? await _mobileSession.snapshot(atMs ?? _wallNow())
        : null;
    if (snapshot != null) {
      await _mobileSession.drainPendingFacts();
      await _enqueuePendingFacts(token);
    }
    await _enqueueEvent(
      token,
      eventName,
      properties,
      userProperties,
      snapshot == null
          ? null
          : (sid: snapshot.sid, mobileOccurredAt: snapshot.mobileOccurredAt),
      includeEventDefaults: includeEventDefaults,
    );
  }

  Future<bool> _enqueueEvent(
    String token,
    String eventName,
    Map<String, Object?>? properties,
    Map<String, Object?>? userProperties,
    OursPrivacyEventSnapshot? snapshot, {
    String? distinctId,
    String? visitorId,
    bool includeEventDefaults = true,
    _AppMetadata? appMetadata,
    bool isCanonicalFact = false,
    bool? isManuallySetId,
  }) async {
    final rawEventProps = <String, Object?>{
      if (includeEventDefaults) ...?_defaultEventProperties[token],
      ...?properties,
    };
    var eventData = <String, Object?>{
      'event': eventName,
      'visitor_id': visitorId ?? persistent.getVisitorId(token),
      'distinct_id': distinctId ?? uuidv4(),
      'isManuallySetId': isManuallySetId ?? config.getIsManuallySetId(token),
      'eventProperties': rawEventProps.isNotEmpty ? rawEventProps : null,
      'userProperties': isCanonicalFact
          ? null
          : _composeUserProperties(token, userProperties),
      'defaultProperties': getDefaultProperties(
        token,
        snapshot,
        includeAttribution: !isCanonicalFact,
      ),
    };
    if (snapshot != null && _isMobilePlatform()) {
      eventData = normalizeMobileEvent(eventData, {
        'mobile_occurred_at': snapshot.mobileOccurredAt,
        'app_version': appMetadata != null
            ? appMetadata.appVersion
            : _mobileSession.appVersion,
        'app_build': appMetadata != null
            ? appMetadata.appBuild
            : _mobileSession.appBuild,
      });
      final eventProperties = eventData['eventProperties'];
      if (eventProperties is! Map ||
          eventProperties['mobile_contract_version'] == null) {
        OursPrivacyLogger.warn(
          token,
          'Mobile analytics metadata omitted to keep event properties within ingest limits.',
        );
      }
    }
    await _coreReady;
    return core.addToOursPrivacyQueue(token, eventsQueueType, eventData);
  }

  Map<String, Object?>? _composeUserProperties(
    String token,
    Map<String, Object?>? perCallUserProps,
  ) {
    final wirePerCall = toWireUserProperties(perCallUserProps);

    final defaultCustom = _defaultUserCustomProperties[token] ?? const {};
    final defaultConsent = _defaultUserConsentProperties[token] ?? const {};
    final hasDefaultCustom = defaultCustom.isNotEmpty;
    final hasDefaultConsent = defaultConsent.isNotEmpty;
    final hasPerCall = wirePerCall != null && wirePerCall.isNotEmpty;

    if (!hasDefaultCustom && !hasDefaultConsent && !hasPerCall) {
      return null;
    }

    final merged = <String, Object?>{...?wirePerCall};

    if (hasDefaultCustom || _truthy(wirePerCall?['custom_properties'])) {
      merged['custom_properties'] = <String, Object?>{
        ...defaultCustom,
        ..._spreadable(wirePerCall?['custom_properties']),
      };
    }

    final consent = <String, Object?>{
      ...defaultConsent,
      ..._spreadable(wirePerCall?['consent']),
    };
    if (consent.isNotEmpty) {
      merged['consent'] = consent;
    } else {
      merged.remove('consent');
    }

    if (merged.isEmpty) return null;

    return merged;
  }

  void setLoggingEnabled(String token, bool loggingEnabled) {
    config.setLoggingEnabled(token, loggingEnabled);
  }

  void setServerURL(String token, String serverURL) {
    config.setServerURL(token, serverURL);
  }

  void setFlushBatchSize(String token, int flushBatchSize) {
    config.setFlushBatchSize(token, flushBatchSize);
  }

  void setFlushOnBackground(String token, bool flushOnBackground) {
    _flushOnBackgroundEnabled = flushOnBackground;
    OursPrivacyLogger.log(
      token,
      'Set flushOnBackground: $_flushOnBackgroundEnabled',
    );
  }

  /// Uploads the queue after every earlier operation, without holding the
  /// operation chain for the network round trip.
  Future<void> flush(String token) async {
    final holder = await _serialize(() {
      final completion = _initialized ? core.flush(token) : null;
      // Observed here so an early failure is not reported as unhandled; the
      // caller still receives it below.
      if (completion != null) {
        unawaited(completion.then<void>((_) {}, onError: (Object _) {}));
      }
      return (completion: completion);
    });
    await holder.completion;
  }

  Future<void> optOutTracking(String token) {
    _consentRevision += 1;
    core.cancelPendingUploads(token);
    final persistOptOut = _setOptedOutTrackingFlag(token, true);
    unawaited(persistOptOut.then<void>((_) {}, onError: (Object _) {}));
    return _serialize(() async {
      await persistOptOut;
      await _setOptedOutTrackingFlag(token, true);
      _stopCheckpoint();
      await _mobileSession.disableTracking(
        firstOpenAccepted: core.queueManager.hasAcceptedFirstOpen(
          token,
          eventsQueueType,
        ),
      );
      await core.queueManager.clearQueue(token, eventsQueueType);
      OursPrivacyLogger.log(token, 'User has opted out of tracking');
      await persistent.reset(token, preserveVisitorId: true);
      _defaultEventProperties[token] = {};
      _defaultUserCustomProperties[token] = {};
      _defaultUserConsentProperties[token] = {};
      _attributionDefaultProperties[token] = {};
    });
  }

  Future<void> optInTracking(String token) {
    final revision = ++_consentRevision;
    return _serialize(() async {
      if (revision != _consentRevision) return;
      await _setOptedOutTrackingFlag(token, false);
      _mobileSession = _createMobileSession(token);
      _mobileSession.appVersion = _appVersion;
      _mobileSession.appBuild = _appBuild;
      await _mobileSession.load();
      if (_lifecycle.foregrounded && _isMobilePlatform()) {
        await _mobileSession.foreground(
          automaticEnabled: _trackAutomaticEvents,
        );
        await _enqueuePendingFacts(token);
        _startCheckpoint(token);
      }
      core.startProcessingQueue(token);
      OursPrivacyLogger.log(token, 'User has opted in to tracking');
      await _track(token, r'$opt_in', null, null);
    });
  }

  Future<void> _setOptedOutTrackingFlag(
    String token,
    bool optedOut, {
    bool explicitDecision = true,
  }) async {
    final consentRevision = _consentRevision;
    final previous = persistent.getOptedOut(token);
    final revision = persistent.updateOptedOut(token, optedOut);
    try {
      await persistent.persistOptedOut(
        token,
        explicitDecision: explicitDecision,
      );
    } catch (_) {
      if (!optedOut) {
        persistent.updateOptedOut(token, previous, revision);
      }
      if (explicitDecision &&
          consentRevision == _consentRevision &&
          persistent.getOptedOut(token)) {
        try {
          await persistent.persistOptedOut(token, explicitDecision: true);
        } catch (_) {
          OursPrivacyLogger.error(
            token,
            'Unable to persist closed tracking decision',
          );
        }
      }
      rethrow;
    }
  }

  bool hasOptedOutTracking(String token) => persistent.getOptedOut(token);

  // identify(userProperties) — caller supplies identifying fields inside the
  // userProperties bag (most commonly externalId). Merging with store-level
  // default custom/consent properties is identical to track() — see
  // _composeUserProperties for the consent guard.
  Future<void> identify(String token, Map<String, Object?>? userProperties) {
    final atMs = _wallNow();
    return _serialize(
      () => _track(
        token,
        r'$identify',
        null,
        userProperties,
        includeEventDefaults: false,
        atMs: atMs,
      ),
    );
  }

  String? getVisitorId(String token) => persistent.getVisitorId(token);

  Future<void> setVisitorId(String token, String visitorId) {
    return _serialize(() => _setVisitorId(token, visitorId));
  }

  Future<void> _setVisitorId(String token, String visitorId) async {
    final previous = persistent.getVisitorId(token);
    final resumeForeground = previous != visitorId &&
        _initialized &&
        _lifecycle.foregrounded &&
        !persistent.getOptedOut(token) &&
        _isMobilePlatform();
    if (previous != visitorId) {
      _stopCheckpoint();
      if (resumeForeground) {
        await _mobileSession.rotateSession();
        await _enqueuePendingFacts(token);
      } else {
        await _mobileSession.resetSession();
        await _enqueuePendingFacts(token);
      }
    }
    config.setIsManuallySetId(token, true);
    persistent.updateVisitorId(token, visitorId);
    await persistent.persistVisitorId(token);
    if (resumeForeground) {
      await _mobileSession.announceRotatedSession();
      await _enqueuePendingFacts(token);
      _startCheckpoint(token);
    }
  }

  Future<void> trackDeepLink(String token, String url) {
    final atMs = _wallNow();
    return _serialize(() => _trackDeepLink(token, url, atMs));
  }

  Future<void> _trackDeepLink(String token, String? url, [int? atMs]) async {
    if (url == null || url.isEmpty) {
      OursPrivacyLogger.log(
        token,
        'trackDeepLink called with invalid URL, skipping.',
      );
      return;
    }

    if (persistent.getOptedOut(token)) {
      OursPrivacyLogger.log(token, 'trackDeepLink skipped: user is opted out.');
      return;
    }

    OursPrivacyLogger.log(token, 'trackDeepLink processed');

    final attribution = parseAttributionFromURL(url);

    _attributionDefaultProperties[token] = <String, Object?>{
      ...?attribution.utmParams,
      ...?attribution.clickIds,
    };

    final oursVisitorId = attribution.oursVisitorId;
    if (oursVisitorId != null) {
      await _setVisitorId(token, oursVisitorId);
    }

    await _track(
      token,
      r'$deep_link_opened',
      null,
      null,
      includeEventDefaults: false,
      atMs: atMs ?? _wallNow(),
    );
  }

  void updateDefaultEventProperties(
    String token,
    Map<String, Object?> properties,
  ) {
    _defaultEventProperties[token] = <String, Object?>{
      ...?_defaultEventProperties[token],
      ...properties,
    };
  }

  void updateDefaultUserCustomProperties(
    String token,
    Map<String, Object?> properties,
  ) {
    _defaultUserCustomProperties[token] = <String, Object?>{
      ...?_defaultUserCustomProperties[token],
      ...properties,
    };
  }

  void updateDefaultUserConsentProperties(
    String token,
    Map<String, Object?> properties,
  ) {
    _defaultUserConsentProperties[token] = <String, Object?>{
      ...?_defaultUserConsentProperties[token],
      ...properties,
    };
  }

  Future<void> _applyInitializationOptions(
    String token,
    OursPrivacyInitOptions options,
  ) async {
    final defaultEventProperties = options.defaultEventProperties;
    if (defaultEventProperties != null) {
      updateDefaultEventProperties(token, defaultEventProperties);
    }
    final defaultUserCustomProperties = options.defaultUserCustomProperties;
    if (defaultUserCustomProperties != null) {
      updateDefaultUserCustomProperties(token, defaultUserCustomProperties);
    }
    final defaultUserConsentProperties = options.defaultUserConsentProperties;
    if (defaultUserConsentProperties != null) {
      updateDefaultUserConsentProperties(token, defaultUserConsentProperties);
    }
    final visitorId = options.visitorId;
    if (visitorId != null && visitorId.isNotEmpty) {
      await _setVisitorId(token, visitorId);
    }
    final initialURL = options.initialURL;
    if (initialURL != null && initialURL.isNotEmpty) {
      await _trackDeepLink(token, initialURL);
    }
  }
}
