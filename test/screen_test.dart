// Port of __tests__/screen.test.js (React Native SDK).
//
// `queued()` reads the in-memory event queue; `settle()` stands in for
// `await op.oursprivacyImpl._pendingOperation` (the operation chain is
// private in Dart, so the harness lets every pending microtask run).
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ours_privacy/ours_privacy.dart';
import 'package:ours_privacy/src/testing.dart';
import 'package:ours_privacy/src/version.dart';

import 'helpers/facade_harness.dart';

late FacadeHarness h;
var _tokenIndex = 0;
late String token;
late OursPrivacy _op;

List<Map<String, Object?>> queued() => h.queue(_op);

List<Map<String, Object?>> screenEvents() => queued()
    .where((event) => event['event'] == r'$mobile_screen_view')
    .toList();

Future<void> settle() => facadeSettle();

OursPrivacy newOp() => _op = h.create();

/// Warning lines the logger printed (RN `console.warn` calls). Printing only
/// happens when logging is enabled for the token.
List<String> printedWarnings() => h.printed
    .where((line) => line.startsWith('[OursPrivacy] warning:'))
    .toList();

void main() {
  setUp(() {
    token = 'screen-token-${++_tokenIndex}';
    h = FacadeHarness();
  });

  tearDown(() => h.dispose());

  test(
      'a public screen call queues the exact canonical payload and '
      'configured host version', () async {
    final op = newOp();
    await op.init(
      token,
      storage: InMemoryStorage(),
      appVersion: '2.0.0',
      appBuild: '42',
      defaultEventProperties: {'campaign': 'excluded'},
      defaultUserCustomProperties: {'tier': 'excluded'},
    );

    unawaited(op.trackScreen('Schedule'));
    await settle();

    final view = screenEvents().first;
    expect(queued(), hasLength(1));
    // Device fields are the Flutter SDK's (StaticDeviceInfo.ios): RN's
    // jest mock reports os_version 'undefined', `react-native@<version>` and
    // no device_model.
    expect(view, {
      'event': r'$mobile_screen_view',
      'visitor_id': isA<String>(),
      'distinct_id': isA<String>(),
      'eventProperties': {
        'screen_name': 'Schedule',
        'mobile_contract_version': 1,
        'mobile_occurred_at': '2026-10-05T12:00:00.000Z',
        'app_version': '2.0.0',
        'app_build': '42',
      },
      'isManuallySetId': false,
      'userProperties': null,
      'defaultProperties': {
        'device_type': 'mobile',
        'os_name': 'iOS',
        'os_version': '17.5',
        'version': 'flutter@$oursPrivacySdkVersion',
        'screen_width': 375,
        'screen_height': 812,
        'device_vendor': 'Apple',
        'device_model': 'iPhone15,2',
        'sid': '1791201600000',
      },
    });
  });

  test('duplicate calls for the same visible screen queue one view', () async {
    final op = newOp();
    await op.init(token, storage: InMemoryStorage());

    unawaited(op.trackScreen('Schedule'));
    unawaited(op.trackScreen('Schedule'));
    await settle();

    expect(screenEvents(), hasLength(1));
  });

  for (final loggingEnabled in [true, false]) {
    group('invalid screen labels with logging enabled: $loggingEnabled', () {
      // RN also passes 123, null and undefined; `trackScreen(String)` makes
      // those compile-time errors in Dart, so only the string labels port.
      for (final label in [
        '',
        '   ',
        ' Schedule',
        'Schedule ',
        'Schedule\n',
        'Patient/123',
        'Patient?name=1',
        'Patiént',
        '123',
        'A' * 81,
      ]) {
        test('drops ${_describe(label)} without changing the active screen',
            () async {
          final op = newOp();
          await op.init(token, storage: InMemoryStorage());
          await op.trackScreen('Home');
          final before = [...queued()];
          op.setLoggingEnabled(loggingEnabled);
          h.printed.clear();

          await expectLater(op.trackScreen(label), completes);
          await settle();
          expect(queued(), before);

          final warnings = printedWarnings();
          if (loggingEnabled) {
            expect(warnings, hasLength(1));
            final message = warnings.single;
            expect(message, contains('trackScreen'));
            expect(message.toLowerCase(), contains('invalid screen label'));
            expect(message, isNot(contains(token)));
            if (label.isNotEmpty) {
              expect(message, isNot(contains(label)));
            }
          } else {
            expect(warnings, isEmpty);
          }

          op.setLoggingEnabled(false);
          await op.trackScreen('Home');
          expect(queued(), before);
          await op.trackScreen('Schedule');
          expect(
            screenEvents().map((event) => eventPropsOf(event)['screen_name']),
            ['Home', 'Schedule'],
          );
        });
      }
    });
  }

  for (final label in ['A', 'A${'b' * 79}', 'Visit_Details-1']) {
    test('accepts the valid screen label ${_describe(label)}', () async {
      final op = newOp();
      await op.init(token, storage: InMemoryStorage());
      await op.trackScreen(label);

      expect(screenEvents(), hasLength(1));
      expect(eventPropsOf(screenEvents()[0])['screen_name'], label);
    });
  }

  test('a screen change attributes elapsed engagement to the previous screen',
      () async {
    final op = newOp();
    await op.init(token,
        storage: InMemoryStorage(), trackAutomaticEvents: true);

    unawaited(op.trackScreen('Home'));
    await settle();
    await h.clock.advance(4000);
    await op.trackScreen('Home/123');
    await op.trackScreen('Home');
    unawaited(op.trackScreen('Schedule'));
    await settle();

    final events = queued();
    expect(
      facadeEventNames(events.sublist(events.length - 3)),
      [
        r'$mobile_screen_view',
        r'$mobile_session_engagement',
        r'$mobile_screen_view',
      ],
    );
    final engagement = events[events.length - 2];
    final schedule = events[events.length - 1];
    expect(eventPropsOf(engagement), {
      'engagement_duration_ms': 4000,
      'screen_name': 'Home',
      'mobile_contract_version': 1,
      'mobile_occurred_at': '2026-10-05T12:00:04.000Z',
    });
    expect(defaultPropsOf(engagement)['sid'], defaultPropsOf(schedule)['sid']);
    expect(eventPropsOf(schedule), {
      'screen_name': 'Schedule',
      'mobile_contract_version': 1,
      'mobile_occurred_at': '2026-10-05T12:00:04.000Z',
    });
    expect(
      screenEvents().map((event) => eventPropsOf(event)['screen_name']),
      ['Home', 'Schedule'],
    );
  });

  test(
      'manual screens work with automatic events off without lifecycle or '
      'engagement facts', () async {
    final op = newOp();
    await op.init(token, storage: InMemoryStorage());

    unawaited(op.trackScreen('Home'));
    await settle();
    await h.clock.advance(4000);
    unawaited(op.trackScreen('Schedule'));
    await settle();

    expect(facadeEventNames(queued()), [
      r'$mobile_screen_view',
      r'$mobile_screen_view',
    ]);
  });

  test('full tracking opt-out suppresses explicit screens', () async {
    final op = newOp();
    await op.init(
      token,
      storage: InMemoryStorage(),
      trackAutomaticEvents: true,
      optOutTrackingByDefault: true,
    );

    unawaited(op.trackScreen('Schedule'));
    await settle();

    expect(queued(), isEmpty);
  });

  // RN: 'React Native web does not emit a mobile screen event'.
  test('Flutter web does not emit a mobile screen event', () async {
    h.device = const StaticDeviceInfo.web();
    final op = newOp();
    await op.init(token, storage: InMemoryStorage());

    unawaited(op.trackScreen('Home'));
    await settle();

    expect(queued(), isEmpty);
  });
}

String _describe(String label) {
  final escaped = label.replaceAll('\n', r'\n');
  return label.length > 20
      ? "'${escaped.substring(0, 6)}…' (${label.length} chars)"
      : "'$escaped'";
}
