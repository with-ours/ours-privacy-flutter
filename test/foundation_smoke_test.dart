// Smoke tests for the non-session core (schema, attribution, payload,
// network, persistence, queue, core, device info). The full ports of the
// React Native suites live in their own files.
import 'dart:async';
import 'dart:convert';
import 'dart:ui' show Size;

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ours_privacy/src/attribution.dart';
import 'package:ours_privacy/src/config.dart';
import 'package:ours_privacy/src/constants.dart';
import 'package:ours_privacy/src/core.dart';
import 'package:ours_privacy/src/device_info.dart';
import 'package:ours_privacy/src/errors.dart';
import 'package:ours_privacy/src/mobile_payload.dart';
import 'package:ours_privacy/src/network.dart';
import 'package:ours_privacy/src/persistent.dart';
import 'package:ours_privacy/src/queue.dart';
import 'package:ours_privacy/src/schema.dart';
import 'package:ours_privacy/src/storage.dart';

const _token = 'upload-token';
const _type = eventsQueueType;

Map<String, Object?> _event(String id, {String visitor = 'visitor-1'}) => {
      'event': 'appointment_booked',
      'distinct_id': id,
      'visitor_id': visitor,
      'isManuallySetId': false,
      'eventProperties': {
        'mobile_contract_version': 1,
        'mobile_occurred_at': '2026-10-05T12:00:00.000Z',
      },
      'userProperties': null,
      'defaultProperties': {'sid': '1791201600000', 'os_name': 'iOS'},
    };

class _Harness {
  _Harness(this.storage, this.core, this.rejected, this.requests);

  final InMemoryStorage storage;
  final OursPrivacyCore core;
  final List<OursPrivacyIngestRejection> rejected;
  final List<Map<String, Object?>> requests;

  List<Object?> get savedItems =>
      jsonDecode(storage.values[queueKey(_token, _type)] ?? '[]')
          as List<Object?>;
  List<QueueItem> get queued =>
      OursPrivacyQueueManager.of(storage).getQueue(_token, _type);
}

Future<_Harness> _start(
  Future<http.Response> Function(http.Request request) handler, {
  List<Map<String, Object?>>? items,
}) async {
  final storage = InMemoryStorage();
  final requests = <Map<String, Object?>>[];
  final client = MockClient((request) {
    requests.add(jsonDecode(request.body) as Map<String, Object?>);
    return handler(request);
  });
  final core = OursPrivacyCore(storage: storage, httpClient: client);
  final rejected = <OursPrivacyIngestRejection>[];
  OursPrivacyConfig.instance
    ..setServerURL(_token, 'https://upload.example.test')
    ..setOnIngestRejected(_token, rejected.add);
  await OursPrivacyPersistent.of(storage).initializationComplete(_token);
  await core.initialize(_token);
  for (final item in items ?? [_event('first-event')]) {
    await core.addToOursPrivacyQueue(_token, _type, item);
  }
  return _Harness(storage, core, rejected, requests);
}

void main() {
  setUp(resetOursPrivacyFoundationForTesting);

  group('attribution', () {
    test('parses UTMs, click IDs and the visitor ID; keeps PHI out', () {
      final result = parseAttributionFromURL(
        'https://example.test/open?ours_visitor_id=web-123&utm_source=g%C3%B6ogle'
        '&utm_term=analytics+sdk&gclid=click-123&patient_email=private%40example.test'
        '&utm_medium=&orphan#frag',
      );
      expect(result.oursVisitorId, 'web-123');
      expect(result.utmParams,
          {'utm_source': 'göogle', 'utm_term': 'analytics sdk'});
      expect(result.clickIds, {'gclid': 'click-123'});
    });

    test('keeps a malformed value raw and handles null', () {
      expect(
        parseAttributionFromURL('myapp://open?utm_source=%E0%A4%A').utmParams,
        {'utm_source': '%E0%A4%A'},
      );
      final empty = parseAttributionFromURL(null);
      expect(empty.utmParams, isNull);
      expect(empty.clickIds, isNull);
      expect(empty.oursVisitorId, isNull);
      expect(empty.rawURL, '');
      expect(clickIds, contains('irclickid'));
      expect(schemaSyncedAt, '2026-03-26T16:49:44.170Z');
    });
  });

  group('mobile payload', () {
    test('migrates a legacy queued row', () {
      final normalized = normalizeMobileEvent({
        'event': 'appointment_booked',
        'eventProperties': {'appointment_id': 'a'},
        'defaultProperties': {
          'sid': 'old-uuid',
          'os_name': 'iOS',
          'mobile_session_started_at': '2026-10-05T12:00:00.000Z',
          'mobile_occurred_at': '2026-10-05T12:00:02.000Z',
          'mobile_platform': 'ios',
          'mobile_contract_version': 1,
          'app_version': '1.2',
        },
      });
      expect(normalized['defaultProperties'],
          {'sid': '1791201600000', 'os_name': 'iOS'});
      expect(normalized['eventProperties'], {
        'appointment_id': 'a',
        'mobile_contract_version': 1,
        'mobile_occurred_at': '2026-10-05T12:00:02.000Z',
        'app_version': '1.2',
      });
    });

    test('drops metadata that would exceed 200 properties', () {
      final properties = {
        for (var i = 0; i < 197; i++) 'property_$i': 'value-$i',
        'mobile_contract_version': 9,
      };
      final normalized = normalizeMobileEvent(
        {'event': 'manual', 'eventProperties': properties},
        {
          'mobile_occurred_at': '2026-10-05T12:00:00.000Z',
          'app_version': '2.0',
          'app_build': '42',
        },
      );
      final props = normalized['eventProperties']! as Map<String, Object?>;
      expect(props, hasLength(197));
      expect(props.containsKey('mobile_contract_version'), isFalse);
    });

    test('validates session IDs and canonical timestamps', () {
      expect(isSessionId('1791201600000'), isTrue);
      expect(isSessionId('0791201600000'), isFalse);
      expect(isoMilliseconds('2026-02-30T12:00:00.000Z'), isNull);
      expect(isoMilliseconds('2026-10-05T12:00:00.000Z'), 1791201600000);
    });
  });

  group('network', () {
    test('posts the RN body shape with an exact content type', () async {
      late http.Request seen;
      final network = OursPrivacyNetwork(
        clientFactory: () => MockClient((request) async {
          seen = request;
          return http.Response('{"success":true}', 200);
        }),
      );
      final response = await network.sendRequest(
        token: 't',
        endpoint: '/ingest',
        data: [
          {'event': 'e'},
        ],
        serverURL: 'https://cdn.example.test',
        isManuallySetId: true,
      );
      expect(response, {'success': true});
      expect(seen.url.toString(), 'https://cdn.example.test/ingest');
      expect(seen.headers['Content-Type'], 'application/json');
      expect(jsonDecode(seen.body), {
        'token': 't',
        'is_manually_set_id': true,
        'data': [
          {'event': 'e'},
        ],
      });
    });

    test('retries after 2 s and does not retry a 400', () {
      fakeAsync((async) {
        var calls = 0;
        final network = OursPrivacyNetwork(
          clientFactory: () => MockClient((request) async {
            calls += 1;
            return calls == 1
                ? http.Response('{}', 500)
                : http.Response('{"success":true}', 200);
          }),
        );
        Object? result;
        unawaited(network
            .sendRequest(
                token: 't', endpoint: '/ingest', data: [], serverURL: 'x://h')
            .then((value) => result = value));
        async.elapse(const Duration(milliseconds: 1999));
        expect(calls, 1);
        async.elapse(const Duration(milliseconds: 1));
        expect(calls, 2);
        expect(result, {'success': true});

        Object? error;
        final bad = OursPrivacyNetwork(
          clientFactory: () =>
              MockClient((request) async => http.Response('<html>', 400)),
        );
        unawaited(bad
            .sendRequest(
                token: 't', endpoint: '/ingest', data: [], serverURL: 'x://h')
            .catchError((Object e) => error = e));
        async.flushMicrotasks();
        expect(error, isA<OursPrivacyHttpError>());
        expect((error! as OursPrivacyHttpError).code, 400);
      });
    });

    test('cancels an in-flight request on a host client immediately', () async {
      final never = Completer<http.Response>();
      final network = OursPrivacyNetwork();
      final pending = network.sendRequest(
        token: 't',
        endpoint: '/ingest',
        data: [],
        serverURL: 'x://h',
        client: MockClient((request) => never.future),
      );
      await Future<void>.delayed(Duration.zero);
      expect(network.activeRequestCount('t'), 1);
      network.cancelRequests('t');
      await expectLater(
          pending, throwsA(isA<OursPrivacyRequestCancelledError>()));
      expect(network.activeRequestCount('t'), 0);
    });
  });

  group('core upload recovery', () {
    test('retains HTML 200 for four flushes, then rejects the head', () async {
      final h = await _start((_) async => http.Response('<html>', 200));
      for (var attempt = 1; attempt <= 4; attempt++) {
        await h.core.flush(_token);
        expect(h.savedItems, hasLength(1));
        expect(h.rejected, isEmpty);
      }
      await h.core.flush(_token);
      expect(h.requests, hasLength(5));
      expect(h.savedItems, isEmpty);
      expect(h.queued, isEmpty);
      expect(h.rejected.single.distinctId, 'first-event');
      expect(h.rejected.single.code, 'invalid_acknowledgment');
      // isManuallySetId is queue-internal.
      final sent = (h.requests.first['data']! as List).single as Map;
      expect(sent.containsKey('isManuallySetId'), isFalse);
      expect(h.requests.first['is_manually_set_id'], isFalse);
    });

    test('reports only indexed rejections after durable removal', () async {
      late _Harness h;
      h = await _start(
        (_) async => http.Response(
            '{"success":true,"accepted":1,"rejected":[{"index":1,"code":"invalid_session"}]}',
            200),
        items: [_event('first-event'), _event('second-event')],
      );
      OursPrivacyConfig.instance.setOnIngestRejected(_token, (rejection) {
        expect(h.savedItems, isEmpty);
        h.rejected.add(rejection);
      });
      await h.core.flush(_token);
      expect(h.rejected.single.distinctId, 'second-event');
      expect(
        OursPrivacyQueueManager.of(h.storage).getResponseMode(_token, _type),
        OursPrivacyResponseMode.indexed,
      );
      expect(jsonDecode(h.storage.values[queueMetadataKey(_token, _type)]!),
          {'firstOpenAccepted': false, 'responseMode': 'indexed'});
    });

    test('splits batches on visitor and identity mode', () async {
      final h = await _start(
        (_) async => http.Response('', 200),
        items: [
          _event('a'),
          {..._event('b'), 'isManuallySetId': true},
          {..._event('c', visitor: 'visitor-2'), 'isManuallySetId': true},
        ],
      );
      await h.core.flush(_token);
      expect(
        h.requests.map((r) => [
              r['is_manually_set_id'],
              (r['data']! as List)
                  .map((e) => (e as Map)['distinct_id'])
                  .toList(),
            ]),
        [
          [
            false,
            ['a'],
          ],
          [
            true,
            ['b'],
          ],
          [
            true,
            ['c'],
          ],
        ],
      );
      expect(h.queued, isEmpty);
    });

    test('drops a permanent 4xx as http_<status>', () async {
      final h = await _start((_) async => http.Response('{}', 422));
      await h.core.flush(_token);
      expect(h.rejected.single.code, 'http_422');
      expect(h.queued, isEmpty);
    });

    test('keeps a retryable success:false response', () async {
      final h = await _start((_) async =>
          http.Response('{"success":false,"retryable":true}', 200));
      await h.core.flush(_token);
      expect(h.queued, hasLength(1));
      expect(h.rejected, isEmpty);
    });

    test('opt-out during an upload cancels it without removal', () async {
      final release = Completer<http.Response>();
      final h = await _start((_) => release.future);
      final pending = h.core.flush(_token);
      await Future<void>.delayed(Duration.zero);
      final persistent = OursPrivacyPersistent.of(h.storage);
      persistent.updateOptedOut(_token, true);
      h.core.cancelPendingUploads(_token);
      await persistent.persistOptedOut(_token);
      release.complete(http.Response(
          '{"success":true,"accepted":0,"rejected":[{"index":0,"code":"x"}]}',
          200));
      await pending;
      expect(h.queued, hasLength(1));
      expect(h.rejected, isEmpty);
    });
  });

  group('persistence and queue', () {
    test('fails closed on a malformed stored decision', () async {
      final storage = InMemoryStorage();
      await storage.setItem(optOutKey('t'), 'invalid');
      final persistent = OursPrivacyPersistent.of(storage);
      await expectLater(
        persistent.initializationComplete('t'),
        throwsA(isA<OursPrivacyException>().having(
            (e) => e.message, 'message', 'Invalid stored tracking decision')),
      );
      expect(persistent.getOptedOut('t'), isTrue);
    });

    test('marks a pre-existing visitor ID as a legacy install', () async {
      final storage = InMemoryStorage();
      await storage.setItem(visitorIdKey('t'), 'existing');
      final persistent = OursPrivacyPersistent.of(storage);
      await persistent.initializationComplete('t');
      expect(persistent.getVisitorId('t'), 'existing');
      expect(persistent.hasExistingInstall('t'), isTrue);
      expect(storage.values[mobileInstallKey('t')], 'legacy');
      expect(persistent.getOptedOut('t'), isFalse);
      expect(identical(OursPrivacyPersistent.of(storage), persistent), isTrue);
    });

    test('stores rows as an array and restores first-open acceptance',
        () async {
      final storage = InMemoryStorage();
      final queue = OursPrivacyQueueManager.of(storage);
      await queue.initialize('t', _type);
      await queue.enqueue(
          't', _type, {'event': r'$mobile_first_open', 'distinct_id': 'first'});
      await queue.enqueue('t', _type, {'event': 'dup', 'distinct_id': 'first'});
      expect(jsonDecode(storage.values[queueKey('t', _type)]!),
          isA<List<Object?>>());
      expect(queue.getQueue('t', _type), hasLength(1));
      await queue.removeByIds('t', _type, ['first']);

      OursPrivacyQueueManager.resetForTesting();
      OursPrivacyPersistent.resetForTesting();
      final reloaded = OursPrivacyQueueManager.of(storage);
      await reloaded.initialize('t', _type);
      expect(reloaded.hasAcceptedFirstOpen('t', _type), isTrue);
      expect(reloaded.getQueue('t', _type), isEmpty);
    });
  });

  group('device info', () {
    test('static iOS info builds RN-ordered defaults', () {
      const info = StaticDeviceInfo.ios(screenSize: (width: 375.4, height: 0));
      expect(info.isMobilePlatform, isTrue);
      final props = info.defaultProperties();
      expect(props.keys.toList(), [
        'device_type',
        'os_name',
        'os_version',
        'version',
        'screen_width',
        'device_vendor',
        'device_model',
      ]);
      expect(props['os_name'], 'iOS');
      expect(props['screen_width'], 375);
      expect(props['version'], startsWith('flutter@'));
    });

    test('web is never a mobile platform', () {
      expect(const StaticDeviceInfo.web().isMobilePlatform, isFalse);
      expect(const StaticDeviceInfo.web().osName, 'web');
    });

    test('platform reader follows defaultTargetPlatform and tolerates FFI', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        final info = PlatformDeviceInfo();
        expect(info.os, 'android');
        // The test host is not Android, so no native facts are reported.
        expect(info.defaultProperties()['os_name'], 'Android');
        expect(info.deviceModel, isNull);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
      expect(parseAppleOSVersion('Version 17.5 (Build 21F79)'), '17.5');
      expect(parseAppleOSVersion('SP1A.210812.016'), isNull);
    });

    test('iOS device_model follows the iOS SDK on a Mac and the simulator', () {
      String? mac() => 'Mac16,7';
      String? board() => 'D73AP';
      // iPhone: the hw.machine string, hw.model is never read.
      expect(
        resolveAppleDeviceModel(
          machine: 'iPhone15,2',
          readModel: () => fail('hw.model read on a device'),
          isSimulator: false,
        ),
        'iPhone15,2',
      );
      // iPhone or iPad app on an Apple-silicon Mac: the Mac model, as
      // ProcessInfo.isiOSAppOnMac makes the iOS SDK send.
      expect(
        resolveAppleDeviceModel(
            machine: 'arm64', readModel: mac, isSimulator: false),
        'Mac16,7',
      );
      // The simulator keeps the architecture, like the iOS SDK's uname.
      expect(
        resolveAppleDeviceModel(
            machine: 'arm64', readModel: mac, isSimulator: true),
        'arm64',
      );
      // Not a Mac model, or hw.model unreadable: keep hw.machine.
      expect(
        resolveAppleDeviceModel(
            machine: 'arm64', readModel: board, isSimulator: false),
        'arm64',
      );
      expect(
        resolveAppleDeviceModel(
          machine: 'arm64',
          readModel: () => throw StateError('sysctl failed'),
          isSimulator: false,
        ),
        'arm64',
      );
      expect(
        resolveAppleDeviceModel(
            machine: null, readModel: mac, isSimulator: false),
        isNull,
      );
    });

    testWidgets('screen size: iOS uses the view, Android the display',
        (tester) async {
      addTearDown(tester.view.reset);
      addTearDown(tester.view.display.reset);
      // iPhone 8 Plus in landscape. Flutter's iOS display is
      // UIScreen.nativeBounds (portrait, 1080x1920 at scale 3); the view is
      // UIScreen.bounds x scale, which React Native and the iOS SDK send.
      tester.view.display.size = const Size(1080, 1920);
      tester.view.display.devicePixelRatio = 3;
      tester.view.physicalSize = const Size(2208, 1242);
      tester.view.devicePixelRatio = 3;
      expect(
        PlatformDeviceInfo.screenSizeOf(tester.view, OursPrivacyOS.ios),
        (width: 736.0, height: 414.0),
      );
      // Android: the whole display in dp, like Dimensions.get('screen'),
      // even when the app's window is smaller (split screen).
      tester.view.display.size = const Size(1080, 2400);
      tester.view.display.devicePixelRatio = 2.5;
      tester.view.physicalSize = const Size(1080, 1200);
      tester.view.devicePixelRatio = 2.5;
      expect(
        PlatformDeviceInfo.screenSizeOf(tester.view, OursPrivacyOS.android),
        (width: 432.0, height: 960.0),
      );
    });
  });
}
