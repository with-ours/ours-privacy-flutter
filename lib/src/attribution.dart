// Port of javascript/oursprivacy-attribution.js (React Native SDK).
//
// Deep link / URL attribution parser.
//
// Extracts marketing attribution data (UTM params, click IDs, visitor ID)
// from a URL string. Field lists are sourced from schema.dart, which mirrors
// the server's Zod schema to ensure the SDK and server stay in sync.
//
// Parsed fields go into **defaultProperties** (not eventProperties) because
// the server schema has dedicated typed columns for them. Unknown keys in
// defaultProperties are silently stripped by the server's Zod parse.
import 'schema.dart';

export 'schema.dart' show clickIds, utmParams;

/// Query parameter carrying the Ours Privacy cross-platform visitor ID.
const String oursVisitorIdParam = 'ours_visitor_id';

/// Result of [parseAttributionFromURL].
class OursPrivacyAttribution {
  const OursPrivacyAttribution({
    required this.utmParams,
    required this.clickIds,
    required this.oursVisitorId,
    required this.rawURL,
  });

  /// UTM parameters present with a non-empty value, or null when none.
  final Map<String, String>? utmParams;

  /// Ad network click IDs present with a non-empty value, or null when none.
  final Map<String, String>? clickIds;

  /// Non-empty `ours_visitor_id`, or null.
  final String? oursVisitorId;

  /// The URL that was parsed, or '' for null input.
  final String rawURL;

  /// UTM params and click IDs merged, for defaultProperties.
  Map<String, String> get defaultProperties => {
        ...?utmParams,
        ...?clickIds,
      };

  @override
  String toString() => 'OursPrivacyAttribution(utmParams: $utmParams, '
      'clickIds: $clickIds, oursVisitorId: $oursVisitorId, rawURL: $rawURL)';
}

/// Parse query parameters from a URL string.
/// Uses simple string splitting instead of [Uri.parse], which rejects many
/// custom-scheme deep links and would make parsing differ from the other SDKs.
Map<String, String> parseQueryParams(String? url) {
  if (url == null || url.isEmpty) return {};
  final queryStart = url.indexOf('?');
  if (queryStart == -1) return {};
  final queryString = url.substring(queryStart + 1);
  // Strip any fragment
  final fragmentStart = queryString.indexOf('#');
  final cleanQuery = fragmentStart == -1
      ? queryString
      : queryString.substring(0, fragmentStart);

  final params = <String, String>{};
  for (final pair in cleanQuery.split('&')) {
    final eqIndex = pair.indexOf('=');
    if (eqIndex == -1) continue;
    final key = pair.substring(0, eqIndex);
    final value = pair.substring(eqIndex + 1);
    try {
      params[key] = Uri.decodeComponent(value.replaceAll('+', ' '));
    } catch (_) {
      // Malformed percent-encoding: keep the raw value, like JavaScript's
      // decodeURIComponent fallback in the React Native SDK.
      params[key] = value;
    }
  }
  return params;
}

/// Extract a subset of params from parsed query params.
/// Returns a map with only the keys that are present and non-empty, or null if
/// none found.
Map<String, String>? _extractParams(
  Map<String, String> queryParams,
  List<String> keys,
) {
  final result = <String, String>{};
  for (final key in keys) {
    final value = queryParams[key];
    if (value != null && value.isNotEmpty) result[key] = value;
  }
  return result.isEmpty ? null : result;
}

/// Parse marketing attribution data from a URL.
///
/// Extracts UTM parameters, ad network click IDs (Google, Meta, TikTok,
/// AppLovin, etc.), and the Ours Privacy cross-platform visitor ID.
///
/// All returned fields (utmParams + clickIds) are valid keys in the server's
/// defaultPayload schema and should be placed in defaultProperties.
OursPrivacyAttribution parseAttributionFromURL(String? url) {
  final queryParams = parseQueryParams(url);
  final visitorId = queryParams[oursVisitorIdParam];
  return OursPrivacyAttribution(
    utmParams: _extractParams(queryParams, utmParams),
    clickIds: _extractParams(queryParams, clickIds),
    oursVisitorId: visitorId == null || visitorId.isEmpty ? null : visitorId,
    rawURL: url ?? '',
  );
}
