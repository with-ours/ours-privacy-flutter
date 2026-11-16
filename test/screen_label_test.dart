// trackScreen label validation (React Native `index.js` trackScreen, iOS
// `OursPrivacyInstance.swift`, Android `OursPrivacyAPI.java`): a label must
// match `^[A-Za-z][A-Za-z0-9 _-]{0,79}$` with no trailing whitespace. An
// invalid label logs one warning with the exact React Native message, never
// throws, queues nothing and sends nothing.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ours_privacy/ours_privacy.dart';

import 'helpers/facade_harness.dart';

const _warning =
    'trackScreen ignored an invalid screen label. Use 1-80 ASCII characters '
    'starting with a letter, containing only letters, digits, spaces, '
    'underscores, or hyphens, with no trailing whitespace.';

const _token = 'screen-label-token';

final Map<String, String> _valid = {
  'single letter': 'A',
  'lower-case letter': 'z',
  '80 characters': 'A${'b' * 79}',
  'digits after the first letter': 'Step2',
  'inner space': 'Visit Details',
  'underscore': 'Visit_Details',
  'hyphen': 'Visit-Details',
  'mixed allowed punctuation': 'Visit_Details-1 Final',
  'trailing digit': 'Screen9',
  'trailing underscore': 'Screen_',
  'trailing hyphen': 'Screen-',
  'consecutive spaces inside': 'Home  Page',
};

final Map<String, String> _invalid = {
  'empty': '',
  'single space': ' ',
  'only spaces': '   ',
  '81 characters': 'A${'b' * 80}',
  '120 characters': 'A' * 120,
  'leading digit': '1Home',
  'only digits': '123',
  'leading underscore': '_Home',
  'leading hyphen': '-Home',
  'leading space': ' Home',
  'trailing space': 'Home ',
  'trailing tab': 'Home\t',
  'trailing newline': 'Home\n',
  'inner tab': 'Home\tPage',
  'inner newline': 'Home\nPage',
  'slash': 'Patient/123',
  'query string': 'Patient?name=1',
  'dot': 'Home.Page',
  'colon': 'Home:Page',
  'at sign': 'user@example',
  'ampersand': 'Terms&Conditions',
  'parentheses': 'Home(1)',
  'hash': 'Home#top',
  'percent': 'Sale%50',
  'apostrophe': "Doctor's Notes",
  'accented letter': 'Patiént',
  'non-Latin letters': 'ホーム',
  'emoji': 'Home😀',
  'leading emoji': '😀Home',
  'non-breaking space': 'Home Page',
  'trailing non-breaking space': 'Home ',
  'zero-width space': 'Home​Page',
};

void main() {
  late FacadeHarness h;
  late OursPrivacy op;

  setUp(() async {
    h = FacadeHarness();
    h.respond = facadeIndexedSuccess;
    op = h.create();
    await op.init(_token, storage: InMemoryStorage());
  });

  tearDown(() => h.dispose());

  test('the label table covers the documented boundaries', () {
    expect(_valid['80 characters']!.length, 80);
    expect(_invalid['81 characters']!.length, 81);
  });

  for (final MapEntry(key: name, value: label) in _valid.entries) {
    test('accepts a valid label: $name', () async {
      await op.trackScreen(label);
      await op.flush();

      final sent = h.sentEvents;
      expect(facadeEventNames(sent), [r'$mobile_screen_view']);
      expect(eventPropsOf(sent.single)['screen_name'], label);
      expect(
        h.logs.where((line) => line.startsWith('warning:')),
        isEmpty,
      );
    });
  }

  for (final MapEntry(key: name, value: label) in _invalid.entries) {
    test('rejects an invalid label with a warning and sends nothing: $name',
        () async {
      // Never throws, and the returned future completes normally.
      late Future<void> result;
      expect(() => result = op.trackScreen(label), returnsNormally);
      await expectLater(result, completes);
      await op.flush();

      expect(h.queue(op), isEmpty);
      expect(h.requests, isEmpty);
      expect(
        h.logs.where((line) => line.startsWith('warning:')),
        ['warning: $_warning'],
      );
    });
  }

  test('an invalid label does not replace the active screen', () async {
    await op.trackScreen('Home');
    await op.trackScreen('Home/123');
    await op.trackScreen('Home');
    await op.trackScreen('Schedule');
    await op.flush();

    expect(
      h.sentEvents.map((event) => eventPropsOf(event)['screen_name']),
      ['Home', 'Schedule'],
    );
  });

  test('the warning is printed only when logging is enabled', () async {
    await op.trackScreen('1 bad label');
    expect(h.printed, isEmpty);

    op.setLoggingEnabled(true);
    await op.trackScreen('1 bad label');
    expect(
      h.printed.where((line) => line.contains('trackScreen')),
      ['[OursPrivacy] warning: $_warning'],
    );
  });

  test('un-awaited invalid labels never reach the zone error handler',
      () async {
    // The documented NavigatorObserver usage calls trackScreen un-awaited.
    for (final label in _invalid.values) {
      unawaited(op.trackScreen(label));
    }
    await facadeSettle();
    expect(h.queue(op), isEmpty);
  });
}
