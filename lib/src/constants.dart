// Port of javascript/oursprivacy-constants.js (React Native SDK).
// Storage key strings are byte-identical to the React Native SDK.

/// Ingest endpoint path appended to the server URL.
const String eventsEndpoint = '/ingest';

/// Queue type used in storage keys, mirroring `OursPrivacyType.EVENTS`.
const String eventsQueueType = eventsEndpoint;

String queueKey(String token, String type) =>
    'OURSPRIVACY_${token}_${type}_QUEUE';

String queueMetadataKey(String token, String type) =>
    '${queueKey(token, type)}_METADATA_V1';

// Storage key string kept as-is for compatibility with the other SDKs.
String visitorIdKey(String token) => 'OURSPRIVACY_${token}_DEVICE_ID';

/// Visitor IDs that are authoritative (`is_manually_set_id: true`), stored
/// as `{"visitorIds": [...]}`. Same key and shape as React Native.
String isManuallySetIdKey(String token) =>
    'OURSPRIVACY_${token}_IS_MANUALLY_SET_ID';

String optOutKey(String token) => 'OURSPRIVACY_${token}_OPT_OUT';

String optOutDecisionKey(String token) =>
    'OURSPRIVACY_${token}_OPT_OUT_DECISION_V1';

String optOutDefaultKey(String token) =>
    'OURSPRIVACY_${token}_OPT_OUT_DEFAULT_V1';

String mobileInstallKey(String token) =>
    'OURSPRIVACY_${token}_MOBILE_INSTALL_V1';

String mobileSessionKey(String token) =>
    'OURSPRIVACY_${token}_MOBILE_SESSION_V1';

const String defaultServerURL = 'https://cdn.oursprivacy.com';

/// Maximum events per request; `setFlushBatchSize` clamps to 1..50.
const int defaultBatchSize = 50;
const int maxBatchSize = 50;

const Duration defaultFlushInterval = Duration(seconds: 10);
const Duration checkpointInterval = Duration(seconds: 10);
