// Port of __tests__/main.test.js (React Native SDK).
//
// The React Native suite constructs `OursPrivacyMain` directly with Jest
// mocks for core, queue, network, persistence and config, and asserts the
// calls made to them (`addToOursPrivacyQueue`, `updateVisitorId`, ...). Dart
// cannot substitute those modules, so each case runs the real modules over
// in-memory storage and asserts the effect of the same call instead:
// - `core.addToOursPrivacyQueue(token, EVENTS, payload)` -> the row in the
//   in-memory event queue;
// - `persistent.updateVisitorId` / `persistVisitorId` -> `getVisitorId` and
//   the stored visitor ID key;
// - `config.setX(token, ...)` -> `OursPrivacyConfig.instance.getX(token)`;
// - `console.log` -> the lines the logger printed.
//
// The mocked persistence in React Native reports "not opted out" before
// `initialize()`, so several RN cases track without initializing. The real
// persistence (in both SDKs) keeps tracking closed until the stored decision
// has loaded, so those ports call [ready] first.
import 'package:flutter_test/flutter_test.dart';
import 'package:ours_privacy/src/config.dart';
import 'package:ours_privacy/src/constants.dart';
import 'package:ours_privacy/src/testing.dart';
import 'package:ours_privacy/src/version.dart';

import 'helpers/facade_harness.dart';

const token = 'test-token';

void main() {
  late FacadeHarness h;
  late FacadeStorage storage;
  late OursPrivacyMain oursprivacyMain;

  OursPrivacyConfig config() => OursPrivacyConfig.instance;

  List<Map<String, Object?>> queued() => h.queueOfMain(oursprivacyMain);

  Map<String, Object?> lastQueued([String? event]) => event == null
      ? queued().last
      : queued().lastWhere((item) => item['event'] == event);

  Future<void> ready([
    OursPrivacyInitOptions options = const OursPrivacyInitOptions(),
  ]) =>
      oursprivacyMain.initialize(token, options);

  setUp(() {
    h = FacadeHarness();
    storage = FacadeStorage();
    oursprivacyMain = h.createMain(token, storage: storage);
  });

  tearDown(() => h.dispose());

  test('should initialize properly', () async {
    const options = OursPrivacyInitOptions(
      serverURL: 'https://api.oursprivacy.com',
      defaultEventProperties: {'superProp1': 'value1', 'superProp2': 'value2'},
    );

    await oursprivacyMain.initialize(token, options);

    // core.initialize(token) loads the stored event queue.
    expect(storage.reads, contains(queueKey(token, eventsQueueType)));
    expect(oursprivacyMain.isInitialized, isTrue);
  });

  test(
      'should override persistent visitor_id when visitorId is provided in '
      'options', () async {
    await oursprivacyMain.initialize(
      token,
      const OursPrivacyInitOptions(
        visitorId: 'preset-visitor-123',
        serverURL: 'https://cdn.oursprivacy.com',
      ),
    );
    expect(oursprivacyMain.getVisitorId(token), 'preset-visitor-123');
    expect(storage.values[visitorIdKey(token)], 'preset-visitor-123');
  });

  test('should preserve init options when starting opted out', () async {
    await oursprivacyMain.initialize(
      token,
      const OursPrivacyInitOptions(
        optOutTrackingByDefault: true,
        serverURL: 'https://api.oursprivacy.com',
        visitorId: 'preset-visitor-123',
        defaultEventProperties: {'platform': 'mobile'},
        defaultUserCustomProperties: {'plan': 'pro'},
        defaultUserConsentProperties: {'marketing': true},
      ),
    );

    expect(config().getServerURL(token), 'https://api.oursprivacy.com');
    expect(oursprivacyMain.hasOptedOutTracking(token), isTrue);
    expect(oursprivacyMain.getVisitorId(token), 'preset-visitor-123');
    expect(oursprivacyMain.defaultEventProperties(token), {
      'platform': 'mobile',
    });
    // The user defaults have no getter; opting in sends `$opt_in`, which
    // carries the preserved default event, custom and consent properties.
    await oursprivacyMain.optInTracking(token);
    final optIn = lastQueued(r'$opt_in');
    expect(eventPropsOf(optIn), containsPair('platform', 'mobile'));
    expect(userPropsOf(optIn), {
      'custom_properties': {'plan': 'pro'},
      'consent': {'marketing': true},
    });
  });

  test('should not track if initialize with optOutTrackingByDefault being true',
      () async {
    await oursprivacyMain.initialize(
      token,
      const OursPrivacyInitOptions(
        optOutTrackingByDefault: true,
        serverURL: 'https://api.oursprivacy.com',
      ),
    );

    const eventName = 'Test Event';
    const eventProperties = {'prop1': 'value1', 'prop2': 'value2'};

    expect(oursprivacyMain.hasOptedOutTracking(token), isTrue);

    await oursprivacyMain.track(token, eventName, eventProperties);
    expect(queued(), isEmpty);
  });

  test('should not fire \$deep_link_opened or store attribution when opted out',
      () async {
    await oursprivacyMain.initialize(
      token,
      const OursPrivacyInitOptions(
        optOutTrackingByDefault: true,
        serverURL: 'https://cdn.oursprivacy.com',
        initialURL:
            'myapp://open?utm_source=google&gclid=abc&ours_visitor_id=web-123',
      ),
    );
    expect(queued(), isEmpty);
    expect(oursprivacyMain.attributionDefaultProperties(token), isEmpty);
    expect(oursprivacyMain.getVisitorId(token), isNot('web-123'));
  });

  test('should track if initialize with optOutTrackingByDefault being false',
      () async {
    await oursprivacyMain.initialize(
      token,
      const OursPrivacyInitOptions(serverURL: 'https://api.oursprivacy.com'),
    );
    oursprivacyMain.setLoggingEnabled(token, true);
    const eventName = 'Test Event';
    const eventProperties = {'prop1': 'value1', 'prop2': 'value2'};

    await oursprivacyMain.track(token, eventName, eventProperties);
    expect(facadeEventNames(queued()), [eventName]);
  });

  test('should send correct payload on track event', () async {
    await ready();
    const eventName = 'Test Event';
    const eventProperties = {'prop1': 'value1', 'prop2': 'value2'};

    await oursprivacyMain.track(token, eventName, eventProperties);
    final row = queued().single;
    expect(row['event'], eventName);
    expect(row['visitor_id'], oursprivacyMain.getVisitorId(token));
    expect(row['distinct_id'], isA<String>());
    expect(eventPropsOf(row), containsPair('prop1', 'value1'));
    expect(eventPropsOf(row), containsPair('prop2', 'value2'));
    final defaults = defaultPropsOf(row);
    expect(defaults['device_type'], 'mobile');
    expect(defaults['os_name'], isA<String>());
    expect(defaults['version'], startsWith('flutter@'));
  });

  test('should trigger the flush on the flush call', () async {
    await oursprivacyMain.initialize(token, const OursPrivacyInitOptions());
    // RN asserts core.flush(token) was called. With the real core, flush is
    // observable once there is a queued event to upload.
    await oursprivacyMain.track(token, 'queued');
    await oursprivacyMain.flush(token);
    expect(h.requests, hasLength(1));
    expect(facadeEventNames(h.sentEvents), ['queued']);
    expect(queued(), isEmpty);
  });

  test('setLoggingEnabled should work as expected', () async {
    await ready();
    oursprivacyMain.setLoggingEnabled(token, true);
    expect(config().getLoggingEnabled(token), isTrue);
    h.printed.clear();
    await oursprivacyMain.track(token, 'test-event');
    expect(h.printed, isNotEmpty);
  });

  test('hasOptedOutTracking should read the persisted opt-out flag', () async {
    await ready();
    oursprivacyMain.persistent.updateOptedOut(token, true);
    expect(oursprivacyMain.hasOptedOutTracking(token), isTrue);
    expect(
      oursprivacyMain.hasOptedOutTracking(token),
      oursprivacyMain.persistent.getOptedOut(token),
    );
  });

  test(
      'optOutTracking should clear queued events without rotating visitor '
      'identity', () async {
    await ready();
    await oursprivacyMain.track(token, 'queued');
    final visitorId = oursprivacyMain.getVisitorId(token);

    await oursprivacyMain.optOutTracking(token);

    expect(queued(), isEmpty);
    expect(
      facadePersistedQueueItems(
          storage.values[queueKey(token, eventsQueueType)]!),
      isEmpty,
    );
    expect(oursprivacyMain.getVisitorId(token), visitorId);
    expect(storage.values[visitorIdKey(token)], visitorId);
  });

  test('optOutTracking should clear attribution and all default properties',
      () async {
    await ready();
    await oursprivacyMain.trackDeepLink(
      token,
      'myapp://open?utm_source=google&gclid=abc',
    );
    oursprivacyMain.updateDefaultEventProperties(token, {'custom': 'val'});
    oursprivacyMain.updateDefaultUserCustomProperties(token, {'plan': 'pro'});
    oursprivacyMain.updateDefaultUserConsentProperties(token, {
      'marketing': true,
    });

    await oursprivacyMain.optOutTracking(token);

    expect(oursprivacyMain.attributionDefaultProperties(token), isEmpty);
    expect(oursprivacyMain.defaultEventProperties(token), isEmpty);
    final dp = oursprivacyMain.getDefaultProperties(token, null);
    expect(dp.containsKey('utm_source'), isFalse);
    // The user defaults have no getter: the `$opt_in` sent after opting back
    // in carries no custom or consent properties.
    await oursprivacyMain.optInTracking(token);
    final optIn = lastQueued(r'$opt_in');
    expect(optIn['userProperties'], isNull);
    expect(eventPropsOf(optIn).containsKey('custom'), isFalse);
    expect(defaultPropsOf(optIn).containsKey('utm_source'), isFalse);
  });

  // RN: 'should be a safe no-op in JavaScript mode'. In Dart it sets the
  // flag the lifecycle handler reads; it must not throw.
  test('setFlushOnBackground should be a safe no-op in JavaScript mode', () {
    expect(
      () => oursprivacyMain.setFlushOnBackground(token, false),
      returnsNormally,
    );
    expect(oursprivacyMain.flushOnBackgroundEnabled, isFalse);
  });

  group('identify', () {
    setUp(() => ready());

    test(
        'sends \$identify with external_id on the wire when caller passes '
        'externalId', () async {
      const externalId = 'new-external-id';
      await oursprivacyMain.identify(token, {'externalId': externalId});
      final row = lastQueued();
      expect(row['event'], r'$identify');
      expect(userPropsOf(row), containsPair('external_id', externalId));
    });

    test('sends the full \$identify payload shape', () async {
      await oursprivacyMain.identify(token, {'externalId': 'new-distinct-id'});
      final row = lastQueued();
      expect(row['event'], r'$identify');
      expect(row['visitor_id'], oursprivacyMain.getVisitorId(token));
      expect(row['distinct_id'], isA<String>());
      expect(eventPropsOf(row), {
        'mobile_contract_version': 1,
        'mobile_occurred_at': isA<String>(),
      });
      expect(
        userPropsOf(row),
        containsPair('external_id', 'new-distinct-id'),
      );
      expect(defaultPropsOf(row), containsPair('device_type', 'mobile'));
    });

    test(
        'merges per-call customProperties on top of default customProperties '
        '(was broken before)', () async {
      oursprivacyMain.updateDefaultUserCustomProperties(token, {
        'plan': 'pro',
        'tier': 'silver',
      });
      await oursprivacyMain.identify(token, {
        'externalId': 'u-1',
        'customProperties': {'tier': 'gold'},
      });
      final row = lastQueued();
      expect(row['event'], r'$identify');
      expect(userPropsOf(row), containsPair('external_id', 'u-1'));
      expect(
        userPropsOf(row),
        containsPair('custom_properties', {'plan': 'pro', 'tier': 'gold'}),
      );
    });

    test(
        'preserves per-call customProperties even when no defaults are set '
        '(fixes the broken guard)', () async {
      await oursprivacyMain.identify(token, {
        'externalId': 'u-2',
        'customProperties': {'tier': 'gold'},
      });
      final row = lastQueued();
      expect(row['event'], r'$identify');
      expect(userPropsOf(row), containsPair('external_id', 'u-2'));
      expect(
        userPropsOf(row),
        containsPair('custom_properties', {'tier': 'gold'}),
      );
    });

    test('preserves per-call consent even when no defaults are set', () async {
      await oursprivacyMain.identify(token, {
        'externalId': 'u-3',
        'consent': {'marketing': true},
      });
      expect(userPropsOf(queued().single), {
        'external_id': 'u-3',
        'consent': {'marketing': true},
      });
    });

    test('translates camelCase typed fields to snake_case on the wire',
        () async {
      await oursprivacyMain.identify(token, {
        'email': 'u@x.com',
        'externalId': 'u-4',
        'phoneNumber': '+15555555555',
        'firstName': 'Ada',
        'lastName': 'Lovelace',
        'dateOfBirth': '1815-12-10',
        'companyName': 'Babbage Ltd',
        'jobTitle': 'Mathematician',
        'gender': 'female',
        'city': 'London',
        'state': 'England',
        'zip': 'NW1',
        'country': 'GB',
        'ip': '203.0.113.1',
      });
      expect(userPropsOf(queued().single), {
        'email': 'u@x.com',
        'external_id': 'u-4',
        'phone_number': '+15555555555',
        'first_name': 'Ada',
        'last_name': 'Lovelace',
        'date_of_birth': '1815-12-10',
        'company_name': 'Babbage Ltd',
        'job_title': 'Mathematician',
        'gender': 'female',
        'city': 'London',
        'state': 'England',
        'zip': 'NW1',
        'country': 'GB',
        'ip': '203.0.113.1',
      });
    });

    test('omits consent when neither defaults nor per-call carry consent',
        () async {
      oursprivacyMain.updateDefaultUserCustomProperties(token, {'plan': 'pro'});
      await oursprivacyMain.identify(token, {'externalId': 'u-5'});
      final user = userPropsOf(queued().single)!;
      expect(user, {
        'external_id': 'u-5',
        'custom_properties': {'plan': 'pro'},
      });
      expect(user.containsKey('consent'), isFalse);
    });
  });

  group('default properties', () {
    setUp(() => ready());

    test('updateDefaultEventProperties should merge into event payload',
        () async {
      oursprivacyMain.updateDefaultEventProperties(token, {'tier': 'pro'});
      await oursprivacyMain.track(token, 'Test Event', {});
      expect(eventPropsOf(lastQueued()), containsPair('tier', 'pro'));
    });

    test('updateDefaultUserCustomProperties should appear in userProperties',
        () async {
      oursprivacyMain.updateDefaultUserCustomProperties(token, {
        'plan': 'enterprise',
      });
      await oursprivacyMain.track(token, 'Test Event', {});
      expect(
        userPropsOf(lastQueued())!['custom_properties'],
        containsPair('plan', 'enterprise'),
      );
    });

    test('updateDefaultUserConsentProperties should appear in userProperties',
        () async {
      oursprivacyMain.updateDefaultUserConsentProperties(token, {
        'marketing': true,
      });
      await oursprivacyMain.track(token, 'Test Event', {});
      expect(
        userPropsOf(lastQueued())!['consent'],
        containsPair('marketing', true),
      );
    });
  });

  group('track with per-call userProperties (CDP parity)', () {
    setUp(() => ready());

    test('sends per-call userProperties on the wire when no defaults set',
        () async {
      await oursprivacyMain.track(
        token,
        'Test Event',
        {},
        {'email': 'u@x.com'},
      );
      expect(userPropsOf(lastQueued()), {'email': 'u@x.com'});
    });

    test(
        'leaves userProperties null when neither defaults nor per-call user '
        'props are present', () async {
      await oursprivacyMain.track(token, 'Test Event', {'prop1': 'v'});
      final row = lastQueued();
      expect(row.containsKey('userProperties'), isTrue);
      expect(row['userProperties'], isNull);
    });

    test(
        'merges per-call customProperties (camelCase) on top of default '
        'custom properties → snake_case on wire', () async {
      oursprivacyMain.updateDefaultUserCustomProperties(token, {
        'plan': 'pro',
        'tier': 'silver',
      });
      await oursprivacyMain.track(token, 'Test Event', {}, {
        'customProperties': {'tier': 'gold'},
      });
      expect(
        userPropsOf(lastQueued()),
        containsPair('custom_properties', {'plan': 'pro', 'tier': 'gold'}),
      );
    });

    test('merges per-call consent on top of default consent properties',
        () async {
      oursprivacyMain.updateDefaultUserConsentProperties(token, {
        'analytics': true,
        'marketing': false,
      });
      await oursprivacyMain.track(token, 'Test Event', {}, {
        'consent': {'marketing': true},
      });
      expect(
        userPropsOf(lastQueued()),
        containsPair('consent', {'analytics': true, 'marketing': true}),
      );
    });

    test(
        'spreads top-level per-call user props (e.g. email) onto '
        'userProperties alongside merged custom_properties', () async {
      oursprivacyMain.updateDefaultUserCustomProperties(token, {'plan': 'pro'});
      await oursprivacyMain.track(token, 'Test Event', {}, {
        'email': 'u@x.com',
        'customProperties': {'tier': 'gold'},
      });
      expect(userPropsOf(lastQueued()), {
        'email': 'u@x.com',
        'custom_properties': {'plan': 'pro', 'tier': 'gold'},
      });
    });

    test(
        'omits consent when neither defaults nor per-call user props carry '
        'consent', () async {
      oursprivacyMain.updateDefaultUserCustomProperties(token, {'plan': 'pro'});
      await oursprivacyMain.track(
        token,
        'Test Event',
        {},
        {'email': 'u@x.com'},
      );
      final user = userPropsOf(queued().single)!;
      expect(user, {
        'email': 'u@x.com',
        'custom_properties': {'plan': 'pro'},
      });
      expect(user.containsKey('consent'), isFalse);
    });
  });

  test('getVisitorId should return the visitor id', () async {
    await ready();
    final visitorId = oursprivacyMain.getVisitorId(token);
    expect(visitorId, matches(facadeUuidV4));
    expect(visitorId, storage.values[visitorIdKey(token)]);
  });

  test('reset should clear default property maps', () async {
    await ready(const OursPrivacyInitOptions(visitorId: 'before-reset'));
    oursprivacyMain.updateDefaultEventProperties(token, {'foo': 'bar'});
    oursprivacyMain.updateDefaultUserCustomProperties(token, {'plan': 'pro'});
    oursprivacyMain.updateDefaultUserConsentProperties(token, {
      'marketing': true,
    });
    expect(config().getIsManuallySetId(token), isTrue);
    await oursprivacyMain.reset(token);
    // persistent.reset(token): a new visitor identity.
    expect(oursprivacyMain.getVisitorId(token), isNot('before-reset'));
    expect(oursprivacyMain.getVisitorId(token), matches(facadeUuidV4));
    // config.setIsManuallySetId(token, false)
    expect(config().getIsManuallySetId(token), isFalse);
    expect(oursprivacyMain.defaultEventProperties(token), isEmpty);
    // The user default maps have no getter: the next event has none.
    await oursprivacyMain.track(token, 'after_reset');
    final row = lastQueued('after_reset');
    expect(row['userProperties'], isNull);
    expect(eventPropsOf(row).containsKey('foo'), isFalse);
  });

  test('getDefaultProperties should include device_type and merge attribution',
      () async {
    await ready();
    final props = oursprivacyMain.getDefaultProperties(token, null);
    expect(props['device_type'], 'mobile');
    await oursprivacyMain.trackDeepLink(token, 'myapp://open?utm_source=test');
    final propsAfter = oursprivacyMain.getDefaultProperties(token, null);
    expect(propsAfter['utm_source'], 'test');
  });

  // RN: 'should report version as react-native@<semver>'.
  test('getDefaultProperties should report version as flutter@<semver>', () {
    final props = oursprivacyMain.getDefaultProperties(token, null);
    expect(props['version'], 'flutter@$oursPrivacySdkVersion');
    expect(oursPrivacySdkVersion, matches(RegExp(r'^\d+\.\d+\.\d+$')));
  });

  group('trackDeepLink', () {
    setUp(() => ready());

    test('should parse UTM params into defaultProperties (not eventProperties)',
        () async {
      await oursprivacyMain.trackDeepLink(
        token,
        'myapp://open?utm_source=google&utm_medium=cpc&utm_campaign=spring',
      );
      expect(oursprivacyMain.attributionDefaultProperties(token), {
        'utm_source': 'google',
        'utm_medium': 'cpc',
        'utm_campaign': 'spring',
      });
      final dp = oursprivacyMain.getDefaultProperties(token, null);
      expect(dp['utm_source'], 'google');
      expect(dp['utm_medium'], 'cpc');
    });

    test('should parse click IDs into defaultProperties', () async {
      await oursprivacyMain.trackDeepLink(
        token,
        'myapp://open?gclid=abc123&fbclid=def456',
      );
      expect(
        oursprivacyMain.attributionDefaultProperties(token),
        allOf(
            containsPair('gclid', 'abc123'), containsPair('fbclid', 'def456')),
      );
    });

    test('should parse AppLovin params (aleid, alart) into defaultProperties',
        () async {
      await oursprivacyMain.trackDeepLink(
        token,
        'myapp://open?aleid=click_123&alart=user_456',
      );
      expect(
        oursprivacyMain.attributionDefaultProperties(token),
        allOf(
          containsPair('aleid', 'click_123'),
          containsPair('alart', 'user_456'),
        ),
      );
    });

    test('fires \$deep_link_opened without a URL property', () async {
      await oursprivacyMain.trackDeepLink(
        token,
        'myapp://open?utm_source=email&gclid=xyz',
      );
      final eventData = lastQueued(r'$deep_link_opened');
      expect(eventPropsOf(eventData), {
        'mobile_contract_version': 1,
        'mobile_occurred_at': isA<String>(),
      });
      expect(
        defaultPropsOf(eventData),
        allOf(
            containsPair('utm_source', 'email'), containsPair('gclid', 'xyz')),
      );
    });

    test('keeps sensitive link fields out of captured events and diagnostics',
        () async {
      const url =
          'https://example.test/open?ours_visitor_id=web-123&utm_source=campaign&gclid=click-123&patient_email=private%40example.test';
      // RN's mocked config reports logging enabled.
      oursprivacyMain.setLoggingEnabled(token, true);
      oursprivacyMain.updateDefaultEventProperties(token, {
        'url': 'customer-default-url',
      });

      await oursprivacyMain.trackDeepLink(token, url);
      await oursprivacyMain.track(token, 'appointment_booked', {
        'appointment_id': 'appointment-1',
      });

      final deepLink = lastQueued(r'$deep_link_opened');
      final booked = lastQueued('appointment_booked');
      expect(oursprivacyMain.getVisitorId(token), 'web-123');
      expect(eventPropsOf(deepLink), {
        'mobile_contract_version': 1,
        'mobile_occurred_at': isA<String>(),
      });
      expect(
        defaultPropsOf(deepLink),
        allOf(
          containsPair('utm_source', 'campaign'),
          containsPair('gclid', 'click-123'),
        ),
      );
      expect(
        defaultPropsOf(booked),
        allOf(
          containsPair('utm_source', 'campaign'),
          containsPair('gclid', 'click-123'),
        ),
      );
      final wire = deepLink.toString();
      final logs = [...h.printed, ...h.logs].join('\n');
      expect(wire, isNot(contains(url)));
      expect(wire, isNot(contains('patient_email')));
      expect(logs, isNot(contains(url)));
      expect(logs, isNot(contains('patient_email')));
    });

    test('should replace (not merge) attribution on subsequent deep links',
        () async {
      await oursprivacyMain.trackDeepLink(
        token,
        'myapp://open?utm_campaign=spring&gclid=abc',
      );
      expect(oursprivacyMain.attributionDefaultProperties(token), {
        'utm_campaign': 'spring',
        'gclid': 'abc',
      });

      await oursprivacyMain.trackDeepLink(
        token,
        'myapp://open?utm_source=email',
      );
      expect(oursprivacyMain.attributionDefaultProperties(token), {
        'utm_source': 'email',
      });
      final dp = oursprivacyMain.getDefaultProperties(token, null);
      expect(dp.containsKey('utm_campaign'), isFalse);
      expect(dp.containsKey('gclid'), isFalse);
      expect(dp['utm_source'], 'email');
    });

    test('should update visitor_id when ours_visitor_id is in the URL',
        () async {
      await oursprivacyMain.trackDeepLink(
        token,
        'myapp://open?ours_visitor_id=web-uuid-123&utm_source=email',
      );
      expect(oursprivacyMain.getVisitorId(token), 'web-uuid-123');
      expect(storage.values[visitorIdKey(token)], 'web-uuid-123');
      expect(config().getIsManuallySetId(token), isTrue);
    });

    test('should not update visitor_id when ours_visitor_id is absent',
        () async {
      final before = oursprivacyMain.getVisitorId(token);
      await oursprivacyMain.trackDeepLink(
        token,
        'myapp://open?utm_source=google',
      );
      expect(oursprivacyMain.getVisitorId(token), before);
      expect(storage.values[visitorIdKey(token)], before);
      expect(config().getIsManuallySetId(token), isFalse);
    });

    // `trackDeepLink(token, String url)`: null and undefined are compile-time
    // errors in Dart, so only the empty URL ports.
    test('should be a no-op for null/undefined/empty URL', () async {
      await oursprivacyMain.trackDeepLink(token, '');
      expect(queued(), isEmpty);
    });

    test('should be a complete no-op when opted out', () async {
      final before = oursprivacyMain.getVisitorId(token);
      oursprivacyMain.persistent.updateOptedOut(token, true);
      await oursprivacyMain.trackDeepLink(
        token,
        'myapp://open?utm_source=google&gclid=abc&ours_visitor_id=web-123',
      );
      expect(queued(), isEmpty);
      expect(oursprivacyMain.attributionDefaultProperties(token), isEmpty);
      expect(oursprivacyMain.getVisitorId(token), before);
      expect(config().getIsManuallySetId(token), isFalse);
    });

    test('should handle URL with no attribution params', () async {
      await oursprivacyMain.trackDeepLink(token, 'myapp://open');
      final row = lastQueued();
      expect(row['event'], r'$deep_link_opened');
      expect(eventPropsOf(row), {
        'mobile_contract_version': 1,
        'mobile_occurred_at': isA<String>(),
      });
    });
  });

  group('setVisitorId', () {
    test('should update visitor_id and set is_manually_set_id', () async {
      await ready();
      await oursprivacyMain.setVisitorId(token, 'new-visitor-id');
      expect(oursprivacyMain.getVisitorId(token), 'new-visitor-id');
      expect(storage.values[visitorIdKey(token)], 'new-visitor-id');
      expect(config().getIsManuallySetId(token), isTrue);
    });
  });

  group('initialURL init option', () {
    test('should parse deep link on init when initialURL is provided',
        () async {
      await oursprivacyMain.initialize(
        token,
        const OursPrivacyInitOptions(
          initialURL: 'myapp://open?utm_source=google&aleid=click_abc',
          serverURL: 'https://cdn.oursprivacy.com',
        ),
      );
      expect(
        oursprivacyMain.attributionDefaultProperties(token),
        allOf(
          containsPair('utm_source', 'google'),
          containsPair('aleid', 'click_abc'),
        ),
      );
      expect(facadeEventNames(queued()), contains(r'$deep_link_opened'));
    });

    test('should handle both visitorId and initialURL in init options',
        () async {
      await oursprivacyMain.initialize(
        token,
        const OursPrivacyInitOptions(
          visitorId: 'explicit-visitor-id',
          initialURL:
              'myapp://open?utm_source=google&ours_visitor_id=url-visitor-id',
          serverURL: 'https://cdn.oursprivacy.com',
        ),
      );
      // visitorId option is applied first, then initialURL overrides with
      // ours_visitor_id
      expect(oursprivacyMain.getVisitorId(token), 'url-visitor-id');
      expect(storage.values[visitorIdKey(token)], 'url-visitor-id');
    });
  });

  test('reset should clear attribution from defaultProperties', () async {
    await ready();
    await oursprivacyMain.trackDeepLink(
      token,
      'myapp://open?utm_source=google&gclid=abc',
    );
    expect(
      oursprivacyMain.attributionDefaultProperties(token),
      allOf(containsPair('utm_source', 'google'), containsPair('gclid', 'abc')),
    );
    await oursprivacyMain.reset(token);
    expect(oursprivacyMain.attributionDefaultProperties(token), isEmpty);
    final dp = oursprivacyMain.getDefaultProperties(token, null);
    expect(dp.containsKey('utm_source'), isFalse);
  });
}
