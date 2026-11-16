/// Ours Privacy Flutter SDK demo.
library;

import 'package:app_links/app_links.dart';
import 'package:material_ui/material_ui.dart';

import 'analytics.dart';
import 'config.dart';
import 'demo_app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final config = DemoConfig.fromEnvironment();

  // Create AppLinks early so the link that started the app is not missed.
  final appLinks = AppLinks();

  Object? initError;
  try {
    await initOursPrivacy(config);
  } catch (error) {
    // Show the failure in the app instead of a blank screen.
    debugPrint('[OursPrivacy] init failed: $error');
    initError = error;
  }

  runApp(
    DemoApp(
      config: config,
      // Delivers the link that started the app, then each later link.
      deepLinks: appLinks.uriLinkStream,
      initError: initError,
    ),
  );
}
