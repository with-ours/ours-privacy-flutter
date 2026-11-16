/// Ours Privacy analytics SDK for Flutter apps on iOS and Android.
///
/// ```dart
/// final op = OursPrivacy();
/// await op.init('YOUR_API_TOKEN', trackAutomaticEvents: true);
/// op.track('event_name');
/// ```
library;

import 'package:http/http.dart' as http;

import 'src/config.dart';
import 'src/logger.dart';
import 'src/oursprivacy_main.dart';
import 'src/storage.dart';

export 'src/config.dart' show OursPrivacyIngestRejection;
export 'src/errors.dart' show OursPrivacyException;
export 'src/storage.dart' show InMemoryStorage, OursPrivacyStorage;

const String _invalidObject = ' is not a valid json object';
const String _invalidString = ' is not a valid string';

const String _notInitializedError =
    'OursPrivacy.init(token, options) must be called before any other method.';

const String _invalidScreenLabelWarning =
    'trackScreen ignored an invalid screen label. Use 1-80 ASCII characters '
    'starting with a letter, containing only letters, digits, spaces, '
    'underscores, or hyphens, with no trailing whitespace.';

final RegExp _blankString = RegExp(r'^\s*$');
final RegExp _screenLabel = RegExp(r'^[A-Za-z][A-Za-z0-9 _-]{0,79}$');

/// The primary class for integrating Ours Privacy with your app.
///
/// Usage:
/// ```dart
/// final ours = OursPrivacy();
/// await ours.init('YOUR_API_TOKEN', trackAutomaticEvents: true);
/// ours.track('event_name');
/// ```
///
/// Methods other than [init] and [close] throw a [StateError] until [init]
/// has been called, and again after [close]. Invalid arguments throw
/// synchronously (an [ArgumentError]). Returned futures complete with an
/// [OursPrivacyException] when storage fails or persisted SDK state cannot
/// be read.
class OursPrivacy {
  /// Creates an uninitialized instance. Does not touch the Flutter binding,
  /// so it is safe to create before `runApp` (for example as a top-level
  /// `final`).
  OursPrivacy();

  String? _token;
  OursPrivacyMain? _impl;

  /// Completes when the instance stopped by the latest [close] has finished
  /// its queued work; the next [init] waits for it.
  Future<void>? _closing;

  /// Initialize Ours Privacy.
  ///
  /// - [token]: your Ours Privacy project token.
  /// - [trackAutomaticEvents]: enable mobile lifecycle events (first open,
  ///   app open, sessions, engagement, app update). Default false.
  /// - [appVersion], [appBuild]: host app release metadata.
  /// - [onIngestRejected]: receives `{distinctId, code}` after a mobile
  ///   ingest rejection.
  /// - [optOutTrackingByDefault]: start in an opted-out state until the
  ///   visitor makes a choice. Default false.
  /// - [serverURL]: override the ingest endpoint.
  /// - [visitorId]: pre-set the visitor ID (sets `is_manually_set_id: true`
  ///   on events tracked in this launch).
  /// - [initialURL]: deep link URL to parse on init.
  /// - [defaultEventProperties]: merged into every [track] call.
  /// - [defaultUserCustomProperties]: merged into
  ///   `userProperties.customProperties`.
  /// - [defaultUserConsentProperties]: merged into `userProperties.consent`.
  /// - [storage]: override the default storage backend
  ///   (`shared_preferences`).
  /// - [httpClient]: HTTP client for uploads (advanced and testing). The SDK
  ///   never closes it.
  ///
  /// Calling [init] again replaces the previous configuration; a session in
  /// progress continues when the token, storage and
  /// [trackAutomaticEvents] are unchanged. Calling [init] after [close]
  /// starts the instance again.
  ///
  /// The returned future completes with an [OursPrivacyException] when
  /// storage fails or persisted SDK state cannot be read.
  Future<void> init(
    String token, {
    bool trackAutomaticEvents = false,
    String? appVersion,
    String? appBuild,
    void Function(OursPrivacyIngestRejection rejection)? onIngestRejected,
    bool optOutTrackingByDefault = false,
    String? serverURL,
    String? visitorId,
    String? initialURL,
    Map<String, Object?>? defaultEventProperties,
    Map<String, Object?>? defaultUserCustomProperties,
    Map<String, Object?>? defaultUserConsentProperties,
    OursPrivacyStorage? storage,
    http.Client? httpClient,
  }) {
    if (!_isValidString(token)) _raiseStringError('token');
    final options = OursPrivacyInitOptions(
      trackAutomaticEvents: trackAutomaticEvents,
      appVersion: appVersion,
      appBuild: appBuild,
      onIngestRejected: onIngestRejected,
      optOutTrackingByDefault: optOutTrackingByDefault,
      serverURL: serverURL,
      visitorId: visitorId,
      initialURL: initialURL,
      defaultEventProperties:
          _jsonObjectOrNull(defaultEventProperties, 'defaultEventProperties'),
      defaultUserCustomProperties: _jsonObjectOrNull(
          defaultUserCustomProperties, 'defaultUserCustomProperties'),
      defaultUserConsentProperties: _jsonObjectOrNull(
          defaultUserConsentProperties, 'defaultUserConsentProperties'),
      storage: storage,
      httpClient: httpClient,
    );
    final previousImpl = _impl;
    final previous = previousImpl?.dispose();
    _token = token;
    final next = OursPrivacyMain(
      token,
      storage: storage,
      httpClient: httpClient,
      environment: oursPrivacyEnvironments[this] ??
          oursPrivacyDefaultEnvironment ??
          const OursPrivacyEnvironment(),
    );
    _impl = next;
    oursPrivacyImpls[this] = next;
    final closing = _closing;
    _closing = null;
    if (previousImpl != null && previous != null) {
      next.restoreAfter(previous, previousImpl, options);
    } else if (closing != null) {
      next.startAfter(closing);
    }
    return next.initialize(token, options);
  }

  /// Stops this instance: cancels its timers and in-flight uploads and
  /// detaches its app lifecycle listener. Completes after work already
  /// queued on the instance has finished. Events still in the queue stay in
  /// storage and are sent after the next [init].
  ///
  /// Afterwards every method other than [init] and [close] throws a
  /// [StateError] until [init] is called again. Calling [close] before
  /// [init], or more than once, does nothing.
  ///
  /// Apps normally never call this; use it in tests (in `tearDown`) or when
  /// discarding an instance.
  Future<void> close() {
    final impl = _impl;
    if (impl == null) return _closing ?? Future<void>.value();
    _impl = null;
    _token = null;
    oursPrivacyImpls[this] = null;
    final closing = impl.dispose();
    _closing = closing;
    return closing;
  }

  /// Set the base URL used for Ours Privacy API requests.
  /// Defaults to https://cdn.oursprivacy.com.
  /// To route data to Ours Privacy's EU servers, set to
  /// https://api-eu.oursprivacy.com.
  void setServerURL(String serverURL) {
    _requireInit().setServerURL(_token!, serverURL);
  }

  /// Enable or disable debug logging at run time. Disabled by default.
  void setLoggingEnabled(bool loggingEnabled) {
    _requireInit().setLoggingEnabled(_token!, loggingEnabled);
  }

  /// Enable or disable flushing the event queue when the app moves to the
  /// background. Enabled by default. The flush is best effort: the operating
  /// system may suspend the app before it finishes.
  void setFlushOnBackground(bool flushOnBackground) {
    _requireInit().setFlushOnBackground(_token!, flushOnBackground);
  }

  /// Set the maximum number of events sent in a single network request.
  /// Values are clamped to 1..50.
  void setFlushBatchSize(int flushBatchSize) {
    _requireInit().setFlushBatchSize(_token!, flushBatchSize);
  }

  /// Returns true if the visitor has opted out from tracking (also true while
  /// the stored decision is unknown).
  bool hasOptedOutTracking() => _requireInit().hasOptedOutTracking(_token!);

  /// Resume tracking after [optOutTracking]. Also sends a `$opt_in` event.
  Future<void> optInTracking() => _requireInit().optInTracking(_token!);

  /// Stop all tracking immediately. Queued events that have not been flushed
  /// are discarded. Await [flush] before opting out to send queued events
  /// first.
  Future<void> optOutTracking() => _requireInit().optOutTracking(_token!);

  /// Link this anonymous visitor to a known user identity. Call this after
  /// login. Sends a `$identify` event with the provided user properties.
  ///
  /// Callers pass identifying fields inside [userProperties] — most commonly
  /// `externalId` (your system's user ID). Supported keys: `email`,
  /// `externalId`, `phoneNumber`, `firstName`, `lastName`, `gender`,
  /// `dateOfBirth`, `city`, `state`, `zip`, `country`, `companyName`,
  /// `jobTitle`, `ip`, `customProperties` (map) and `consent` (map). The SDK
  /// merges in any default customProperties / consent registered via
  /// `updateDefault*()`.
  Future<void> identify([Map<String, Object?>? userProperties]) {
    final impl = _requireInit();
    final user = _jsonObjectOrNull(userProperties, 'userProperties');
    return impl.identify(_token!, user);
  }

  /// Track an event.
  ///
  /// Event names starting with `$mobile_` are reserved: the call logs a
  /// warning and does nothing. Property values must be JSON values (String,
  /// num, bool, null, List, or Map with String keys).
  Future<void> track(
    String eventName, [
    Map<String, Object?>? eventProperties,
    Map<String, Object?>? userProperties,
  ]) {
    final impl = _requireInit();
    if (!_isValidString(eventName)) _raiseStringError('eventName');
    if (eventName.startsWith(r'$mobile_')) {
      OursPrivacyLogger.warn(
        _token,
        r'Event names starting with $mobile_ are reserved',
      );
      return Future<void>.value();
    }
    final properties = _jsonObjectOrNull(eventProperties, 'properties');
    final user = _jsonObjectOrNull(userProperties, 'userProperties');
    return _observeOperation(
      impl.track(_token!, eventName, properties, user),
    );
  }

  /// Record a screen view (`$mobile_screen_view`) on iOS and Android.
  ///
  /// [screenName] must be 1-80 ASCII characters starting with a letter and
  /// containing only letters, digits, spaces, underscores or hyphens, with
  /// no trailing whitespace. An invalid label is ignored with a warning; it
  /// never throws.
  Future<void> trackScreen(String screenName) {
    final impl = _requireInit();
    if (screenName.trim() != screenName || !_screenLabel.hasMatch(screenName)) {
      OursPrivacyLogger.warn(_token, _invalidScreenLabelWarning);
      return Future<void>.value();
    }
    return _observeOperation(impl.trackScreen(_token!, screenName));
  }

  /// Clear stored identity and all default properties. Generates a new
  /// visitor ID. Call this when a visitor logs out.
  Future<void> reset() {
    final impl = _requireInit();
    return _observeOperation(impl.reset(_token!));
  }

  /// Returns the stable visitor UUID for this install, or null before it has
  /// loaded. Synchronous.
  String? getVisitorId() => _requireInit().getVisitorId(_token!);

  /// Merge properties into eventProperties on every subsequent [track] call.
  void updateDefaultEventProperties(Map<String, Object?> properties) {
    final impl = _requireInit();
    impl.updateDefaultEventProperties(
      _token!,
      _jsonObject(properties, 'properties'),
    );
  }

  /// Merge properties into userProperties.customProperties on every event.
  void updateDefaultUserCustomProperties(Map<String, Object?> properties) {
    final impl = _requireInit();
    impl.updateDefaultUserCustomProperties(
      _token!,
      _jsonObject(properties, 'properties'),
    );
  }

  /// Merge consent flags into userProperties.consent on every event.
  void updateDefaultUserConsentProperties(Map<String, Object?> properties) {
    final impl = _requireInit();
    impl.updateDefaultUserConsentProperties(
      _token!,
      _jsonObject(properties, 'properties'),
    );
  }

  /// Parse a deep link URL for marketing attribution data and fire a
  /// `$deep_link_opened` event. Extracts UTM parameters, ad network click IDs
  /// (gclid, fbclid, ttclid, aleid, etc.), and ours_visitor_id for
  /// cross-platform identity stitching. The URL itself is never sent.
  Future<void> trackDeepLink(String url) {
    final impl = _requireInit();
    if (!_isValidString(url)) _raiseStringError('url');
    return impl.trackDeepLink(_token!, url);
  }

  /// Update the visitor ID after initialization. Use this for web-to-app
  /// identity stitching when the visitor ID arrives outside of a deep link.
  /// Sets `is_manually_set_id: true` on events tracked until the app
  /// restarts; the visitor ID itself persists.
  Future<void> setVisitorId(String visitorId) {
    final impl = _requireInit();
    if (!_isValidString(visitorId)) _raiseStringError('visitorId');
    return impl.setVisitorId(_token!, visitorId);
  }

  /// Flush queued events to the Ours Privacy ingest endpoint immediately.
  Future<void> flush() => _requireInit().flush(_token!);

  /// Logs a failure of [completion] instead of letting it escape: the
  /// returned future always completes normally, so an un-awaited call never
  /// reaches the zone's uncaught-error handler.
  Future<void> _observeOperation(Future<void> completion) {
    final token = _token;
    return completion.then<void>(
      (_) {},
      onError: (Object error) => OursPrivacyLogger.error(token, '$error'),
    );
  }

  OursPrivacyMain _requireInit() {
    final impl = _impl;
    if (impl == null) throw StateError(_notInitializedError);
    return impl;
  }
}

bool _isValidString(String value) => !_blankString.hasMatch(value);

Never _raiseStringError(String paramName) =>
    throw ArgumentError('$paramName$_invalidString');

Map<String, Object?>? _jsonObjectOrNull(
  Map<String, Object?>? value,
  String paramName,
) =>
    value == null ? null : _jsonObject(value, paramName);

/// Validates that [value] is a JSON object and returns a deep copy, so later
/// changes to the caller's map do not affect queued events. Non-finite
/// numbers become null, as `JSON.stringify` does in the React Native SDK.
Map<String, Object?> _jsonObject(
  Map<String, Object?> value,
  String paramName,
) {
  final copy = _jsonCopy(value, Set<Object>.identity());
  if (copy is! Map<String, Object?>) {
    throw ArgumentError('$paramName$_invalidObject');
  }
  return copy;
}

/// Sentinel for a value that cannot be encoded as JSON.
const Object _invalid = Object();

Object? _jsonCopy(Object? value, Set<Object> visiting) {
  if (value == null || value is String || value is bool || value is int) {
    return value;
  }
  if (value is double) return value.isFinite ? value : null;
  if (value is Map) {
    if (!visiting.add(value)) return _invalid;
    final copy = <String, Object?>{};
    for (final entry in value.entries) {
      final key = entry.key;
      if (key is! String) return _invalid;
      final item = _jsonCopy(entry.value, visiting);
      if (identical(item, _invalid)) return _invalid;
      copy[key] = item;
    }
    visiting.remove(value);
    return copy;
  }
  if (value is List) {
    if (!visiting.add(value)) return _invalid;
    final copy = <Object?>[];
    for (final element in value) {
      final item = _jsonCopy(element, visiting);
      if (identical(item, _invalid)) return _invalid;
      copy.add(item);
    }
    visiting.remove(value);
    return copy;
  }
  return _invalid;
}
