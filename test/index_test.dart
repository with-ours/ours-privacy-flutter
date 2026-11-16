// Port of __tests__/index.test.js (React Native SDK).
//
// The React Native suite mocks OursPrivacyMain with Jest and asserts that the
// `OursPrivacy` wrapper forwards each call (`toHaveBeenCalledWith`). Dart
// cannot replace the class the facade constructs, so each case drives the
// real implementation and asserts the observable result of the forwarded
// call (the implementation's state, the shared config, or the queued row).
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ours_privacy/ours_privacy.dart';
import 'package:ours_privacy/src/config.dart';
import 'package:ours_privacy/src/persistent.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/facade_harness.dart';

late FacadeHarness h;

Future<OursPrivacy> newInitialized({
  String token = 'token',
  bool trackAutomaticEvents = false,
  bool optOutTrackingByDefault = false,
  Map<String, Object?>? defaultEventProperties,
  String? visitorId,
}) async {
  final op = h.create();
  await op.init(
    token,
    storage: InMemoryStorage(),
    trackAutomaticEvents: trackAutomaticEvents,
    optOutTrackingByDefault: optOutTrackingByDefault,
    defaultEventProperties: defaultEventProperties,
    visitorId: visitorId,
  );
  return op;
}

Matcher get throwsInitError => throwsA(
      isA<StateError>().having(
        (error) => error.message,
        'message',
        contains('init'),
      ),
    );

void main() {
  setUp(() => h = FacadeHarness());
  tearDown(() => h.dispose());

  test('init forwards token and options to the impl initialize()', () async {
    final op = await newInitialized(token: 'token');
    final impl = h.impl(op);
    expect(impl.token, 'token');
    expect(impl.isInitialized, isTrue);
    expect(OursPrivacyConfig.instance.getServerURL('token'),
        'https://cdn.oursprivacy.com');
  });

  test('init passes options through verbatim (camelCase)', () async {
    final op = await newInitialized(
      trackAutomaticEvents: false,
      optOutTrackingByDefault: true,
      defaultEventProperties: {'prop': 'value'},
      visitorId: 'preset-visitor-123',
    );
    final impl = h.impl(op);
    expect(impl.trackAutomaticEvents, isFalse);
    expect(op.hasOptedOutTracking(), isTrue);
    expect(impl.defaultEventProperties('token'), {'prop': 'value'});
    expect(op.getVisitorId(), 'preset-visitor-123');
  });

  test('init passes the storage adapter to the OursPrivacyMain constructor',
      () async {
    final storage = FacadeStorage();
    final op = h.create();
    await op.init('token', storage: storage);
    expect(identical(h.impl(op).persistent.storage, storage), isTrue);
    expect(storage.reads, isNotEmpty);
  });

  test('init omits storage when not provided', () async {
    // Without `storage`, the SDK uses its process default backend
    // (shared_preferences). Back it with the plugin's in-memory test store.
    SharedPreferences.setMockInitialValues({});
    final op = h.create();
    await op.init('token');
    final storage = h.impl(op).persistent.storage;
    expect(identical(storage, resolveOursPrivacyStorage(null)), isTrue);
    expect(storage, isNot(isA<InMemoryStorage>()));
  });

  test('init throws when token is missing or blank', () {
    // RN's init is async, so it rejects; the Dart facade throws
    // synchronously. A missing (undefined) token is a compile-time
    // error in Dart, so only the blank cases are ported.
    expect(() => OursPrivacy().init(''), throwsArgumentError);
    expect(() => OursPrivacy().init('   '), throwsArgumentError);
  });

  test('methods throw if called before init()', () {
    final op = OursPrivacy();
    expect(() => op.track('e'), throwsInitError);
    expect(() => op.trackScreen('Schedule'), throwsInitError);
    expect(() => op.reset(), throwsInitError);
    expect(() => op.flush(), throwsInitError);
    expect(() => op.getVisitorId(), throwsInitError);
  });

  test('identify before init() throws', () {
    final op = OursPrivacy();
    expect(() => op.identify({'email': 'a@b.com'}), throwsInitError);
  });

  test('it calls setServerURL', () async {
    final op = await newInitialized();
    op.setServerURL('https://api-eu.oursprivacy.com');
    expect(OursPrivacyConfig.instance.getServerURL('token'),
        'https://api-eu.oursprivacy.com');
  });

  test('it calls setLoggingEnabled', () async {
    final op = await newInitialized();
    op.setLoggingEnabled(true);
    expect(OursPrivacyConfig.instance.getLoggingEnabled('token'), isTrue);
  });

  test('it calls setFlushBatchSize', () async {
    final op = await newInitialized();
    op.setFlushBatchSize(20);
    expect(OursPrivacyConfig.instance.getFlushBatchSize('token'), 20);
  });

  test('it calls hasOptedOutTracking', () async {
    final op = await newInitialized();
    expect(op.hasOptedOutTracking(), h.impl(op).hasOptedOutTracking('token'));
    expect(op.hasOptedOutTracking(), isFalse);
  });

  test('it calls optInTracking', () async {
    final op = await newInitialized(optOutTrackingByDefault: true);
    expect(op.hasOptedOutTracking(), isTrue);
    await op.optInTracking();
    expect(op.hasOptedOutTracking(), isFalse);
    expect(facadeEventNames(h.queue(op)), [r'$opt_in']);
  });

  test('it calls optOutTracking', () async {
    final op = await newInitialized();
    await op.optOutTracking();
    expect(op.hasOptedOutTracking(), isTrue);
  });

  test('flush returns the completion promise from the SDK implementation',
      () async {
    final op = await newInitialized();
    await op.track('queued');
    final release = Completer<void>();
    h.respond = (request) async {
      await release.future;
      return facadeIndexedSuccess(request);
    };

    var completed = false;
    final completion = op.flush().then((_) => completed = true);
    await h.waitForRequests(1);
    expect(completed, isFalse);

    release.complete();
    await completion;
    expect(completed, isTrue);
    expect(h.queue(op), isEmpty);
  });

  test('identify forwards userProperties (no positional id arg)', () async {
    final op = await newInitialized();
    await op.identify({'email': 'user@example.com', 'externalId': '123'});
    final row = h.queue(op).single;
    expect(row['event'], r'$identify');
    expect(userPropsOf(row), {
      'email': 'user@example.com',
      'external_id': '123',
    });
  });

  test('identify with no userProperties is allowed', () async {
    final op = await newInitialized();
    await op.identify();
    final row = h.queue(op).single;
    expect(row['event'], r'$identify');
    expect(row['userProperties'], isNull);
  });

  test('it calls track', () async {
    final op = await newInitialized();
    await op.track('event name', {'Cool Property': 'Property Value'});
    final row = h.queue(op).single;
    expect(row['event'], 'event name');
    expect(eventPropsOf(row), containsPair('Cool Property', 'Property Value'));
    expect(row['userProperties'], isNull);
  });

  test('track forwards camelCase userProperties', () async {
    final op = await newInitialized();
    await op.track(
      'event name',
      {'Cool Property': 'Property Value'},
      {
        'email': 'user@example.com',
        'customProperties': {'plan': 'pro'},
      },
    );
    final row = h.queue(op).single;
    expect(eventPropsOf(row), containsPair('Cool Property', 'Property Value'));
    expect(userPropsOf(row), {
      'email': 'user@example.com',
      'custom_properties': {'plan': 'pro'},
    });
  });

  for (final eventName in [
    r'$mobile_first_open',
    r'$mobile_screen_view',
    r'$mobile_custom',
  ]) {
    test(
        'track ignores reserved event $eventName before forwarding caller '
        'fields', () async {
      final op = await newInitialized();
      await expectLater(
        op.track(
          eventName,
          {'patient_id': 'private'},
          {'email': 'private@example.test'},
        ),
        completes,
      );
      expect(h.queue(op), isEmpty);
      expect(h.logs.join('\n'), isNot(contains('private')));
    });
  }

  test('track continues to forward legacy automatic events', () async {
    final op = await newInitialized();
    await op.track(r'$ae_custom', {'source': 'legacy'});
    final row = h.queue(op).single;
    expect(row['event'], r'$ae_custom');
    expect(eventPropsOf(row), containsPair('source', 'legacy'));
  });

  test('it calls reset', () async {
    final op = await newInitialized(visitorId: 'before-reset');
    op.updateDefaultEventProperties({'tier': 'pro'});
    await op.reset();
    expect(op.getVisitorId(), isNot('before-reset'));
    expect(op.getVisitorId(), matches(facadeUuidV4));
    expect(h.impl(op).defaultEventProperties('token'), isEmpty);
    expect(OursPrivacyConfig.instance.getIsManuallySetId('token'), isFalse);
  });

  test('it calls getVisitorId', () async {
    final op = await newInitialized();
    final id = op.getVisitorId();
    expect(id, h.impl(op).getVisitorId('token'));
    expect(id, matches(facadeUuidV4));
  });

  test('it calls updateDefaultEventProperties', () async {
    final op = await newInitialized();
    op.updateDefaultEventProperties({'tier': 'pro'});
    expect(h.impl(op).defaultEventProperties('token'), {'tier': 'pro'});
  });

  test('it calls updateDefaultUserCustomProperties', () async {
    final op = await newInitialized();
    op.updateDefaultUserCustomProperties({'plan': 'enterprise'});
    await op.track('after');
    expect(userPropsOf(h.queue(op).single), {
      'custom_properties': {'plan': 'enterprise'},
    });
  });

  test('it calls updateDefaultUserConsentProperties', () async {
    final op = await newInitialized();
    op.updateDefaultUserConsentProperties({'marketing': true});
    await op.track('after');
    expect(userPropsOf(h.queue(op).single), {
      'consent': {'marketing': true},
    });
  });
}
