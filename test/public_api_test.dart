// Public API surface test. Replaces __tests__/declarations.test.ts (React
// Native SDK), which type-checks index.d.ts. Here:
// - every documented public method is assigned to a variable of its
//   documented function type, so a signature change fails compilation;
// - `package:ours_privacy/ours_privacy.dart` exports exactly the documented
//   types;
// - every method other than `init` and `close` throws `StateError` before
//   `init` and after `close`;
// - storage failures and corrupt persisted state surface as
//   `OursPrivacyException` (an `Exception`);
// - `close` stops timers and the lifecycle listener, using only the public
//   API inside a widget test;
// - blank token / eventName / url / visitorId and non-JSON property maps
//   throw `ArgumentError` synchronously (the facade is not `async`);
// - futures from un-awaited `track`, `trackScreen` and `reset` never reach
//   the zone's uncaught-error handler, even when storage fails.
//
// declarations.test.ts also asserts compile errors (`// @ts-expect-error`
// for a non-string screen label, a non-function rejection callback, a
// numeric appVersion, function-valued properties). Dart's static types give
// the same guarantees for the first three, and a negative compile check
// cannot run inside a test; function-valued properties are a runtime
// ArgumentError in Dart and are covered below.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ours_privacy/ours_privacy.dart';
import 'package:ours_privacy/src/config.dart' show OursPrivacyConfig;
import 'package:ours_privacy/src/testing.dart' show OursAppState;

import 'helpers/facade_harness.dart';

const _token = 'public-api-token';
const _notInitialized =
    'OursPrivacy.init(token, options) must be called before any other method.';

Matcher _argumentError(String message) => throwsA(
      isA<ArgumentError>().having((e) => e.message, 'message', message),
    );

final Matcher _throwsNotInitialized = throwsA(
  isA<StateError>().having((e) => e.message, 'message', _notInitialized),
);

/// Every method other than `init` and `close` throws the not-initialized
/// [StateError] on [op].
void _expectEveryMethodThrowsNotInitialized(OursPrivacy op) {
  expect(() => op.setServerURL('https://x.test'), _throwsNotInitialized);
  expect(() => op.setLoggingEnabled(true), _throwsNotInitialized);
  expect(() => op.setFlushOnBackground(true), _throwsNotInitialized);
  expect(() => op.setFlushBatchSize(10), _throwsNotInitialized);
  expect(() => op.hasOptedOutTracking(), _throwsNotInitialized);
  expect(() => op.optInTracking(), _throwsNotInitialized);
  expect(() => op.optOutTracking(), _throwsNotInitialized);
  expect(() => op.identify(), _throwsNotInitialized);
  expect(() => op.identify({'email': 'a@b.test'}), _throwsNotInitialized);
  expect(() => op.track('event'), _throwsNotInitialized);
  expect(() => op.trackScreen('Home'), _throwsNotInitialized);
  expect(() => op.reset(), _throwsNotInitialized);
  expect(() => op.getVisitorId(), _throwsNotInitialized);
  expect(
    () => op.updateDefaultEventProperties({'a': 1}),
    _throwsNotInitialized,
  );
  expect(
    () => op.updateDefaultUserCustomProperties({'a': 1}),
    _throwsNotInitialized,
  );
  expect(
    () => op.updateDefaultUserConsentProperties({'a': true}),
    _throwsNotInitialized,
  );
  expect(() => op.trackDeepLink('myapp://open'), _throwsNotInitialized);
  expect(() => op.setVisitorId('visitor'), _throwsNotInitialized);
  expect(() => op.flush(), _throwsNotInitialized);
}

/// An [OursPrivacyException] whose cause is a [StateError] with [message].
Matcher _storageFailure(String message) => isA<OursPrivacyException>().having(
      (e) => e.cause,
      'cause',
      isA<StateError>().having((e) => e.message, 'message', message),
    );

void main() {
  group('public API', () {
    late FacadeHarness h;

    setUp(() => h = FacadeHarness());
    tearDown(() => h.dispose());

    Future<OursPrivacy> initialized({OursPrivacyStorage? storage}) async {
      final op = h.create();
      await op.init(_token, storage: storage ?? InMemoryStorage());
      return op;
    }

    group('surface', () {
      test('the public library exports exactly the documented types', () {
        final source = File('lib/ours_privacy.dart').readAsStringSync();
        final exports = RegExp(r"^export\s+'[^']+'([^;]*);", multiLine: true)
            .allMatches(source)
            .toList();
        final shown = <String>{};
        for (final export in exports) {
          final combinators = export.group(1)!.trim();
          expect(combinators, startsWith('show '),
              reason: 'every export must use `show`: ${export.group(0)}');
          shown.addAll(
            combinators.substring(5).split(',').map((name) => name.trim()),
          );
        }
        expect(shown, {
          'OursPrivacyIngestRejection',
          'OursPrivacyException',
          'InMemoryStorage',
          'OursPrivacyStorage',
        });

        final publicDeclarations = <String>{};
        final declaration = RegExp(r'([A-Za-z_$][\w$]*)\s*(?:\(|=|;|\{)');
        for (final line in source.split('\n')) {
          if (line.isEmpty ||
              line.startsWith(' ') ||
              line.startsWith('/') ||
              line.startsWith('}') ||
              line.startsWith(')') ||
              line.startsWith('import ') ||
              line.startsWith('export ') ||
              line.startsWith('library')) {
            continue;
          }
          final classMatch =
              RegExp(r'^(?:abstract\s+)?class\s+(\w+)').firstMatch(line);
          final name =
              classMatch?.group(1) ?? declaration.firstMatch(line)?.group(1);
          if (name != null && !name.startsWith('_')) {
            publicDeclarations.add(name);
          }
        }
        expect(publicDeclarations, {'OursPrivacy'});
      });

      test('every public method has the documented signature', () {
        final op = OursPrivacy();

        // Assigning each tear-off to its documented type is the check: a
        // mismatch is a compile error.
        final Future<void> Function(
          String token, {
          bool trackAutomaticEvents,
          String? appVersion,
          String? appBuild,
          void Function(OursPrivacyIngestRejection rejection)? onIngestRejected,
          bool optOutTrackingByDefault,
          String? serverURL,
          String? visitorId,
          String? initialURL,
          Map<String, Object?>? defaultEventProperties,
          Map<String, Object?>? defaultUserCustomProperties,
          Map<String, Object?>? defaultUserConsentProperties,
          OursPrivacyStorage? storage,
          http.Client? httpClient,
        }) init = op.init;
        final void Function(String serverURL) setServerURL = op.setServerURL;
        final void Function(bool enabled) setLoggingEnabled =
            op.setLoggingEnabled;
        final void Function(bool enabled) setFlushOnBackground =
            op.setFlushOnBackground;
        final void Function(int size) setFlushBatchSize = op.setFlushBatchSize;
        final bool Function() hasOptedOutTracking = op.hasOptedOutTracking;
        final Future<void> Function() optInTracking = op.optInTracking;
        final Future<void> Function() optOutTracking = op.optOutTracking;
        final Future<void> Function([Map<String, Object?>? userProperties])
            identify = op.identify;
        final Future<void> Function(
          String eventName, [
          Map<String, Object?>? eventProperties,
          Map<String, Object?>? userProperties,
        ]) track = op.track;
        final Future<void> Function(String screenName) trackScreen =
            op.trackScreen;
        final Future<void> Function() reset = op.reset;
        final String? Function() getVisitorId = op.getVisitorId;
        final void Function(Map<String, Object?> properties)
            updateDefaultEventProperties = op.updateDefaultEventProperties;
        final void Function(Map<String, Object?> properties)
            updateDefaultUserCustomProperties =
            op.updateDefaultUserCustomProperties;
        final void Function(Map<String, Object?> properties)
            updateDefaultUserConsentProperties =
            op.updateDefaultUserConsentProperties;
        final Future<void> Function(String url) trackDeepLink =
            op.trackDeepLink;
        final Future<void> Function(String visitorId) setVisitorId =
            op.setVisitorId;
        final Future<void> Function() flush = op.flush;
        final Future<void> Function() close = op.close;

        expect(
          <Object>[
            init,
            setServerURL,
            setLoggingEnabled,
            setFlushOnBackground,
            setFlushBatchSize,
            hasOptedOutTracking,
            optInTracking,
            optOutTracking,
            identify,
            track,
            trackScreen,
            reset,
            getVisitorId,
            updateDefaultEventProperties,
            updateDefaultUserCustomProperties,
            updateDefaultUserConsentProperties,
            trackDeepLink,
            setVisitorId,
            flush,
            close,
          ],
          hasLength(20),
        );
      });

      test('the exported value types have the documented shape', () async {
        const rejection = OursPrivacyIngestRejection(
          distinctId: 'event-1',
          code: 'invalid_session',
        );
        final String distinctId = rejection.distinctId;
        final String code = rejection.code;
        expect(distinctId, 'event-1');
        expect(code, 'invalid_session');

        final OursPrivacyStorage storage = InMemoryStorage();
        expect(await storage.getItem('k'), isNull);
        await storage.setItem('k', 'v');
        expect(await storage.getItem('k'), 'v');
        await storage.removeItem('k');
        expect(await storage.getItem('k'), isNull);

        final cause = StateError('disk full');
        final Exception exception =
            OursPrivacyException('storage failed', cause: cause);
        final OursPrivacyException typed = exception as OursPrivacyException;
        final String message = typed.message;
        final Object? typedCause = typed.cause;
        expect(message, 'storage failed');
        expect(typedCause, same(cause));
        expect(
          '$exception',
          'OursPrivacyException: storage failed (cause: Bad state: disk full)',
        );
        expect(
          '${const OursPrivacyException('corrupt')}',
          'OursPrivacyException: corrupt',
        );
        expect(const OursPrivacyException('corrupt').cause, isNull);
      });

      test('a host-implemented OursPrivacyStorage is used for persistence',
          () async {
        final storage = FacadeStorage();
        final op = await initialized(storage: storage);
        expect(storage.values['OURSPRIVACY_${_token}_DEVICE_ID'],
            op.getVisitorId());
      });

      test('onIngestRejected receives a typed rejection', () async {
        final rejections = <OursPrivacyIngestRejection>[];
        final op = h.create();
        await op.init(
          _token,
          storage: InMemoryStorage(),
          onIngestRejected: (rejection) => rejections.add(rejection),
        );
        await op.track('rejected');
        h.respondOnce.add(facadeJson({
          'success': true,
          'accepted': 0,
          'rejected': [
            {'index': 0, 'code': 'invalid_session'},
          ],
        }));
        await op.flush();
        expect(rejections, hasLength(1));
        expect(rejections.single.code, 'invalid_session');
        expect(rejections.single.distinctId, matches(facadeUuidV4));
      });

      test('the declaration examples are accepted', () async {
        final op = await initialized();
        await op.track('purchase', {
          'value': 42,
          'currency': 'USD',
          'details': {
            'items': [
              {'sku': 'book', 'quantity': 1},
            ],
            'discount': null,
          },
        });
        await op.identify({
          'externalId': 'visitor-1',
          'customProperties': {'plan': 'plus', 'seats': 3},
          'consent': {'analytics': true},
        });
        op.updateDefaultEventProperties({'origin': 'demo', 'enabled': true});
        op.updateDefaultUserConsentProperties({'marketing': false});
        op.updateDefaultUserConsentProperties({'analytics': 'granted'});
        await op.identify({
          'consent': {'analytics': 'granted'},
        });
        await op.trackScreen('Schedule');
        const String? maybeCoupon = null;
        await op.track('purchase', {'coupon': maybeCoupon});
        final order = {
          'id': 'order-1',
          'total': 42,
          'items': [
            {'sku': 'book', 'quantity': 1},
          ],
        };
        await op.track('purchase', order);
        op.updateDefaultEventProperties(order);
        final Future<void> trackCompletion = op.track('awaitable');
        final Future<void> screenCompletion = op.trackScreen('Home');
        final Future<void> resetCompletion = op.reset();
        final bool optedOut = op.hasOptedOutTracking();
        await Future.wait([trackCompletion, screenCompletion, resetCompletion]);
        expect(optedOut, isFalse);
      });
    });

    group('before init', () {
      test('every method other than init and close throws StateError', () {
        _expectEveryMethodThrowsNotInitialized(OursPrivacy());
      });

      test('the not-initialized check runs before argument validation', () {
        final op = OursPrivacy();
        expect(() => op.track(''), _throwsNotInitialized);
        expect(() => op.trackDeepLink(''), _throwsNotInitialized);
        expect(() => op.setVisitorId(''), _throwsNotInitialized);
        expect(() => op.trackScreen('1 bad'), _throwsNotInitialized);
      });

      test('a failed init does not count as uninitialized', () async {
        final storage = FacadeStorage(persistWrites: false)
          ..onGet = (key) {
            if (key.endsWith('_OPT_OUT')) throw StateError('read failed');
          };
        final op = h.create();
        await expectLater(
          op.init(_token, storage: storage),
          throwsA(_storageFailure('read failed')),
        );
        expect(op.getVisitorId, returnsNormally);
      });
    });

    group('runtime failures', () {
      test('an init storage failure is an Exception, not an Error', () async {
        final storage = FacadeStorage()
          ..onGet = (key) {
            if (key.endsWith('_DEVICE_ID')) throw StateError('read failed');
          };
        final op = h.create();
        Object? caught;
        try {
          await op.init(_token, storage: storage);
        } on Exception catch (error) {
          caught = error;
        }
        expect(caught, _storageFailure('read failed'));
        expect(
          (caught! as OursPrivacyException).message,
          contains('read failed for OURSPRIVACY_${_token}_DEVICE_ID'),
        );
      });

      test('a storage backend that throws synchronously is wrapped too',
          () async {
        final op = h.create();
        await expectLater(
          op.init(_token, storage: _SyncThrowingStorage()),
          throwsA(isA<OursPrivacyException>()
              .having((e) => e.cause, 'cause', isA<UnsupportedError>())),
        );
      });

      for (final (key, value, message) in [
        ('_OPT_OUT', 'maybe', 'Invalid stored tracking decision'),
        ('_OPT_OUT_DECISION_V1', 'maybe', 'Invalid stored tracking decision'),
        ('_OPT_OUT_DEFAULT_V1', 'maybe', 'Invalid stored tracking default'),
        ('_MOBILE_INSTALL_V1', 'unknown', 'Invalid stored mobile installation'),
      ]) {
        test(
            'corrupt persisted state ($key) fails init with '
            'OursPrivacyException', () async {
          final storage = InMemoryStorage();
          await storage.setItem('OURSPRIVACY_$_token$key', value);
          final op = h.create();
          await expectLater(
            op.init(_token, storage: storage),
            throwsA(isA<OursPrivacyException>()
                .having((e) => e.message, 'message', message)
                .having((e) => e.cause, 'cause', isNull)),
          );
          expect(op.hasOptedOutTracking(), isTrue);
        });
      }

      test('a failed opt-out write completes with OursPrivacyException',
          () async {
        var failWrites = false;
        final storage = FacadeStorage()
          ..onSet = (key, value) {
            if (failWrites) throw StateError('disk full');
          };
        final op = await initialized(storage: storage);
        failWrites = true;
        await expectLater(
          op.optOutTracking(),
          throwsA(_storageFailure('disk full')),
        );
        expect(op.hasOptedOutTracking(), isTrue);
      });
    });

    group('close', () {
      test('before init does nothing and the instance stays uninitialized',
          () async {
        final op = h.create();
        await op.close();
        await op.close();
        _expectEveryMethodThrowsNotInitialized(op);
        await op.init(_token, storage: InMemoryStorage());
        expect(op.getVisitorId(), matches(facadeUuidV4));
      });

      test('stops the instance; other methods throw until init', () async {
        final op = h.create();
        await op.init(
          _token,
          storage: InMemoryStorage(),
          trackAutomaticEvents: true,
        );
        final impl = h.impl(op);
        expect(h.appState.listenerCount, 1);
        expect(impl.hasCheckpointTimer, isTrue);
        expect(h.clock.pendingTimers, greaterThan(0));

        await op.close();

        expect(impl.isDisposed, isTrue);
        expect(impl.hasCheckpointTimer, isFalse);
        expect(h.appState.listenerCount, 0);
        expect(h.clock.pendingTimers, 0);
        _expectEveryMethodThrowsNotInitialized(op);
        await op.close();
        _expectEveryMethodThrowsNotInitialized(op);
      });

      test('queued events survive close and are sent after init', () async {
        final storage = InMemoryStorage();
        final op = h.create();
        await op.init(_token, storage: storage);
        h.suspendPeriodicNetworkFlush(_token);
        final visitorId = op.getVisitorId();
        await op.track('before close');
        await op.close();
        expect(h.requests, isEmpty);

        await op.init(_token, storage: storage);
        expect(op.getVisitorId(), visitorId);
        await op.track('after close');
        await op.flush();
        expect(facadeEventNames(h.sentEvents), ['before close', 'after close']);
      });

      test('close during init leaves nothing running', () async {
        final op = h.create();
        final init = op.init(
          _token,
          storage: InMemoryStorage(),
          trackAutomaticEvents: true,
        );
        final impl = h.impl(op);
        final closing = op.close();
        await init;
        await closing;
        expect(impl.isDisposed, isTrue);
        expect(impl.hasCheckpointTimer, isFalse);
        expect(h.appState.listenerCount, 0);
        expect(h.clock.pendingTimers, 0);
        _expectEveryMethodThrowsNotInitialized(op);
      });

      test('init right after an un-awaited close waits for it', () async {
        final storage = InMemoryStorage();
        final op = h.create();
        await op.init(_token, storage: storage);
        final first = h.impl(op);
        final closing = op.close();
        final init = op.init(_token, storage: storage);
        await Future.wait([closing, init]);
        expect(first.isDisposed, isTrue);
        expect(h.impl(op).isInitialized, isTrue);
        expect(h.appState.listenerCount, 1);
      });
    });

    group('argument validation', () {
      for (final blank in ['', ' ', '   ', '\t', '\n', ' \t\r\n ']) {
        final label = blank.replaceAll('\t', r'\t').replaceAll('\n', r'\n');
        test('blank strings ("$label") throw ArgumentError synchronously',
            () async {
          expect(
            () => OursPrivacy().init(blank),
            _argumentError('token is not a valid string'),
          );
          final op = await initialized();
          expect(
            () => op.track(blank),
            _argumentError('eventName is not a valid string'),
          );
          expect(
            () => op.trackDeepLink(blank),
            _argumentError('url is not a valid string'),
          );
          expect(
            () => op.setVisitorId(blank),
            _argumentError('visitorId is not a valid string'),
          );
          await op.flush();
          expect(h.requests, isEmpty);
        });
      }

      test('a blank token leaves the instance uninitialized', () {
        final op = h.create();
        expect(() => op.init(' '), throwsArgumentError);
        expect(() => op.track('event'), _throwsNotInitialized);
      });

      final invalidValues = <String, Object?>{
        'DateTime': DateTime(2026),
        'function': () => 'no',
        'Object': Object(),
        'Set': {1, 2},
        'nested DateTime in a list': [DateTime(2026)],
        'nested non-String key': {
          'inner': {1: 'one'},
        },
        'Uri': Uri.parse('https://example.test'),
      };

      for (final MapEntry(key: name, value: value) in invalidValues.entries) {
        test('non-JSON property values throw ArgumentError: $name', () async {
          final op = await initialized();
          final properties = <String, Object?>{'bad': value};
          expect(
            () => op.track('event', properties),
            _argumentError('properties is not a valid json object'),
          );
          expect(
            () => op.track('event', null, properties),
            _argumentError('userProperties is not a valid json object'),
          );
          expect(
            () => op.identify(properties),
            _argumentError('userProperties is not a valid json object'),
          );
          expect(
            () => op.updateDefaultEventProperties(properties),
            _argumentError('properties is not a valid json object'),
          );
          expect(
            () => op.updateDefaultUserCustomProperties(properties),
            _argumentError('properties is not a valid json object'),
          );
          expect(
            () => op.updateDefaultUserConsentProperties(properties),
            _argumentError('properties is not a valid json object'),
          );
          for (final option in [
            'defaultEventProperties',
            'defaultUserCustomProperties',
            'defaultUserConsentProperties',
          ]) {
            final fresh = OursPrivacy();
            expect(
              () => fresh.init(
                _token,
                defaultEventProperties:
                    option == 'defaultEventProperties' ? properties : null,
                defaultUserCustomProperties:
                    option == 'defaultUserCustomProperties' ? properties : null,
                defaultUserConsentProperties:
                    option == 'defaultUserConsentProperties'
                        ? properties
                        : null,
              ),
              _argumentError('$option is not a valid json object'),
            );
          }
          await op.flush();
          expect(h.requests, isEmpty);
        });
      }

      test('a cyclic property map throws ArgumentError', () async {
        final op = await initialized();
        final cyclic = <String, Object?>{};
        cyclic['self'] = cyclic;
        final list = <Object?>[];
        list.add(list);
        expect(
          () => op.track('event', cyclic),
          _argumentError('properties is not a valid json object'),
        );
        expect(
          () => op.track('event', {'list': list}),
          _argumentError('properties is not a valid json object'),
        );
      });

      test('non-finite numbers are sent as null, like JSON.stringify',
          () async {
        final op = await initialized();
        await op.track('numbers', {
          'nan': double.nan,
          'inf': double.infinity,
          'ok': 1.5,
        });
        await op.flush();
        final props = eventPropsOf(h.sentEvents.single);
        expect(props.containsKey('nan'), isTrue);
        expect(props['nan'], isNull);
        expect(props['inf'], isNull);
        expect(props['ok'], 1.5);
      });

      test('caller maps are copied, so later mutation does not change events',
          () async {
        final op = await initialized();
        final nested = <String, Object?>{'value': 'before'};
        final properties = <String, Object?>{'nested': nested};
        final pending = op.track('copied', properties);
        nested['value'] = 'after';
        properties['added'] = true;
        await pending;
        await op.flush();
        final props = eventPropsOf(h.sentEvents.single);
        expect(props['nested'], {'value': 'before'});
        expect(props.containsKey('added'), isFalse);
      });

      test(r'$mobile_ event names log the reserved warning and do nothing',
          () async {
        final op = await initialized();
        await expectLater(op.track(r'$mobile_first_open'), completes);
        await expectLater(op.track(r'$mobile_anything', {'a': 1}), completes);
        await op.flush();
        expect(h.requests, isEmpty);
        expect(
          h.logs.where((line) => line.startsWith('warning:')),
          [
            r'warning: Event names starting with $mobile_ are reserved',
            r'warning: Event names starting with $mobile_ are reserved',
          ],
        );
      });

      test('setFlushBatchSize clamps to 1..50', () async {
        final op = await initialized();
        op.setFlushBatchSize(0);
        expect(OursPrivacyConfig.instance.getFlushBatchSize(_token), 1);
        op.setFlushBatchSize(-5);
        expect(OursPrivacyConfig.instance.getFlushBatchSize(_token), 1);
        op.setFlushBatchSize(51);
        expect(OursPrivacyConfig.instance.getFlushBatchSize(_token), 50);
        op.setFlushBatchSize(20);
        expect(OursPrivacyConfig.instance.getFlushBatchSize(_token), 20);
      });
    });

    group('unobserved futures', () {
      test(
          'un-awaited track with a failing storage does not produce an uncaught '
          'zone error', () async {
        var failWrites = false;
        final storage = FacadeStorage()
          ..onSet = (key, value) {
            if (failWrites) throw StateError('disk full');
          };
        final op = await initialized(storage: storage);
        failWrites = true;

        final uncaught = <Object>[];
        runZonedGuarded(
          () {
            unawaited(op.track('lost', {'a': 1}));
            unawaited(op.trackScreen('Home'));
            unawaited(op.reset());
          },
          (error, stack) => uncaught.add(error),
        );
        await facadeSettle(50);

        expect(uncaught, isEmpty);
        expect(
          h.logs.where((line) =>
              line.startsWith('error:') && line.contains('disk full')),
          isNotEmpty,
        );
        expect(h.queue(op), isEmpty);
      });

      test('awaited track, trackScreen and reset complete normally on failure',
          () async {
        var failWrites = false;
        final storage = FacadeStorage()
          ..onSet = (key, value) {
            if (failWrites) throw StateError('disk full');
          };
        final op = await initialized(storage: storage);
        failWrites = true;
        await expectLater(op.track('lost'), completes);
        await expectLater(op.trackScreen('Home'), completes);
        await expectLater(op.reset(), completes);
      });
    });

    group('init', () {
      test('attaches the lifecycle listener synchronously', () async {
        final op = h.create();
        final init = op.init(_token, storage: InMemoryStorage());
        expect(h.appState.listenerCount, 1);
        // A lifecycle event delivered before init completes is buffered and
        // applied once storage has loaded, even though the platform's current
        // state reads as unknown by then.
        h.appState.emit(OursAppState.resumed);
        h.appState.currentState = null;
        await init;
        expect(h.impl(op).appForegrounded, isTrue);
      });

      test('calling init again replaces the previous instance', () async {
        final op = await initialized();
        final first = h.impl(op);
        await op.init(_token, storage: InMemoryStorage());
        expect(identical(h.impl(op), first), isFalse);
        expect(first.isDisposed, isTrue);
        expect(h.appState.listenerCount, 1);
      });
    });
  });

  // Uses only the public API, the way an app's own widget tests would: no
  // test hooks, the real lifecycle listener and the real timers (which
  // flutter_test fakes and checks for leaks when the test ends).
  testWidgets('close leaves no pending timers in a widget test',
      (tester) async {
    final requests = <http.Request>[];
    final op = OursPrivacy();
    await op.init(
      _token,
      trackAutomaticEvents: true,
      storage: InMemoryStorage(),
      httpClient: MockClient((request) async {
        requests.add(request);
        return http.Response('{"success":true}', 200);
      }),
    );
    await op.track('widget test');
    await op.flush();
    expect(requests, hasLength(1));
    expect(requests.single.body, contains('widget test'));

    await op.close();
    expect(() => op.track('after close'), _throwsNotInitialized);
  });
}

/// Storage whose methods throw before returning a future.
class _SyncThrowingStorage implements OursPrivacyStorage {
  @override
  Future<String?> getItem(String key) => throw UnsupportedError('sync read');

  @override
  Future<void> setItem(String key, String value) =>
      throw UnsupportedError('sync write');

  @override
  Future<void> removeItem(String key) => throw UnsupportedError('sync remove');
}
