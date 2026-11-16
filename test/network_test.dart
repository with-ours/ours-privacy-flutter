// Port of __tests__/network.test.js (React Native SDK).
//
// `jest-fetch-mock` becomes a `package:http/testing.dart` MockClient passed
// as the host client, and Jest fake timers become fake_async.
import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ours_privacy/src/network.dart';
import 'package:ours_privacy/src/testing.dart';

void main() {
  setUp(resetOursPrivacyForTesting);
  tearDown(resetOursPrivacyForTesting);

  group('OursPrivacyNetwork', () {
    const mockToken = 'test-token';
    const mockEndpoint = '/ingest';
    const mockServerURL = 'https://cdn.oursprivacy.com';
    final mockData = <Object?>[
      {
        'event': 'Purchase',
        'visitor_id': 'uuid-123',
        'distinct_id': 'per-event-uuid',
        'eventProperties': {'price': 99},
        'userProperties': null,
        'defaultProperties': {
          'device_type': 'mobile',
          'os_name': 'iOS',
          'version': '1.1.0',
        },
      },
    ];

    late List<http.Request> calls;

    /// fetchMock.mockResponses(...): answers in order, repeating the last.
    MockClient respond(List<http.Response> responses) {
      calls = [];
      return MockClient((request) async {
        calls.add(request);
        final index = calls.length - 1;
        return responses[
            index < responses.length ? index : responses.length - 1];
      });
    }

    test('sends a successful request', () async {
      final client = respond([
        http.Response(jsonEncode({'success': true, 'visitor_id': 'abc'}), 200),
      ]);

      await OursPrivacyNetwork().sendRequest(
        token: mockToken,
        endpoint: mockEndpoint,
        data: mockData,
        serverURL: mockServerURL,
        client: client,
      );

      expect(calls, hasLength(1));
      expect(calls.single.url.toString(), '$mockServerURL$mockEndpoint');
    });

    test('re-sends the POST body on a 307 or 308 redirect, like fetch',
        () async {
      final client = respond([
        http.Response('', 307,
            headers: {'location': 'https://proxy.example.com/v2/ingest'}),
        http.Response('', 308, headers: {'location': '/v3/ingest'}),
        http.Response(jsonEncode({'success': true}), 200),
      ]);

      final response = await OursPrivacyNetwork().sendRequest(
        token: mockToken,
        endpoint: mockEndpoint,
        data: mockData,
        serverURL: mockServerURL,
        client: client,
      );

      expect(response, {'success': true});
      expect(calls.map((request) => request.url.toString()), [
        '$mockServerURL$mockEndpoint',
        'https://proxy.example.com/v2/ingest',
        'https://proxy.example.com/v3/ingest',
      ]);
      expect(calls.map((request) => request.method).toSet(), {'POST'});
      expect(calls.map((request) => request.body).toSet(), hasLength(1));
      expect(calls.last.headers['Content-Type'], 'application/json');
    });

    test('returns the indexed HTTP 200 response for queue acknowledgement',
        () async {
      final indexed = {
        'success': true,
        'visitor_id': 'abc',
        'accepted': 0,
        'rejected': [
          {'index': 0, 'code': 'invalid_session'},
        ],
      };
      final client = respond([http.Response(jsonEncode(indexed), 200)]);

      final response = await OursPrivacyNetwork().sendRequest(
        token: mockToken,
        endpoint: mockEndpoint,
        data: mockData,
        serverURL: mockServerURL,
        client: client,
      );

      expect(response, indexed);
    });

    test('sends JSON body with token, is_manually_set_id, and data', () async {
      final client = respond([
        http.Response(jsonEncode({'success': true}), 200),
      ]);

      await OursPrivacyNetwork().sendRequest(
        token: mockToken,
        endpoint: mockEndpoint,
        data: mockData,
        serverURL: mockServerURL,
        isManuallySetId: false,
        client: client,
      );

      final request = calls.first;
      expect(request.headers['Content-Type'], 'application/json');
      final body = jsonDecode(request.body) as Map<String, Object?>;
      expect(body['token'], mockToken);
      expect(body['is_manually_set_id'], false);
      expect(body['data'], mockData);
    });

    test('sets is_manually_set_id: true when provided', () async {
      final client = respond([
        http.Response(jsonEncode({'success': true}), 200),
      ]);

      await OursPrivacyNetwork().sendRequest(
        token: mockToken,
        endpoint: mockEndpoint,
        data: mockData,
        serverURL: mockServerURL,
        isManuallySetId: true,
        client: client,
      );

      final body = jsonDecode(calls.first.body) as Map<String, Object?>;
      expect(body['is_manually_set_id'], true);
    });

    test('does not include ?ip= query param in the URL', () async {
      final client = respond([
        http.Response(jsonEncode({'success': true}), 200),
      ]);

      await OursPrivacyNetwork().sendRequest(
        token: mockToken,
        endpoint: mockEndpoint,
        data: mockData,
        serverURL: mockServerURL,
        client: client,
      );

      final url = calls.first.url.toString();
      expect(url, isNot(contains('?ip=')));
      expect(url, '$mockServerURL$mockEndpoint');
    });

    test('retries on failure and succeeds', () {
      fakeAsync((async) {
        final client = respond([
          http.Response(jsonEncode({}), 500),
          http.Response(jsonEncode({'success': true}), 200),
        ]);

        Object? result;
        Object? failure;
        unawaited(OursPrivacyNetwork()
            .sendRequest(
          token: mockToken,
          endpoint: mockEndpoint,
          data: mockData,
          serverURL: mockServerURL,
          client: client,
        )
            .then((value) => result = value, onError: (Object e) {
          failure = e;
        }));
        async.elapse(const Duration(milliseconds: 1999));
        expect(calls, hasLength(1));
        async.elapse(const Duration(milliseconds: 1));
        expect(failure, isNull);
        expect(result, {'success': true});

        expect(calls, hasLength(2));
      });
    });

    test('fails with an HTTP error and does not retry for client errors',
        () async {
      final client = respond([http.Response('<html>bad request</html>', 400)]);

      await expectLater(
        OursPrivacyNetwork().sendRequest(
          token: mockToken,
          endpoint: mockEndpoint,
          data: mockData,
          serverURL: mockServerURL,
          client: client,
        ),
        throwsA(isA<OursPrivacyHttpError>().having((e) => e.code, 'code', 400)),
      );
      expect(calls, hasLength(1));
    });
  });
}
