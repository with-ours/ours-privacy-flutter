import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'analytics.dart';
import 'config.dart';

/// Re-initializes the SDK with a new configuration (the automatic-events
/// toggle). Tests pass one that injects in-memory storage and a mock client.
typedef DemoInitializer = Future<void> Function(DemoConfig config);

Future<void> _defaultInitializer(DemoConfig config) => initOursPrivacy(config);

/// Simulated warm-start deep link with attribution that replaces the launch
/// link's attribution, as in the React Native demo.
const String demoWarmDeepLink =
    'oursdemo://products/456?utm_source=applovin&utm_medium=display'
    '&aleid=warm_aleid_789&alart=warm_alart_abc'
    '&ours_visitor_id=web-visitor-uuid-from-deep-link';

class DemoApp extends StatefulWidget {
  const DemoApp({
    super.key,
    required this.config,
    this.deepLinks,
    this.initError,
    this.initializer = _defaultInitializer,
  });

  /// The configuration [op] was initialized with.
  final DemoConfig config;

  /// Incoming deep links (`AppLinks().uriLinkStream` in the app).
  final Stream<Uri>? deepLinks;

  /// Set when the first `init` failed.
  final Object? initError;

  final DemoInitializer initializer;

  @override
  State<DemoApp> createState() => _DemoAppState();
}

class _DemoAppState extends State<DemoApp> {
  final _screenObserver = OursScreenObserver();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ours Privacy Demo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF841584)),
      ),
      navigatorObservers: [_screenObserver],
      routes: {
        '/': (context) => DemoHomePage(
          config: widget.config,
          deepLinks: widget.deepLinks,
          initError: widget.initError,
          initializer: widget.initializer,
        ),
        '/schedule': (context) => const ScheduleScreen(),
      },
    );
  }
}

class DemoHomePage extends StatefulWidget {
  const DemoHomePage({
    super.key,
    required this.config,
    required this.initializer,
    this.deepLinks,
    this.initError,
  });

  final DemoConfig config;
  final DemoInitializer initializer;
  final Stream<Uri>? deepLinks;
  final Object? initError;

  @override
  State<DemoHomePage> createState() => _DemoHomePageState();
}

class _DemoHomePageState extends State<DemoHomePage> {
  late DemoConfig _config = widget.config;
  late String _status = widget.initError == null
      ? 'Initialized'
      : 'Init failed: ${widget.initError}';
  StreamSubscription<Uri>? _deepLinkSubscription;

  @override
  void initState() {
    super.initState();
    // Hand every link the app is opened with to the SDK, on a cold start and
    // on a warm open. Awaiting trackDeepLink applies the visitor ID and
    // attribution before anything tracked afterward.
    _deepLinkSubscription = widget.deepLinks?.listen((uri) async {
      await _run('Deep link tracked (${uri.scheme}://${uri.host})', () async {
        await op.trackDeepLink(uri.toString());
      });
    });
  }

  @override
  void dispose() {
    unawaited(_deepLinkSubscription?.cancel());
    super.dispose();
  }

  void _log(String message) => debugPrint('[OursPrivacy] $message');

  String? _visitorId() {
    try {
      return op.getVisitorId();
    } catch (_) {
      return null;
    }
  }

  bool _optedOut() {
    try {
      return op.hasOptedOutTracking();
    } catch (_) {
      return true;
    }
  }

  /// Runs an SDK action, then shows [done] (or the error) and the current
  /// visitor ID.
  Future<void> _run(String done, Future<void> Function() action) async {
    String status;
    try {
      await action();
      status = done;
    } catch (error) {
      status = 'Failed: $error';
    }
    _log('$status. visitor_id: ${_visitorId()}');
    if (mounted) setState(() => _status = status);
  }

  VoidCallback _action(String done, Future<void> Function() action) =>
      () => unawaited(_run(done, action));

  Future<void> _handleTrack() async {
    _log('visitor_id: ${_visitorId()}');
    await op.track('button_pressed', {'button': 'Track Event'});
    await op.flush();
  }

  Future<void> _handleIdentify() async {
    await op.identify({
      'email': 'demo-user@example.com',
      'externalId': 'demo-user-123',
      'customProperties': {'plan': 'demo'},
    });
    await op.flush();
  }

  Future<void> _handleUpdateDefaults() async {
    op.updateDefaultEventProperties({'last_action': 'update_defaults'});
    op.updateDefaultUserConsentProperties({
      'marketing': true,
      'analytics': true,
    });
    await op.track('defaults_updated');
    await op.flush();
  }

  Future<void> _handleTrackDeepLink() async {
    // Simulate a warm-start deep link with different attribution (replaces
    // init's attribution).
    await op.trackDeepLink(demoWarmDeepLink);
    await op.flush();
  }

  Future<void> _handleTrackAfterAttribution() async {
    // This should include attribution from the most recent deep link in
    // defaultProperties.
    await op.track('post_attribution_event', {'source': 'manual_test'});
    await op.flush();
  }

  Future<void> _handleSetVisitorId() async {
    final newId =
        'manually-set-visitor-id-${DateTime.now().millisecondsSinceEpoch}';
    await op.setVisitorId(newId);
    await op.track('after_set_visitor_id', {'new_visitor_id': newId});
    await op.flush();
  }

  Future<void> _handleOptIn() async {
    await op.optInTracking();
    await op.flush();
  }

  Future<void> _setTrackAutomaticEvents(bool enabled) async {
    final next = _config.copyWith(trackAutomaticEvents: enabled);
    await _run('Re-initialized with trackAutomaticEvents: $enabled', () async {
      await widget.initializer(next);
      if (mounted) setState(() => _config = next);
    });
  }

  @override
  Widget build(BuildContext context) {
    final optedOut = _optedOut();
    return Scaffold(
      appBar: AppBar(title: const Text('Ours Privacy Demo')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_config.usesPlaceholderToken)
                const _Notice(
                  'No token set. Run with '
                  '--dart-define=OURSPRIVACY_TOKEN=<your token> to send '
                  'events to a test source.',
                ),
              _InfoRow('Server', _config.effectiveServerURL),
              _InfoRow(
                'Visitor ID',
                _visitorId() ?? '(loading)',
                valueKey: const ValueKey('visitorId'),
              ),
              _InfoRow(
                'Tracking',
                optedOut ? 'Opted out' : 'Opted in',
                valueKey: const ValueKey('trackingState'),
              ),
              _InfoRow('Status', _status, valueKey: const ValueKey('status')),
              SwitchListTile(
                key: const ValueKey('trackAutomaticEvents'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Track automatic events'),
                subtitle: const Text(
                  'App opens, sessions, and engagement. Toggling calls '
                  'init again.',
                ),
                value: _config.trackAutomaticEvents,
                onChanged: (value) =>
                    unawaited(_setTrackAutomaticEvents(value)),
              ),
              const _Section(
                'Track Event',
                "Calls track('button_pressed') + flush().",
              ),
              FilledButton(
                onPressed: _action('Tracked + flushed', _handleTrack),
                child: const Text('Track Event'),
              ),
              const _Section(
                'Identify',
                'Calls identify with email, externalId, and '
                    'customProperties.',
              ),
              FilledButton(
                onPressed: _action('Identified + flushed', _handleIdentify),
                child: const Text('Identify User'),
              ),
              const _Section(
                'Update Default Properties',
                'Updates default event + consent properties, then tracks an '
                    'event.',
              ),
              FilledButton(
                onPressed: _action(
                  'Defaults updated + tracked + flushed',
                  _handleUpdateDefaults,
                ),
                child: const Text('Update Defaults + Track'),
              ),
              const _Section(
                'Screens',
                'A NavigatorObserver calls trackScreen() as routes change: '
                    'Home here, Schedule on the next screen.',
              ),
              OutlinedButton(
                onPressed: () =>
                    unawaited(Navigator.of(context).pushNamed('/schedule')),
                child: const Text('Open Schedule'),
              ),
              const _Section(
                'Deep Link Attribution',
                'Tests trackDeepLink() with UTMs, click IDs, and '
                    'ours_visitor_id. Links opened with oursdemo:// are '
                    'tracked the same way.',
              ),
              FilledButton(
                onPressed: _action(
                  'Deep link tracked + flushed',
                  _handleTrackDeepLink,
                ),
                child: const Text('Track Deep Link (warm start)'),
              ),
              FilledButton(
                onPressed: _action(
                  'Post-attribution event tracked + flushed',
                  _handleTrackAfterAttribution,
                ),
                child: const Text('Track After Attribution'),
              ),
              FilledButton(
                onPressed: _action(
                  'Visitor ID set + tracked + flushed',
                  _handleSetVisitorId,
                ),
                child: const Text('Set Visitor ID Manually'),
              ),
              const _Section(
                'Privacy Controls',
                'Opt out stops all tracking. Opt in resumes and sends '
                    r'$opt_in event.',
              ),
              FilledButton(
                onPressed: _action('Opted out', op.optOutTracking),
                child: const Text('Opt Out'),
              ),
              FilledButton(
                onPressed: _action(
                  r'Opted in + flushed ($opt_in event sent)',
                  _handleOptIn,
                ),
                child: const Text('Opt In'),
              ),
              const _Section(
                'Queue and Identity',
                'Flush sends queued events now. Reset clears identity and '
                    'default properties and generates a new visitor ID.',
              ),
              OutlinedButton(
                onPressed: _action('Flushed', op.flush),
                child: const Text('Flush'),
              ),
              OutlinedButton(
                onPressed: _action('Reset', op.reset),
                child: const Text('Reset'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ScheduleScreen extends StatelessWidget {
  const ScheduleScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Schedule')),
      body: const Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'Opening this screen sent a Schedule screen view. Go back to '
            'send Home.',
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title, this.description);

  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(description, style: textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow(this.label, this.value, {this.valueKey});

  final String label;
  final String value;
  final Key? valueKey;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 88,
            child: Text(label, style: Theme.of(context).textTheme.labelLarge),
          ),
          Expanded(child: SelectableText(value, key: valueKey)),
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        message,
        key: const ValueKey('placeholderTokenNotice'),
        style: TextStyle(color: colors.onErrorContainer),
      ),
    );
  }
}
