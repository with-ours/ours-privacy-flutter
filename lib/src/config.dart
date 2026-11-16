// Port of javascript/oursprivacy-config.js. Process-wide, keyed by token.
import 'constants.dart';

/// Payload delivered to `onIngestRejected` after a durable mobile ingest
/// rejection.
class OursPrivacyIngestRejection {
  const OursPrivacyIngestRejection(
      {required this.distinctId, required this.code});

  final String distinctId;
  final String code;

  @override
  String toString() =>
      'OursPrivacyIngestRejection(distinctId: $distinctId, code: $code)';
}

typedef OursPrivacyIngestRejectedCallback = void Function(
    OursPrivacyIngestRejection rejection);

class _TokenConfig {
  bool loggingEnabled = false;
  String? serverURL;
  int? batchSize;
  Duration? flushInterval;
  bool isManuallySetId = false;
  OursPrivacyIngestRejectedCallback? onIngestRejected;
}

class OursPrivacyConfig {
  OursPrivacyConfig._();

  static final OursPrivacyConfig instance = OursPrivacyConfig._();

  final Map<String, _TokenConfig> _config = {};

  _TokenConfig _for(String token) =>
      _config.putIfAbsent(token, _TokenConfig.new);

  bool getLoggingEnabled(String token) =>
      _config[token]?.loggingEnabled ?? false;
  void setLoggingEnabled(String token, bool enabled) =>
      _for(token).loggingEnabled = enabled;

  String getServerURL(String token) =>
      _config[token]?.serverURL ?? defaultServerURL;
  void setServerURL(String token, String serverURL) =>
      _for(token).serverURL = serverURL;

  int getFlushBatchSize(String token) =>
      _config[token]?.batchSize ?? defaultBatchSize;

  /// Clamps to 1..[maxBatchSize] (iOS behavior; React Native documents it).
  void setFlushBatchSize(String token, int batchSize) =>
      _for(token).batchSize = batchSize.clamp(1, maxBatchSize);

  Duration getFlushInterval(String token) =>
      _config[token]?.flushInterval ?? defaultFlushInterval;
  void setFlushInterval(String token, Duration interval) =>
      _for(token).flushInterval = interval;

  bool getIsManuallySetId(String token) =>
      _config[token]?.isManuallySetId ?? false;
  void setIsManuallySetId(String token, bool value) =>
      _for(token).isManuallySetId = value;

  OursPrivacyIngestRejectedCallback? getOnIngestRejected(String token) =>
      _config[token]?.onIngestRejected;
  void setOnIngestRejected(
          String token, OursPrivacyIngestRejectedCallback? callback) =>
      _for(token).onIngestRejected = callback;

  /// Test hook: forget all per-token configuration.
  void resetForTesting() => _config.clear();
}
