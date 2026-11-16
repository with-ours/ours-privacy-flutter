// Port of javascript/oursprivacy-mobile-payload.js (React Native SDK).
//
// Mobile analytics metadata (`mobile_contract_version`, `mobile_occurred_at`,
// `app_version`, `app_build`) belongs in eventProperties because ingest
// strips unknown defaultProperties keys. `sid` stays in defaultProperties.
import 'dart:convert';

import 'utils.dart';

/// Maximum number of keys in a mobile event's eventProperties bag.
const int mobileMaxEventPropertyCount = 200;

/// eventProperties must serialize to fewer than this many UTF-16 code units.
const int mobileMaxEventPropertyBytes = 1048576;

final RegExp _sessionIdPattern = RegExp(r'^[1-9]\d{12}$');
final RegExp _isoMillisecondsPattern =
    RegExp(r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$');

/// A mobile session ID is the session start as a 13-digit epoch-millisecond
/// string.
bool isSessionId(Object? value) =>
    value is String && _sessionIdPattern.hasMatch(value);

/// Epoch milliseconds for a canonical `YYYY-MM-DDTHH:mm:ss.sssZ` string, or
/// null when the value is not exactly what `isoFromMilliseconds` would produce
/// (for example `2026-02-30T12:00:00.000Z`).
int? isoMilliseconds(Object? value) {
  if (value is! String || !_isoMillisecondsPattern.hasMatch(value)) {
    return null;
  }
  final parsed = DateTime.tryParse(value);
  if (parsed == null) return null;
  final milliseconds = parsed.millisecondsSinceEpoch;
  return isoFromMilliseconds(milliseconds) == value ? milliseconds : null;
}

const List<String> _metadataFields = [
  'mobile_contract_version',
  'mobile_occurred_at',
  'app_version',
  'app_build',
];

const List<String> _legacyMarkers = [
  'mobile_session_started_at',
  'mobile_platform',
];

Map<String, Object?> _mapOrEmpty(Object? value) {
  if (value is Map<String, Object?>) return value;
  if (value is Map) {
    return {
      for (final entry in value.entries)
        if (entry.key is String) entry.key as String: entry.value,
    };
  }
  return const {};
}

/// SDK-owned metadata for [normalizeMobilePayload]: `mobile_occurred_at`,
/// `app_version` and `app_build`. A null value means "not provided".
typedef MobileMetadata = Map<String, Object?>;

/// Normalizes a queued or new event to the current mobile wire contract.
///
/// Events that carry no mobile marker (and no [metadata]) are returned
/// unchanged. Otherwise:
/// - `sid` must be a 13-digit session ID; a legacy `mobile_session_started_at`
///   is converted to one when possible, and any other `sid` is dropped.
/// - legacy `mobile_session_started_at` / `mobile_platform` are removed.
/// - metadata is moved into eventProperties with `mobile_contract_version: 1`
///   unless that would push the bag past 200 keys or 1 MiB, in which case
///   eventProperties keeps the caller's own keys only.
///
/// [payload] is not modified; a new map is returned when normalization runs.
/// Non-map payloads are returned unchanged.
Object? normalizeMobilePayload(Object? payload, [MobileMetadata? metadata]) {
  if (payload is! Map) return payload;
  final event = _mapOrEmpty(payload);
  final defaults = _mapOrEmpty(event['defaultProperties']);
  final properties = _mapOrEmpty(event['eventProperties']);
  final eventName = event['event'];
  if (metadata == null &&
      !(eventName is String && eventName.startsWith(r'$mobile_')) &&
      !const [
        'mobile_platform',
        'mobile_contract_version',
        'mobile_session_started_at',
        'mobile_occurred_at',
      ].any((key) => defaults[key] != null || properties[key] != null)) {
    return payload;
  }

  final legacyMetadata = defaults['mobile_contract_version'] != null ||
      _legacyMarkers
          .any((key) => defaults[key] != null || properties[key] != null);
  final sdkMetadata = metadata ?? (legacyMetadata ? defaults : null);
  final defaultProperties = Map<String, Object?>.of(defaults);
  final eventProperties = Map<String, Object?>.of(properties);
  final startMs = isoMilliseconds(defaults['mobile_session_started_at']);
  if (!isSessionId(defaults['sid'])) {
    if (startMs != null && isSessionId(startMs.toString())) {
      defaultProperties['sid'] = startMs.toString();
    } else {
      defaultProperties.remove('sid');
    }
  }
  for (final key in _legacyMarkers) {
    defaultProperties.remove(key);
    eventProperties.remove(key);
  }
  final commonMetadata = <String, Object?>{};
  for (final key in _metadataFields) {
    defaultProperties.remove(key);
    eventProperties.remove(key);
    final Object? value;
    if (sdkMetadata != null) {
      value = sdkMetadata[key] ??
          (metadata != null && (key == 'app_version' || key == 'app_build')
              ? (properties[key] ?? defaults[key])
              : null);
    } else {
      value = defaults[key] ?? properties[key];
    }
    if (value != null) commonMetadata[key] = value;
  }
  commonMetadata['mobile_contract_version'] = 1;
  final mergedProperties = <String, Object?>{
    ...eventProperties,
    ...commonMetadata,
  };
  return <String, Object?>{
    ...event,
    'defaultProperties': defaultProperties,
    'eventProperties': _fitsIngestLimits(mergedProperties)
        ? mergedProperties
        : eventProperties,
  };
}

bool _fitsIngestLimits(Map<String, Object?> properties) {
  if (properties.length > mobileMaxEventPropertyCount) return false;
  try {
    return jsonEncode(properties).length < mobileMaxEventPropertyBytes;
  } catch (_) {
    return false;
  }
}

/// Typed convenience over [normalizeMobilePayload] for map payloads.
Map<String, Object?> normalizeMobileEvent(
  Map<String, Object?> payload, [
  MobileMetadata? metadata,
]) =>
    normalizeMobilePayload(payload, metadata)! as Map<String, Object?>;
