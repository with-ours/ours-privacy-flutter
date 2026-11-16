// Port of __tests__/attribution.test.js (React Native SDK), plus coverage of
// every UTM parameter and click ID in schema.dart, `+` and percent decoding,
// fragments, empty values and `ours_visitor_id`, both in the parser and on
// the wire through `trackDeepLink`.
import 'package:flutter_test/flutter_test.dart';
import 'package:ours_privacy/ours_privacy.dart';
import 'package:ours_privacy/src/attribution.dart';
import 'package:ours_privacy/src/schema.dart' as schema;

import 'helpers/facade_harness.dart';

void main() {
  group('parseAttributionFromURL', () {
    test('should parse all UTM parameters', () {
      const url =
          'myapp://open?utm_source=google&utm_medium=cpc&utm_campaign=spring_sale&utm_content=banner_1&utm_term=analytics+sdk';
      final result = parseAttributionFromURL(url);
      expect(result.utmParams, {
        'utm_source': 'google',
        'utm_medium': 'cpc',
        'utm_campaign': 'spring_sale',
        'utm_content': 'banner_1',
        'utm_term': 'analytics sdk',
      });
      expect(result.clickIds, isNull);
      expect(result.oursVisitorId, isNull);
    });

    test('should parse click IDs', () {
      const url = 'myapp://open?gclid=abc123&fbclid=def456&ttclid=ghi789';
      final result = parseAttributionFromURL(url);
      expect(result.clickIds, {
        'gclid': 'abc123',
        'fbclid': 'def456',
        'ttclid': 'ghi789',
      });
      expect(result.utmParams, isNull);
    });

    test('should parse AppLovin-specific params', () {
      const url = 'myapp://open?aleid=click_123&alart=user_456';
      final result = parseAttributionFromURL(url);
      expect(result.clickIds, {'aleid': 'click_123', 'alart': 'user_456'});
    });

    test('should parse ours_visitor_id for cross-platform identity', () {
      const url =
          'myapp://open?ours_visitor_id=550e8400-e29b-41d4-a716-446655440000&utm_source=email';
      final result = parseAttributionFromURL(url);
      expect(result.oursVisitorId, '550e8400-e29b-41d4-a716-446655440000');
      expect(result.utmParams, {'utm_source': 'email'});
    });

    test('keeps patient fields outside the attribution allowlist', () {
      final result = parseAttributionFromURL(
        'https://example.test/open?ours_visitor_id=web-123&utm_source=campaign&gclid=click-123&patient_email=private%40example.test',
      );
      expect(result.oursVisitorId, 'web-123');
      expect(result.utmParams, {'utm_source': 'campaign'});
      expect(result.clickIds, {'gclid': 'click-123'});
    });

    test('should return rawURL', () {
      const url = 'myapp://open?utm_source=google';
      final result = parseAttributionFromURL(url);
      expect(result.rawURL, url);
    });

    test('should handle URL with no query params', () {
      const url = 'myapp://open';
      final result = parseAttributionFromURL(url);
      expect(result.utmParams, isNull);
      expect(result.clickIds, isNull);
      expect(result.oursVisitorId, isNull);
      expect(result.rawURL, url);
    });

    test('should handle URL with fragment after query params', () {
      const url = 'myapp://open?utm_source=google&gclid=abc#section';
      final result = parseAttributionFromURL(url);
      expect(result.utmParams, {'utm_source': 'google'});
      expect(result.clickIds, {'gclid': 'abc'});
    });

    test('should handle https URLs', () {
      const url =
          'https://example.com/app?utm_source=facebook&utm_medium=social&fbclid=xyz';
      final result = parseAttributionFromURL(url);
      expect(result.utmParams, {
        'utm_source': 'facebook',
        'utm_medium': 'social',
      });
      expect(result.clickIds, {'fbclid': 'xyz'});
    });

    test('should decode URI-encoded values', () {
      const url =
          'myapp://open?utm_campaign=spring%20sale%202026&utm_source=g%C3%B6ogle';
      final result = parseAttributionFromURL(url);
      expect(result.utmParams, {
        'utm_campaign': 'spring sale 2026',
        'utm_source': 'göogle',
      });
    });

    test('should handle malformed encoding gracefully', () {
      const url = 'myapp://open?utm_source=%E0%A4%A';
      final result = parseAttributionFromURL(url);
      // Should not throw, should return the raw value
      expect(result.utmParams, isNotNull);
      expect(result.utmParams!['utm_source'], isNotNull);
    });

    test('should ignore empty param values', () {
      const url = 'myapp://open?utm_source=&utm_medium=cpc&gclid=';
      final result = parseAttributionFromURL(url);
      expect(result.utmParams, {'utm_medium': 'cpc'});
      expect(result.clickIds, isNull);
    });

    test('should ignore params without = sign', () {
      const url = 'myapp://open?utm_source=google&orphan_key&utm_medium=cpc';
      final result = parseAttributionFromURL(url);
      expect(result.utmParams, {'utm_source': 'google', 'utm_medium': 'cpc'});
    });

    test('should handle null input', () {
      final result = parseAttributionFromURL(null);
      expect(result.utmParams, isNull);
      expect(result.clickIds, isNull);
      expect(result.oursVisitorId, isNull);
      expect(result.rawURL, '');
    });

    // Dart has no `undefined`; an unassigned nullable variable is null.
    test('should handle undefined input', () {
      String? url;
      final result = parseAttributionFromURL(url);
      expect(result.utmParams, isNull);
      expect(result.clickIds, isNull);
      expect(result.oursVisitorId, isNull);
      expect(result.rawURL, '');
    });

    test('should handle empty string input', () {
      final result = parseAttributionFromURL('');
      expect(result.utmParams, isNull);
      expect(result.clickIds, isNull);
      expect(result.oursVisitorId, isNull);
      expect(result.rawURL, '');
    });

    test('should parse a complex real-world deep link', () {
      const url =
          'myapp://products/123?utm_source=applovin&utm_medium=cpc&utm_campaign=retarget_q1&aleid=click_abc&alart=user_xyz&ours_visitor_id=web-uuid-123&gclid=google_click';
      final result = parseAttributionFromURL(url);
      expect(result.utmParams, {
        'utm_source': 'applovin',
        'utm_medium': 'cpc',
        'utm_campaign': 'retarget_q1',
      });
      expect(result.clickIds, {
        'aleid': 'click_abc',
        'alart': 'user_xyz',
        'gclid': 'google_click',
      });
      expect(result.oursVisitorId, 'web-uuid-123');
    });

    test('should export UTM_PARAMS list from schema', () {
      expect(utmParams, contains('utm_source'));
      expect(utmParams, contains('utm_medium'));
      expect(utmParams, contains('utm_campaign'));
      expect(utmParams, contains('utm_content'));
      expect(utmParams, contains('utm_term'));
    });

    test('should export CLICK_IDS list from schema including AppLovin params',
        () {
      expect(clickIds, contains('gclid'));
      expect(clickIds, contains('fbclid'));
      expect(clickIds, contains('ttclid'));
      expect(clickIds, contains('aleid'));
      expect(clickIds, contains('alart'));
      expect(clickIds, contains('msclkid'));
      // These come from the server schema, not hardcoded
      expect(
          clickIds, contains('irclickid')); // server uses irclickid, not irclid
    });
  });

  // ---- Flutter additions ---------------------------------------------------

  group('schema coverage', () {
    test('attribution re-exports the schema lists unchanged', () {
      expect(identical(utmParams, schema.utmParams), isTrue);
      expect(identical(clickIds, schema.clickIds), isTrue);
    });

    test('every UTM parameter and click ID is a defaultProperties field', () {
      for (final key in [...utmParams, ...clickIds]) {
        expect(schema.defaultPropertyFields, contains(key), reason: key);
      }
    });

    for (final key in utmParams) {
      test('parses the UTM parameter $key', () {
        final result = parseAttributionFromURL(
          'myapp://open?$key=value-$key&unrelated=1',
        );
        expect(result.utmParams, {key: 'value-$key'});
        expect(result.clickIds, isNull);
        expect(result.oursVisitorId, isNull);
      });
    }

    for (final key in clickIds) {
      test('parses the click ID $key', () {
        final result = parseAttributionFromURL(
          'https://example.test/landing?$key=value-$key&unrelated=1',
        );
        expect(result.clickIds, {key: 'value-$key'});
        expect(result.utmParams, isNull);
        expect(result.oursVisitorId, isNull);
      });
    }

    test('parses every UTM parameter and click ID from one URL', () {
      final keys = [...utmParams, ...clickIds];
      final query = [for (final key in keys) '$key=v_$key'].join('&');
      final result = parseAttributionFromURL('myapp://open?$query');
      expect(result.utmParams, {for (final key in utmParams) key: 'v_$key'});
      expect(result.clickIds, {for (final key in clickIds) key: 'v_$key'});
      expect(result.defaultProperties, {for (final key in keys) key: 'v_$key'});
    });

    test('keys are case-sensitive and must match the schema exactly', () {
      final result = parseAttributionFromURL(
        'myapp://open?UTM_SOURCE=upper&Gclid=mixed&utm_source_x=suffix',
      );
      expect(result.utmParams, isNull);
      expect(result.clickIds, isNull);
    });
  });

  group('decoding', () {
    test('decodes + as a space and %2B as a literal plus', () {
      final result = parseAttributionFromURL(
        'myapp://open?utm_term=a+b+c&utm_content=1%2B1',
      );
      expect(result.utmParams, {'utm_term': 'a b c', 'utm_content': '1+1'});
    });

    test('decodes reserved characters and multi-byte UTF-8', () {
      final result = parseAttributionFromURL(
        'myapp://open?utm_campaign=a%26b%3Dc%3Fd%23e&utm_source=%E6%97%A5%E6%9C%AC&gclid=%F0%9F%98%80',
      );
      expect(result.utmParams, {
        'utm_campaign': 'a&b=c?d#e',
        'utm_source': '日本',
      });
      expect(result.clickIds, {'gclid': '😀'});
    });

    test('keeps a malformed value raw without dropping the other params', () {
      final result = parseAttributionFromURL(
        'myapp://open?utm_source=%E0%A4%A&utm_medium=cpc&gclid=%ZZ',
      );
      expect(result.utmParams, {
        'utm_source': '%E0%A4%A',
        'utm_medium': 'cpc',
      });
      expect(result.clickIds, {'gclid': '%ZZ'});
    });

    test('splits only on the first = of a pair', () {
      final result = parseAttributionFromURL('myapp://open?gclid=abc=def==');
      expect(result.clickIds, {'gclid': 'abc=def=='});
    });

    test('a repeated key keeps the last value', () {
      final result = parseAttributionFromURL(
        'myapp://open?utm_source=first&utm_source=second',
      );
      expect(result.utmParams, {'utm_source': 'second'});
    });
  });

  group('fragments', () {
    test('ignores parameters that only appear in the fragment', () {
      final result = parseAttributionFromURL(
        'myapp://open#utm_source=fragment&gclid=fragment',
      );
      expect(result.utmParams, isNull);
      expect(result.clickIds, isNull);
    });

    test('stops at the fragment even when it carries more parameters', () {
      final result = parseAttributionFromURL(
        'myapp://open?utm_source=query#gclid=fragment&ours_visitor_id=frag',
      );
      expect(result.utmParams, {'utm_source': 'query'});
      expect(result.clickIds, isNull);
      expect(result.oursVisitorId, isNull);
    });

    test('an empty fragment and a trailing & are harmless', () {
      final result = parseAttributionFromURL('myapp://open?gclid=abc&#');
      expect(result.clickIds, {'gclid': 'abc'});
    });
  });

  group('empty values', () {
    test('a query with only empty values yields no attribution', () {
      final result = parseAttributionFromURL(
        'myapp://open?utm_source=&utm_medium=&gclid=&ours_visitor_id=',
      );
      expect(result.utmParams, isNull);
      expect(result.clickIds, isNull);
      expect(result.oursVisitorId, isNull);
    });

    test('a bare ? yields no attribution', () {
      final result = parseAttributionFromURL('myapp://open?');
      expect(result.utmParams, isNull);
      expect(result.clickIds, isNull);
      expect(result.oursVisitorId, isNull);
      expect(result.rawURL, 'myapp://open?');
    });

    test('a value that decodes to whitespace is kept', () {
      final result = parseAttributionFromURL('myapp://open?utm_term=%20');
      expect(result.utmParams, {'utm_term': ' '});
    });
  });

  group('ours_visitor_id', () {
    test('is decoded', () {
      final result = parseAttributionFromURL(
        'myapp://open?ours_visitor_id=web%2B123%20abc',
      );
      expect(result.oursVisitorId, 'web+123 abc');
    });

    test('is never part of the attribution maps', () {
      final result = parseAttributionFromURL(
        'myapp://open?ours_visitor_id=web-123',
      );
      expect(result.oursVisitorId, 'web-123');
      expect(result.utmParams, isNull);
      expect(result.clickIds, isNull);
      expect(result.defaultProperties, isEmpty);
    });

    test('an empty ours_visitor_id is null', () {
      final result = parseAttributionFromURL('myapp://open?ours_visitor_id=');
      expect(result.oursVisitorId, isNull);
    });
  });

  group('trackDeepLink on the wire', () {
    late FacadeHarness h;

    setUp(() {
      h = FacadeHarness();
      h.respond = facadeIndexedSuccess;
    });

    tearDown(() => h.dispose());

    test(
        'every UTM parameter and click ID lands in defaultProperties, never '
        'eventProperties, and the URL and other params are not sent', () async {
      final keys = [...utmParams, ...clickIds];
      final query = [
        for (final key in keys) '$key=v%20$key',
        'patient_email=private%40example.test',
        'ours_visitor_id=web-visitor-1',
      ].join('&');
      final url = 'myapp://open?$query#fragment_secret';
      final op = h.create();
      await op.init('attribution-token', storage: InMemoryStorage());
      await op.trackDeepLink(url);
      await op.track('after_link');
      await op.flush();

      final sent = h.sentEvents;
      expect(facadeEventNames(sent), [r'$deep_link_opened', 'after_link']);
      for (final item in sent) {
        final defaults = defaultPropsOf(item);
        for (final key in keys) {
          expect(defaults[key], 'v $key', reason: key);
        }
        expect(item['visitor_id'], 'web-visitor-1');
        final wire = item.toString();
        expect(wire, isNot(contains('myapp://')));
        expect(wire, isNot(contains('patient_email')));
        expect(wire, isNot(contains('private')));
        expect(wire, isNot(contains('fragment_secret')));
        expect(wire, isNot(contains('ours_visitor_id')));
      }
      final deepLink = eventPropsOf(sent.first);
      for (final key in keys) {
        expect(deepLink.containsKey(key), isFalse, reason: key);
      }
      expect(deepLink.keys.toSet(), {
        'mobile_contract_version',
        'mobile_occurred_at',
      });
      expect(
          h.bodies.every((body) => body['is_manually_set_id'] == true), isTrue);
    });

    test('empty values and fragment-only params are not sent', () async {
      final op = h.create();
      await op.init('attribution-empty-token', storage: InMemoryStorage());
      await op.trackDeepLink(
        'myapp://open?utm_source=&gclid=&ours_visitor_id=#utm_medium=frag',
      );
      await op.flush();

      final item = h.sentEvents.single;
      expect(item['event'], r'$deep_link_opened');
      final defaults = defaultPropsOf(item);
      for (final key in [...utmParams, ...clickIds]) {
        expect(defaults.containsKey(key), isFalse, reason: key);
      }
      // An empty ours_visitor_id does not stitch identity.
      expect(h.bodies.single['is_manually_set_id'], isFalse);
    });

    test('+ and percent encoding are decoded before sending', () async {
      final op = h.create();
      await op.init('attribution-decode-token', storage: InMemoryStorage());
      await op.trackDeepLink(
        'myapp://open?utm_campaign=spring+sale%202026&utm_source=g%C3%B6ogle&gclid=a%2Bb',
      );
      await op.flush();

      final defaults = defaultPropsOf(h.sentEvents.single);
      expect(defaults['utm_campaign'], 'spring sale 2026');
      expect(defaults['utm_source'], 'göogle');
      expect(defaults['gclid'], 'a+b');
    });
  });
}
