// Demo configuration, read from `--dart-define` values at build time.
//
//   flutter run \
//     --dart-define=OURSPRIVACY_TOKEN=<your test source token> \
//     --dart-define=OURSPRIVACY_SERVER_URL=https://cdn.oursprivacy.com \
//     --dart-define=OURSPRIVACY_TRACK_AUTOMATIC_EVENTS=true
//
// Plays the role of the React Native demo's `.env` file (`@env`).

/// Used when no `OURSPRIVACY_TOKEN` is defined. It is not a real token:
/// events sent with it are rejected. Never commit a real token.
const String placeholderToken = 'YOUR_API_TOKEN';

/// The SDK's default ingest server, shown when no server URL is defined.
const String defaultServerURL = 'https://cdn.oursprivacy.com';

/// App release metadata sent with lifecycle events (matches pubspec.yaml).
const String demoAppVersion = '1.0.0';
const String demoAppBuild = '1';

const String _tokenDefine = String.fromEnvironment('OURSPRIVACY_TOKEN');
const String _serverURLDefine = String.fromEnvironment(
  'OURSPRIVACY_SERVER_URL',
);
const bool _trackAutomaticEventsDefine = bool.fromEnvironment(
  'OURSPRIVACY_TRACK_AUTOMATIC_EVENTS',
  defaultValue: true,
);

/// How the demo initializes the SDK.
class DemoConfig {
  const DemoConfig({
    required this.token,
    this.serverURL,
    this.trackAutomaticEvents = true,
  });

  /// Builds a config from raw define values: a blank token falls back to
  /// [placeholderToken], and a blank server URL means the SDK default.
  factory DemoConfig.fromDefines({
    String token = '',
    String serverURL = '',
    bool trackAutomaticEvents = true,
  }) {
    final trimmedToken = token.trim();
    final trimmedServerURL = serverURL.trim();
    return DemoConfig(
      token: trimmedToken.isEmpty ? placeholderToken : trimmedToken,
      serverURL: trimmedServerURL.isEmpty ? null : trimmedServerURL,
      trackAutomaticEvents: trackAutomaticEvents,
    );
  }

  /// The configuration compiled into this build with `--dart-define`.
  factory DemoConfig.fromEnvironment() => DemoConfig.fromDefines(
    token: _tokenDefine,
    serverURL: _serverURLDefine,
    trackAutomaticEvents: _trackAutomaticEventsDefine,
  );

  /// The source's API token.
  final String token;

  /// Ingest server override, or null for the SDK default.
  final String? serverURL;

  /// Whether the SDK sends lifecycle events (opens, sessions, engagement).
  final bool trackAutomaticEvents;

  /// True when no token was defined for this build.
  bool get usesPlaceholderToken => token == placeholderToken;

  /// The server the SDK sends to.
  String get effectiveServerURL => serverURL ?? defaultServerURL;

  DemoConfig copyWith({bool? trackAutomaticEvents}) => DemoConfig(
    token: token,
    serverURL: serverURL,
    trackAutomaticEvents: trackAutomaticEvents ?? this.trackAutomaticEvents,
  );
}
