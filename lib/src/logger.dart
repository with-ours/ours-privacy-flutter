// Port of javascript/oursprivacy-logger.js. Silent unless logging is enabled
// for the token via setLoggingEnabled.
import 'package:flutter/foundation.dart' show debugPrint;

import 'config.dart';

enum OursPrivacyLogLevel { debug, info, warning, error }

/// Test hook: receives every emitted log line. Null in production.
void Function(OursPrivacyLogLevel level, String message)? oursPrivacyLogSink;

class OursPrivacyLogger {
  const OursPrivacyLogger._();

  static void log(String? token, String message) =>
      _emit(token, OursPrivacyLogLevel.debug, message);
  static void info(String? token, String message) =>
      _emit(token, OursPrivacyLogLevel.info, message);
  static void warn(String? token, String message) =>
      _emit(token, OursPrivacyLogLevel.warning, message);
  static void error(String? token, String message) =>
      _emit(token, OursPrivacyLogLevel.error, message);

  static void _emit(String? token, OursPrivacyLogLevel level, String message) {
    final sink = oursPrivacyLogSink;
    if (sink != null) sink(level, message);
    if (token == null || !OursPrivacyConfig.instance.getLoggingEnabled(token)) {
      return;
    }
    debugPrint('[OursPrivacy] ${level.name}: $message');
  }
}
