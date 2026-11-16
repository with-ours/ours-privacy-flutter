import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:ours_privacy/ours_privacy.dart';

import 'config.dart';

/// One SDK instance for the whole app, created before `runApp` as in the
/// Quick Start. Creating it does not touch the Flutter binding.
OursPrivacy get op => _op;
OursPrivacy _op = OursPrivacy();

/// Gives each widget test its own SDK instance. An instance initialized in
/// one test's fake-async zone cannot be re-initialized from the next one.
@visibleForTesting
void replaceOursPrivacyForTesting() => _op = OursPrivacy();

/// Initializes [op] from [config].
///
/// [storage] and [httpClient] are for tests (`InMemoryStorage` and
/// `MockClient`); the app uses the SDK defaults.
Future<void> initOursPrivacy(
  DemoConfig config, {
  OursPrivacyStorage? storage,
  http.Client? httpClient,
}) async {
  debugPrint('[OursPrivacy] init server URL: ${config.effectiveServerURL}');
  await op.init(
    config.token,
    trackAutomaticEvents: config.trackAutomaticEvents,
    appVersion: demoAppVersion,
    appBuild: demoAppBuild,
    serverURL: config.serverURL,
    defaultEventProperties: const {'demo_app': true},
    defaultUserCustomProperties: const {'test_user': true},
    onIngestRejected: (rejection) {
      debugPrint('[OursPrivacy] ingest rejected: ${rejection.code}');
    },
    storage: storage,
    httpClient: httpClient,
  );
  op.setLoggingEnabled(kDebugMode);
}

/// Sends route changes to the SDK as screen views, exactly as the Flutter
/// SDK docs show. Route names map to fixed labels; a route name is never
/// passed through as a label.
class OursScreenObserver extends NavigatorObserver {
  static const screenLabels = {'/': 'Home', '/schedule': 'Schedule'};

  void _trackScreen(Route<dynamic>? route) {
    final label = screenLabels[route?.settings.name];
    // trackScreen never throws for a bad label and logs its own failures,
    // so the docs call it without awaiting.
    if (label != null) unawaited(op.trackScreen(label));
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _trackScreen(route);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _trackScreen(previousRoute);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      _trackScreen(newRoute);
}
