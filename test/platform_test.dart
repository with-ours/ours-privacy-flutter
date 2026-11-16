// Platform gating (React Native `screen.test.js` "web does
// not emit a mobile screen event" and `integration.test.js` "keeps web
// events outside the mobile contract"): only an iOS or Android app build is
// a mobile platform. A Flutter web build (even in a mobile browser) or a
// desktop build sends no `sid`, no mobile metadata (`mobile_contract_version`,
// `mobile_occurred_at`, `app_version`, `app_build`, `engagement_duration_ms`)
// and no `$mobile_*` lifecycle, screen or engagement events, while ordinary
// events, attribution and the background flush keep working.
import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter_test/flutter_test.dart';
import 'package:ours_privacy/ours_privacy.dart';
import 'package:ours_privacy/src/device_info.dart' show PlatformDeviceInfo;
import 'package:ours_privacy/src/testing.dart';

import 'helpers/facade_harness.dart';

const _token = 'platform-token';

const _mobileEventPropertyKeys = [
  'mobile_contract_version',
  'mobile_occurred_at',
  'app_version',
  'app_build',
  'engagement_duration_ms',
  'screen_name',
  'previous_app_version',
];

final Map<String, OursPrivacyDeviceInfo> _nonMobile = {
  'web': const StaticDeviceInfo.web(),
  'web with a phone-sized screen':
      const StaticDeviceInfo.web(screenSize: (width: 390.0, height: 844.0)),
  'macOS': const StaticDeviceInfo(os: OursPrivacyOS.macos, osVersion: '15.0'),
  'Windows': const StaticDeviceInfo(os: OursPrivacyOS.windows),
  'Linux': const StaticDeviceInfo(os: OursPrivacyOS.linux),
  'Fuchsia': const StaticDeviceInfo(os: OursPrivacyOS.fuchsia),
};

final Map<String, OursPrivacyDeviceInfo> _mobile = {
  'iOS': const StaticDeviceInfo.ios(),
  'Android': const StaticDeviceInfo.android(),
};

/// Drives one full session through every public entry point and the
/// lifecycle, then flushes. Returns the instance.
Future<OursPrivacy> _exercise(FacadeHarness h) async {
  h.suspendPeriodicNetworkFlush(_token);
  h.respond = facadeIndexedSuccess;
  final op = h.create();
  await op.init(
    _token,
    storage: InMemoryStorage(),
    trackAutomaticEvents: true,
    appVersion: '2.0.0',
    appBuild: '42',
    initialURL: 'myapp://open?utm_source=email&gclid=click-1',
  );
  op.setFlushOnBackground(false);
  await op.trackScreen('Home');
  await h.clock.advance(4000);
  await op.trackScreen('Schedule');
  await op.track('clicked', {'button': 'buy'});
  await op.identify({'externalId': 'user-1'});
  await op.trackDeepLink('myapp://open?utm_campaign=spring');
  // Checkpoint interval, then inactive / background / foreground cycles.
  await h.clock.advance(15000);
  h.appState.emit(OursAppState.inactive);
  await facadeSettle();
  h.appState.emit(OursAppState.resumed);
  await facadeSettle();
  for (final state in [
    OursAppState.inactive,
    OursAppState.hidden,
    OursAppState.paused,
  ]) {
    h.appState.emit(state);
    await facadeSettle();
  }
  await h.clock.advance(31 * 60 * 1000);
  for (final state in [
    OursAppState.hidden,
    OursAppState.inactive,
    OursAppState.resumed,
  ]) {
    h.appState.emit(state);
    await facadeSettle();
  }
  await h.clock.advance(12000);
  await op.setVisitorId('visitor-2');
  await op.reset();
  await op.track('after_reset');
  await op.flush();
  return op;
}

void main() {
  late FacadeHarness h;

  tearDown(() => h.dispose());

  for (final MapEntry(key: name, value: device) in _nonMobile.entries) {
    group('$name builds', () {
      setUp(() => h = FacadeHarness(device: device));

      test('send no sid, no mobile metadata and no lifecycle events', () async {
        final op = await _exercise(h);
        final sent = h.sentEvents;

        expect(facadeEventNames(sent), [
          r'$deep_link_opened',
          'clicked',
          r'$identify',
          r'$deep_link_opened',
          'after_reset',
        ]);
        for (final item in sent) {
          final event = item['event']! as String;
          expect(event, isNot(startsWith(r'$mobile_')));
          final defaults = defaultPropsOf(item);
          expect(defaults.containsKey('sid'), isFalse, reason: event);
          expect(defaults['os_name'], device.os, reason: event);
          expect(defaults['device_type'], 'mobile', reason: event);
          final eventProperties = facadeSection(item, 'eventProperties');
          for (final key in _mobileEventPropertyKeys) {
            expect(eventProperties?.containsKey(key) ?? false, isFalse,
                reason: '$event.$key');
          }
        }
        // Ordinary events and link attribution still work.
        expect(eventPropsOf(sent[1]), {'button': 'buy'});
        expect(sent[0]['eventProperties'], isNull);
        expect(defaultPropsOf(sent[0])['utm_source'], 'email');
        expect(defaultPropsOf(sent[1])['gclid'], 'click-1');
        expect(defaultPropsOf(sent[3])['utm_campaign'], 'spring');

        // No engagement checkpoint runs off-mobile.
        expect(h.impl(op).hasCheckpointTimer, isFalse);
      });

      test('the batch identity follows the visitor, as on mobile', () async {
        await _exercise(h);
        expect(
          h.bodies.map((body) => body['is_manually_set_id']),
          everyElement(isA<bool>()),
        );
        final last = h.sentEvents.last;
        expect(last['event'], 'after_reset');
        expect(last['visitor_id'], matches(facadeUuidV4));
      });

      test('still flush when the app is hidden', () async {
        final op = h.create();
        await op.init(_token, storage: InMemoryStorage());
        await op.track('queued');
        h.appState.emit(OursAppState.inactive);
        h.appState.emit(OursAppState.hidden);
        await h.waitForRequests(1);
        expect(facadeEventNames(h.sentEvents), ['queued']);
      });

      test('trackScreen is a silent no-op, even for a valid label', () async {
        final op = h.create();
        await op.init(
          _token,
          storage: InMemoryStorage(),
          trackAutomaticEvents: true,
        );
        await op.trackScreen('Home');
        await op.flush();
        expect(h.queue(op), isEmpty);
        expect(h.requests, isEmpty);
        expect(h.logs.where((line) => line.startsWith('warning:')), isEmpty);
      });
    });
  }

  // Positive controls: the same session on a mobile platform does carry the
  // mobile contract, so the assertions above are not vacuous.
  for (final MapEntry(key: name, value: device) in _mobile.entries) {
    group('$name builds', () {
      setUp(() => h = FacadeHarness(device: device));

      test('send sid, mobile metadata and lifecycle events', () async {
        await _exercise(h);
        final sent = h.sentEvents;
        final names = facadeEventNames(sent);
        expect(names, contains(r'$mobile_first_open'));
        expect(names, contains(r'$mobile_app_open'));
        expect(names, contains(r'$mobile_session_start'));
        expect(names, contains(r'$mobile_screen_view'));
        expect(names, contains(r'$mobile_session_engagement'));
        expect(names, contains(r'$mobile_session_end'));
        for (final item in sent) {
          final event = item['event']! as String;
          final defaults = defaultPropsOf(item);
          expect(defaults['sid'], matches(RegExp(r'^\d{13}$')), reason: event);
          expect(defaults['os_name'], device.osName, reason: event);
          final props = eventPropsOf(item);
          expect(props['mobile_contract_version'], 1, reason: event);
          expect(props['mobile_contract_version'], isA<int>(), reason: event);
          expect(
            props['mobile_occurred_at'],
            matches(RegExp(r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$')),
            reason: event,
          );
          expect(
            int.parse(defaults['sid']! as String),
            lessThanOrEqualTo(
              DateTime.parse(props['mobile_occurred_at']! as String)
                  .millisecondsSinceEpoch,
            ),
            reason: event,
          );
          expect(item['distinct_id'], matches(facadeUuidV4), reason: event);
        }
      });
    });
  }

  group('the real platform gate', () {
    setUp(() => h = FacadeHarness());

    tearDown(() => debugDefaultTargetPlatformOverride = null);

    for (final (target, mobile) in [
      (TargetPlatform.iOS, true),
      (TargetPlatform.android, true),
      (TargetPlatform.macOS, false),
      (TargetPlatform.windows, false),
      (TargetPlatform.linux, false),
      (TargetPlatform.fuchsia, false),
    ]) {
      test('${target.name} is ${mobile ? '' : 'not '}a mobile platform', () {
        debugDefaultTargetPlatformOverride = target;
        final info = PlatformDeviceInfo();
        expect(info.isMobilePlatform, mobile);
        expect(
          info.defaultProperties()['os_name'],
          switch (target) {
            TargetPlatform.iOS => 'iOS',
            TargetPlatform.android => 'Android',
            _ => target.name.toLowerCase(),
          },
        );
      });
    }
  });
}
