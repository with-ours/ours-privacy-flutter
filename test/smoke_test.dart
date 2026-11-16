// End-to-end smoke test of the public facade: init on a forced iOS device
// with in-memory storage and a mock HTTP client, track, flush, and check the
// exact ingest request against the wire contract.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ours_privacy/ours_privacy.dart';
import 'package:ours_privacy/src/testing.dart';

const _token = 'smoke-token';
const _startMs = 1791201600000; // 2026-10-05T12:00:00.000Z
final _uuidV4 = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

class _Harness {
  _Harness(this.op, this.lifecycle, this.requests, this.logs);

  final OursPrivacy op;
  final ManualLifecycleSource lifecycle;
  final List<http.Request> requests;
  final List<String> logs;
  int wallMs = _startMs;
  int monotonicMs = 0;

  List<Map<String, Object?>> get bodies => [
        for (final request in requests)
          jsonDecode(request.body) as Map<String, Object?>,
      ];

  List<Map<String, Object?>> get sentEvents => [
        for (final body in bodies)
          for (final item in body['data']! as List<Object?>)
            item! as Map<String, Object?>,
      ];

  Future<void> dispose() => op.close();
}

_Harness _harness({
  OursPrivacyDeviceInfo device = const StaticDeviceInfo.ios(),
  OursAppState? initialState = OursAppState.resumed,
}) {
  final requests = <http.Request>[];
  final logs = <String>[];
  oursPrivacyLogSink = (level, message) => logs.add('${level.name}: $message');
  final lifecycle = ManualLifecycleSource(initialState);
  late final _Harness harness;
  final op = createOursPrivacyForTesting(
    OursPrivacyEnvironment(
      deviceInfo: device,
      lifecycleSourceFactory: () => lifecycle,
      wallNow: () => harness.wallMs,
      monotonicNow: () => harness.monotonicMs,
    ),
  );
  harness = _Harness(op, lifecycle, requests, logs);
  return harness;
}

http.Client _indexedSuccess(List<http.Request> requests) =>
    MockClient((request) async {
      requests.add(request);
      final body = jsonDecode(request.body) as Map<String, Object?>;
      return http.Response(
        jsonEncode({
          'success': true,
          'accepted': (body['data']! as List<Object?>).length,
          'rejected': <Object?>[],
        }),
        200,
      );
    });

void main() {
  setUp(resetOursPrivacyForTesting);
  tearDown(resetOursPrivacyForTesting);

  test('track then flush sends the exact wire contract on iOS', () async {
    final h = _harness();
    final storage = InMemoryStorage();
    await h.op.init(
      _token,
      storage: storage,
      httpClient: _indexedSuccess(h.requests),
      appVersion: '2.0.0',
      appBuild: '42',
    );
    await h.op.track(
      'appointment_booked',
      {'appointment_id': 'appointment-1'},
      {
        'externalId': 'user-1',
        'customProperties': {'plan': 'pro'},
      },
    );
    await h.op.flush();

    expect(h.requests, hasLength(1));
    final request = h.requests.single;
    expect(request.method, 'POST');
    expect(request.url.toString(), 'https://cdn.oursprivacy.com/ingest');
    expect(request.headers['Content-Type'] ?? request.headers['content-type'],
        'application/json');

    final body = h.bodies.single;
    expect(body.keys.toList(), ['token', 'is_manually_set_id', 'data']);
    expect(body['token'], _token);
    expect(body['is_manually_set_id'], false);
    final data = body['data']! as List<Object?>;
    expect(data, hasLength(1));

    final item = data.single! as Map<String, Object?>;
    expect(item.keys.toList(), [
      'event',
      'visitor_id',
      'distinct_id',
      'eventProperties',
      'userProperties',
      'defaultProperties',
    ]);
    expect(item['event'], 'appointment_booked');
    expect(item['visitor_id'], h.op.getVisitorId());
    expect(item['visitor_id'], matches(_uuidV4));
    expect(item['distinct_id'], matches(_uuidV4));
    expect(item['eventProperties'], {
      'appointment_id': 'appointment-1',
      'mobile_contract_version': 1,
      'mobile_occurred_at': '2026-10-05T12:00:00.000Z',
      'app_version': '2.0.0',
      'app_build': '42',
    });
    expect(
      (item['eventProperties']! as Map)['mobile_contract_version'],
      isA<int>(),
    );
    expect(item['userProperties'], {
      'external_id': 'user-1',
      'custom_properties': {'plan': 'pro'},
    });
    expect(item['defaultProperties'], {
      'device_type': 'mobile',
      'os_name': 'iOS',
      'os_version': '17.5',
      'version': 'flutter@1.0.0',
      'screen_width': 375,
      'screen_height': 812,
      'device_vendor': 'Apple',
      'device_model': 'iPhone15,2',
      'sid': '$_startMs',
    });

    // The queue is empty after the indexed acknowledgment.
    expect(jsonDecode(storage.values['OURSPRIVACY_${_token}_/ingest_QUEUE']!),
        isEmpty);
    await h.dispose();
  });

  test('automatic events queue the cold-open facts before a manual event',
      () async {
    final h = _harness(device: const StaticDeviceInfo.android());
    await h.op.init(
      _token,
      storage: InMemoryStorage(),
      httpClient: _indexedSuccess(h.requests),
      trackAutomaticEvents: true,
      initialURL:
          'myapp://open?ours_visitor_id=web-123&utm_source=email&gclid=click-1&email=private%40example.test',
    );
    h.wallMs += 1000;
    h.monotonicMs += 1000;
    await h.op.track('appointment_booked');
    await h.op.flush();

    final events = h.sentEvents;
    expect(events.map((event) => event['event']), [
      r'$deep_link_opened',
      r'$mobile_first_open',
      r'$mobile_app_open',
      r'$mobile_session_start',
      'appointment_booked',
    ]);
    final sid = (events[1]['defaultProperties']! as Map)['sid'];
    expect(sid, '$_startMs');
    for (final event in events) {
      expect(event['visitor_id'], 'web-123');
      final defaults = event['defaultProperties']! as Map;
      expect(defaults['os_name'], 'Android');
      expect(defaults['sid'], sid);
      final isCanonical = (event['event']! as String).startsWith(r'$mobile_');
      expect(defaults.containsKey('utm_source'), !isCanonical);
      expect(event.toString(), isNot(contains('private')));
      expect(event.toString(), isNot(contains('myapp://')));
    }
    expect(
        h.bodies.every((body) => body['is_manually_set_id'] == true), isTrue);
    await h.dispose();
  });

  test('web builds send no mobile metadata', () async {
    final h = _harness(device: const StaticDeviceInfo.web());
    await h.op.init(
      _token,
      storage: InMemoryStorage(),
      httpClient: _indexedSuccess(h.requests),
      trackAutomaticEvents: true,
      appVersion: '2.0.0',
    );
    await h.op.trackScreen('Home');
    await h.op.track('clicked', {'button': 'buy'});
    await h.op.flush();

    final event = h.sentEvents.single;
    expect(event['event'], 'clicked');
    expect(event['eventProperties'], {'button': 'buy'});
    final defaults = event['defaultProperties']! as Map;
    expect(defaults['os_name'], 'web');
    expect(defaults.containsKey('sid'), isFalse);
    await h.dispose();
  });

  test('facade validation matches React Native', () async {
    final op = OursPrivacy();
    expect(
      () => op.track('x'),
      throwsA(isA<StateError>().having((e) => e.message, 'message',
          'OursPrivacy.init(token, options) must be called before any other method.')),
    );
    expect(() => op.init('  '), throwsArgumentError);

    final h = _harness();
    await h.op.init(
      _token,
      storage: InMemoryStorage(),
      httpClient: _indexedSuccess(h.requests),
    );
    expect(() => h.op.track(''), throwsArgumentError);
    expect(
        () => h.op.track('x', {'when': DateTime(2026)}), throwsArgumentError);
    expect(() => h.op.trackDeepLink(' '), throwsArgumentError);
    expect(() => h.op.setVisitorId(''), throwsArgumentError);

    await h.op.track(r'$mobile_app_open');
    await h.op.trackScreen('1 bad label');
    await h.op.trackScreen('Trailing ');
    await h.op.flush();
    expect(h.requests, isEmpty);
    expect(
      h.logs,
      contains(r'warning: Event names starting with $mobile_ are reserved'),
    );
    expect(
      h.logs.where((line) => line.startsWith('warning: trackScreen ignored')),
      hasLength(2),
    );
    await h.dispose();
  });

  test('opt-out clears unsent events and re-init keeps the visitor', () async {
    final h = _harness();
    final storage = InMemoryStorage();
    await h.op.init(
      _token,
      storage: storage,
      httpClient: _indexedSuccess(h.requests),
    );
    final visitorId = h.op.getVisitorId();
    await h.op.track('before_opt_out');
    await h.op.optOutTracking();
    expect(h.op.hasOptedOutTracking(), isTrue);
    await h.op.track('ignored');
    await h.op.flush();
    expect(h.requests, isEmpty);

    await h.op.init(
      _token,
      storage: storage,
      httpClient: _indexedSuccess(h.requests),
    );
    expect(h.op.hasOptedOutTracking(), isTrue);
    expect(h.op.getVisitorId(), visitorId);
    await h.op.optInTracking();
    await h.op.flush();
    expect(h.sentEvents.map((event) => event['event']), [r'$opt_in']);
    await h.dispose();
  });

  test('lifecycle: pause/resume, background flush, re-init continues',
      () async {
    final h = _harness(initialState: null);
    final storage = InMemoryStorage();
    final init = h.op.init(
      _token,
      storage: storage,
      httpClient: _indexedSuccess(h.requests),
      trackAutomaticEvents: true,
    );
    // Delivered before init completes: buffered, then applied on load.
    h.lifecycle.emit(OursAppState.resumed);
    await init;
    expect(oursPrivacyImplOf(h.op)!.appForegrounded, isTrue);
    expect(oursPrivacyImplOf(h.op)!.hasCheckpointTimer, isTrue);

    h.monotonicMs += 4000;
    h.wallMs += 4000;
    h.lifecycle.emit(OursAppState.inactive); // pause: engagement 4 s
    h.monotonicMs += 1000;
    h.wallMs += 1000;
    h.lifecycle.emit(OursAppState.resumed); // resume: no app_open
    h.monotonicMs += 2000;
    h.wallMs += 2000;
    h.lifecycle.emit(OursAppState.inactive);
    h.lifecycle.emit(OursAppState.hidden); // background + flush
    h.lifecycle.emit(OursAppState.paused); // no second background
    await oursPrivacyImplOf(h.op)!.flush(_token);

    final events = h.sentEvents;
    expect(events.map((event) => event['event']), [
      r'$mobile_first_open',
      r'$mobile_app_open',
      r'$mobile_session_start',
      r'$mobile_session_engagement',
      r'$mobile_session_engagement',
    ]);
    expect(
      events
          .skip(3)
          .map((e) => (e['eventProperties']! as Map)['engagement_duration_ms']),
      [4000, 2000],
    );

    // Coming back up then re-initializing while foregrounded keeps the
    // session and does not emit another app open.
    h.lifecycle.emit(OursAppState.hidden);
    h.lifecycle.emit(OursAppState.inactive);
    h.lifecycle.emit(OursAppState.resumed);
    await oursPrivacyImplOf(h.op)!.flush(_token);
    expect(h.sentEvents.last['event'], r'$mobile_app_open');
    final count = h.sentEvents.length;
    await h.op.init(
      _token,
      storage: storage,
      httpClient: _indexedSuccess(h.requests),
      trackAutomaticEvents: true,
    );
    expect(oursPrivacyImplOf(h.op)!.reusedSession, isTrue);
    await h.op.flush();
    expect(h.sentEvents.length, count);
    await h.dispose();
  });
}
