# Ours Privacy Flutter SDK

[![pub package](https://img.shields.io/pub/v/ours_privacy.svg)](https://pub.dev/packages/ours_privacy)
[![GitHub](https://img.shields.io/badge/GitHub-repo-blue)](https://github.com/with-ours/ours-privacy-flutter)

Privacy-first analytics for Flutter apps on iOS and Android.

The SDK is written in Dart and needs no native code: add the package, initialize it, and track. It stores its state with the [shared_preferences](https://pub.dev/packages/shared_preferences) plugin. It supports Flutter 3.13+ (Dart 3.1+). CI tests the Flutter 3.13 floor with the lowest allowed dependency versions, and the current stable release.

- [pub.dev](https://pub.dev/packages/ours_privacy)
- [GitHub](https://github.com/with-ours/ours-privacy-flutter)
- [Docs](https://docs.oursprivacy.com/docs/flutter-sdk)

---

## Table of Contents

- [Quick Start](#quick-start)
- [Mobile Instrumentation](#mobile-instrumentation)
- [Complete Example](#complete-example)
- [API Reference](#api-reference)
  - [Initialization](#initialization)
  - [Core Tracking](#core-tracking)
  - [Screen Tracking](#screen-tracking)
  - [Default Properties](#default-properties)
  - [Configuration](#configuration)
  - [Identity](#identity)
  - [Deep Link Attribution](#deep-link-attribution)
  - [Privacy Controls](#privacy-controls)
  - [Shutdown and Errors](#shutdown-and-errors)
- [Persistence](#persistence)
- [Testing Your App](#testing-your-app)
- [Payload Structure](#payload-structure)
- [FAQ](#faq)
- [Support](#support)

---

## Quick Start

### 1. Install

```bash
flutter pub add ours_privacy
```

On Android, your app's `android/app/src/main/AndroidManifest.xml` must declare the internet permission. Flutter's app template adds it only to debug and profile builds, so a release build without it sends no events:

```xml
<uses-permission android:name="android.permission.INTERNET"/>
```

### 2. Initialize

Create one instance for your app and initialize it with your source's API token before `runApp`:

```dart
import 'package:flutter/widgets.dart';
import 'package:ours_privacy/ours_privacy.dart';

final op = OursPrivacy();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await op.init('YOUR_API_TOKEN');
  } on OursPrivacyException catch (error) {
    // Storage failed or saved SDK state was unreadable. Start the app
    // anyway; calling init() again later retries.
    debugPrint('Ours Privacy init failed: $error');
  }
  runApp(const MyApp());
}
```

Catch the error so a storage failure on the device can never stop `runApp`.

That's it. The SDK connects to `https://cdn.oursprivacy.com` by default — no endpoint configuration needed.

### 3. Track Events

```dart
op.track('Button Pressed');
op.track('Purchase', {'value': 49.99, 'currency': 'USD'});
```

### 4. Identify Users

After login, link events to a user:

```dart
await op.identify({
  'externalId': 'user-123',
  'email': 'user@example.com',
  'firstName': 'Jane',
});
```

### 5. Flush

Events are batched and sent every 10 seconds by default. To send immediately:

```dart
await op.flush();
```

On logout, call `await op.reset()` to start a new visitor.

---

## Mobile Instrumentation

On iOS and Android, every event (canonical, manual, and identify) carries `defaultProperties.sid`, the session start time as a 13-digit decimal millisecond timestamp. OS, device, and SDK `version` defaults are sent too. When capacity allows, SDK-owned `eventProperties` contain `mobile_contract_version: 1`, UTC ISO millisecond `mobile_occurred_at`, and `app_version` / `app_build` when supplied through `appVersion` / `appBuild`. The SDK owns `mobile_contract_version` and `mobile_occurred_at`; caller occurrence timestamps are replaced by the SDK call time. Explicit `appVersion` / `appBuild` options override caller values, while existing `app_version` / `app_build` event properties and registered defaults remain fallback values. Flutter web and desktop builds send events without this mobile metadata, so they never count as mobile app traffic.

Up to 196 ordinary event-property keys, including registered defaults, leave key capacity for all four metadata fields. Metadata also requires the JSON-encoded `eventProperties` to stay under 1 MB. If adding metadata would exceed either limit, the SDK omits these fields together and preserves all ordinary properties and session/device defaults. Larger bags may therefore be excluded from Mobile Analytics.

`trackAutomaticEvents` defaults to `false`. Set it to `true` to emit the automatic lifecycle events below. Manual `track()` and `trackScreen()` work with it off and still carry session metadata. The `$mobile_*` prefix is reserved for SDK-generated facts; `track()` ignores those names and logs a warning when logging is enabled. Full tracking opt-out suppresses both automatic and manual events, discards the current mobile session and unsent queued events, and clears registered default event, user custom, user consent, and attribution properties. It retains the current visitor ID; opt-in starts fresh mobile session state under that ID unless your app changes it. An opted-out launch does not consume the first-open marker.

Successful HTTP responses with an empty body (including 204) or a JSON object without indexed fields acknowledge the full batch. Indexed `accepted` counts and `rejected` index/code entries must cover the submitted batch with unique valid indexes. Nonempty malformed bodies, nonobject JSON, and invalid indexed acknowledgments retain the batch until the fifth malformed flush response for that queue head, then discard it with `invalid_acknowledgment`. Restarting the SDK resets the attempt count.

Explicit `success: false` rejects the batch with `ingest_rejected`, unless `retryable: true` is present. Permanent HTTP 4xx responses discard the batch with `http_STATUS`; 403, 408, 425, and 429 retain events for retry. The optional `onIngestRejected` listener receives only `distinctId` and `code`, after removal is saved. Failed saves, transport failures, server errors, and retryable rejections retain queued data. Queues have no size cap. Each batch contains one captured visitor ID and identity mode; changing identity does not rewrite queued events.

```dart
await op.init(
  'YOUR_API_TOKEN',
  onIngestRejected: (rejection) {
    debugPrint('Mobile event rejected ${rejection.distinctId} ${rejection.code}');
  },
);
```

| Canonical event              | Trigger                                                                              | Event properties                                             |
| ---------------------------- | ------------------------------------------------------------------------------------ | ------------------------------------------------------------ |
| `$mobile_first_open`         | First eligible tracked foreground open for this installation and source token        | None                                                         |
| `$mobile_app_open`           | Each tracked foreground entry, including cold start                                  | None                                                         |
| `$mobile_session_start`      | First tracked foreground entry or the next entry after 30 minutes of inactivity      | None                                                         |
| `$mobile_session_engagement` | Positive foreground-time delta at a checkpoint, tracked screen change, or background | `engagement_duration_ms` (integer); `screen_name` when known |
| `$mobile_session_end`        | When a previously announced session is replaced                                      | None                                                         |
| `$mobile_app_update`         | First tracked open after a previously observed host version/build changes            | `previous_app_version`, `previous_app_build` when known      |
| `$mobile_screen_view`        | An explicit `trackScreen()` call with a new active screen                            | `screen_name`                                                |

The SDK follows foreground and background changes itself through Flutter's app lifecycle. A notification shade, system dialog, or app switcher that returns straight to the app resumes the session without another `$mobile_app_open`. `$mobile_screen_view` requires a route signal from your app; the SDK does not observe your navigator. Screen engagement belongs to the previously active screen when a new screen is tracked. Engagement duration is measured in integer milliseconds; a session becomes engaged after 10 accumulated foreground seconds. A session keeps its `sid` on a foreground return before 30 minutes of inactivity and rotates at 30 minutes. Background `track()` calls refresh inactivity, so apps with continuous background tracking may keep the session alive. A clock rollback greater than five minutes starts a new session. `$mobile_session_end` is best effort, because an app can close without warning; its occurrence is the previous session's last activity. A visitor ID change or reset ends an announced session and starts a new one; full opt-out silently discards it. Flutter reports a full-screen native screen over your Flutter view (for example an interstitial ad, the camera, or a payment sheet presented as its own view controller or Activity) the same way as leaving the app, so returning from one counts as a new `$mobile_app_open`.

Backgrounding clears the active screen. Re-report the current screen on foreground resume when your navigation callback does not run.

Canonical SDK telemetry contains lifecycle state, device/SDK metadata, and developer-supplied stable screen labels. Canonical `$mobile_*` facts carry no user properties, default event properties, or deep-link attribution. The SDK does not inspect screen content or collect advertising device IDs, patient fields, crash details, or network payloads automatically. Deep-link parsing extracts only allowlisted UTM parameters, click IDs, and `ours_visitor_id`; it does not add the full URL to a queued event or diagnostic. Keep PHI out of URLs, UTM values, screen labels, custom event names, and other caller-supplied properties.

---

## Complete Example

```dart
import 'package:flutter/material.dart';
import 'package:ours_privacy/ours_privacy.dart';

final op = OursPrivacy();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await op.init(
      'YOUR_API_TOKEN',
      trackAutomaticEvents: true,
      appVersion: '2.0.0',
      appBuild: '42',
    );
  } on OursPrivacyException catch (error) {
    debugPrint('Ours Privacy init failed: $error');
  }
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () => op.track('Button Pressed', {'screen': 'Home'}),
            child: const Text('Track Event'),
          ),
        ),
      ),
    );
  }
}
```

---

## API Reference

Methods validate their arguments synchronously: calling any method before `init()` (or after `close()`) throws a `StateError`, and an empty token, event name, URL, or visitor ID throws an `ArgumentError`. Property values must be JSON-encodable (`String`, `num`, `bool`, `null`, `List`, or `Map<String, ...>` of those); other values throw an `ArgumentError`. Storage or network failures inside `track()`, `trackScreen()`, and `reset()` are logged and never surface as uncaught errors, so calling them without `await` is safe. Other returned futures complete with an [`OursPrivacyException`](#oursprivacyexception) when storage fails or saved SDK state cannot be read.

### Initialization

#### `OursPrivacy()`

Creates an unconfigured instance. All configuration is passed to `init()`. The constructor touches no Flutter bindings, so it is safe as a top-level `final`.

```dart
final op = OursPrivacy();
```

---

#### `op.init(token, {...})`

Initialize the SDK. Must be called before any other method. Await it before `runApp` so consent and the saved visitor are loaded before your first event.

| Parameter                      | Type                                          | Description                                                                                                                  |
| ------------------------------ | --------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| `token`                        | `String`                                      | Your source's API token (required)                                                                                           |
| `trackAutomaticEvents`         | `bool`                                        | Emit canonical mobile lifecycle events when `true` (default: `false`)                                                        |
| `appVersion`                   | `String?`                                     | Host app version, sent as `eventProperties.app_version`                                                                      |
| `appBuild`                     | `String?`                                     | Host app build, sent as `eventProperties.app_build`                                                                          |
| `onIngestRejected`             | `void Function(OursPrivacyIngestRejection)?`  | Optional listener for indexed rejection responses                                                                            |
| `optOutTrackingByDefault`      | `bool`                                        | If `true`, start opted out only while no choice is saved (default: `false`)                                                  |
| `serverURL`                    | `String?`                                     | Override the base URL used for requests, for example a proxy or local QA capture server                                      |
| `visitorId`                    | `String?`                                     | Pre-set the visitor ID; sets `is_manually_set_id: true` on subsequent events in this launch                                  |
| `initialURL`                   | `String?`                                     | Deep link URL to parse on init: UTM params, click IDs, and `ours_visitor_id` (see [Deep Link Attribution](#deep-link-attribution)) |
| `defaultEventProperties`       | `Map<String, Object?>?`                       | Properties merged into `eventProperties` on every `track()` call                                                             |
| `defaultUserCustomProperties`  | `Map<String, Object?>?`                       | Properties merged into `userProperties.custom_properties` on every event                                                     |
| `defaultUserConsentProperties` | `Map<String, Object?>?`                       | JSON-compatible values merged into `userProperties.consent` on every event                                                   |
| `storage`                      | `OursPrivacyStorage?`                         | Custom key-value storage (default: shared_preferences). `InMemoryStorage` is exported for tests                              |
| `httpClient`                   | `http.Client?`                                | Advanced/testing: the `package:http` client used for uploads. The SDK never closes a client you pass                         |

Explicit opt-in and opt-out choices take precedence over `optOutTrackingByDefault` after restart, so a returning user keeps the choice they made. A failed opt-in does not reopen tracking; opt-out fences tracking immediately even if its write fails. These failures complete the returned future with an `OursPrivacyException`; retry the operation after storage recovers.

Calling `init()` again on the same instance replaces the previous configuration. Within the same foreground it does not emit another app-open. Calling `init()` after [`close()`](#opclose) starts the instance again.

**Returns:** `Future<void>`. Completes with an [`OursPrivacyException`](#oursprivacyexception) when storage fails or saved SDK state cannot be read; catch it so the failure cannot stop your app from starting (see [Quick Start](#2-initialize)).

```dart
// Minimal init
await op.init('YOUR_API_TOKEN');

// With options
await op.init(
  'YOUR_API_TOKEN',
  visitorId: 'pre-known-id',
  appVersion: '2.0.0',
  appBuild: '42',
  trackAutomaticEvents: true,
  defaultEventProperties: {'platform': 'mobile'},
  defaultUserCustomProperties: {'tier': 'pro'},
  defaultUserConsentProperties: {'marketing': true},
);
```

---

### Core Tracking

#### `op.track(eventName, [eventProperties, userProperties])`

Track an event with optional event and user properties. Event names starting with `$mobile_` are reserved and ignored with a warning.

| Parameter         | Type                    | Required | Description                                                     |
| ----------------- | ----------------------- | -------- | --------------------------------------------------------------- |
| `eventName`       | `String`                | Yes      | Name of the event                                               |
| `eventProperties` | `Map<String, Object?>?` | No       | Key/value pairs to attach to the event                          |
| `userProperties`  | `Map<String, Object?>?` | No       | User properties for this event (same keys as [`identify()`](#opidentifyuserproperties)) |

**Returns:** `Future<void>`

```dart
op.track('Page View', {'page': '/home', 'referrer': 'google'});
```

---

#### `op.identify([userProperties])`

Associate this visitor with a known user, and send a `$identify` event. Call this after a user logs in.

Pass identifying fields inside the `userProperties` map — most commonly `externalId` (your system's user ID). Any default custom or consent properties registered through `updateDefault*` are merged in automatically.

| Key                | Type     | Description                                                                               |
| ------------------ | -------- | ----------------------------------------------------------------------------------------- |
| `email`            | `String` | User's email address                                                                      |
| `externalId`       | `String` | ID from your own system                                                                   |
| `phoneNumber`      | `String` | User's phone number                                                                       |
| `firstName`        | `String` | First name                                                                                |
| `lastName`         | `String` | Last name                                                                                 |
| `gender`           | `String` | Gender                                                                                    |
| `dateOfBirth`      | `String` | Date of birth (ISO 8601, e.g. `1990-04-12`)                                               |
| `city`             | `String` | City                                                                                      |
| `state`            | `String` | State / region                                                                            |
| `zip`              | `String` | Postal / ZIP code                                                                         |
| `country`          | `String` | Country (ISO 3166-1 alpha-2 preferred)                                                    |
| `companyName`      | `String` | Company name                                                                              |
| `jobTitle`         | `String` | Job title                                                                                 |
| `ip`               | `String` | Client IP (only set this if you have a reliable source — the server will infer otherwise) |
| `customProperties` | `Map`    | Arbitrary custom user attributes                                                          |
| `consent`          | `Map`    | Consent values (e.g. `{'marketing': true}` or `{'analytics': 'granted'}`)                 |

The SDK converts these camelCase keys to the snake_case wire format (`externalId` → `external_id`, `dateOfBirth` → `date_of_birth`, and so on) before sending.

**Returns:** `Future<void>`

```dart
await op.identify({
  'email': 'jane@example.com',
  'externalId': 'db-user-456',
  'firstName': 'Jane',
  'customProperties': {'tier': 'pro'},
  'consent': {'marketing': true},
});
```

---

#### `op.flush()`

Attempt to send queued events immediately. Await it before changing tracking consent. A failed request leaves events queued for retry.

**Returns:** `Future<void>`

```dart
await op.flush();
```

---

#### `op.reset()`

Clear the current user identity and all default properties, and generate a new random visitor ID. Call this when a user logs out. Events already queued keep the visitor they were tracked with.

**Returns:** `Future<void>`

```dart
await op.reset();
```

---

### Screen Tracking

#### `op.trackScreen(screenName)`

Track a visible screen on iOS or Android. `screenName` must be a stable, developer-chosen label of 1–80 characters: start with an ASCII letter, then use only ASCII letters, numbers, spaces, underscores, or hyphens. Leading and trailing whitespace is rejected. Invalid labels are ignored without throwing, and the SDK logs a warning when logging is enabled. Never pass a route path, URL, query string, route parameter, screen title containing patient data, or other dynamic identifier. A duplicate call for the current visible screen does not add another view. Call again when that screen is entered after a background/foreground transition.

**Returns:** `Future<void>`

```dart
op.trackScreen('Schedule');
```

With `Navigator` or `MaterialApp` named routes, add a `NavigatorObserver` that maps fixed route names to approved labels:

```dart
import 'dart:async';

class OursScreenObserver extends NavigatorObserver {
  static const screenLabels = {'/': 'Home', '/schedule': 'Schedule'};

  void _trackScreen(Route<dynamic>? route) {
    final label = screenLabels[route?.settings.name];
    // trackScreen() logs its own failures, so it is safe not to await.
    if (label != null) unawaited(op.trackScreen(label));
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _trackScreen(route);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _trackScreen(previousRoute);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      _trackScreen(newRoute);
}

MaterialApp(navigatorObservers: [OursScreenObserver()], routes: appRoutes);
```

Initialize `op` before `runApp` so the initial route's `didPush` is tracked. With a router package such as go_router, pass the observer to its `observers` list, or call `trackScreen()` from its route-change callback. Map route names only; do not read route arguments or derive labels from URLs. Automatic lifecycle tracking does not replace this explicit route integration, and `trackScreen()` remains available when `trackAutomaticEvents` is off.

Full-screen native UI that covers your Flutter view (for example a system photo picker, document scanner, or full-screen browser) can move the app to the background. When the user returns, the screen name is cleared until the next `trackScreen()` call, and no route change fires, so call `trackScreen()` again for the screen the user returns to.

---

### Default Properties

Default properties are merged into every event the SDK sends. They are the primary way to attach persistent context without repeating it on every `track()` call. Set them at init or at any point afterwards. They live in memory: set them again after each app launch. `$identify` and `$deep_link_opened` events, and canonical `$mobile_*` facts, do not carry default event properties.

#### `op.updateDefaultEventProperties(properties)`

Merge properties into `eventProperties` on every future `track()` call. Properties are merged shallowly — later calls overwrite earlier ones for the same key.

**Returns:** `void`

```dart
// At init time:
await op.init(
  'YOUR_API_TOKEN',
  defaultEventProperties: {'environment': 'production'},
);

// Or later (e.g. after fetching user data):
op.updateDefaultEventProperties({'experiment_group': 'variant_b'});

// Every subsequent track() includes these automatically:
op.track('Button Pressed'); // eventProperties includes environment and experiment_group
```

---

#### `op.updateDefaultUserCustomProperties(properties)`

Merge properties into `userProperties.custom_properties` on every future event.

**Returns:** `void`

```dart
op.updateDefaultUserCustomProperties({'tier': 'enterprise', 'seats': 50});
```

---

#### `op.updateDefaultUserConsentProperties(properties)`

Merge properties into `userProperties.consent` on every future event. Use this to send the user's consent state alongside all analytics events.

**Returns:** `void`

```dart
op.updateDefaultUserConsentProperties({'marketing': true});
```

---

### Configuration

#### `op.setServerURL(serverURL)`

Override the base URL after initialization. **Returns:** `void`

#### `op.setLoggingEnabled(enabled)`

Enable or disable debug logging. Logging is disabled by default. **Returns:** `void`

```dart
op.setLoggingEnabled(true);
```

#### `op.setFlushOnBackground(enabled)`

Toggle the automatic flush when the app moves to the background. Enabled by default. On iOS the flush is best effort: the SDK does not request extra background execution time, so a request still in flight when the system suspends the app is retried on the next launch or flush. **Returns:** `void`

```dart
op.setFlushOnBackground(false);
```

#### `op.setFlushBatchSize(size)`

Set the maximum number of events sent in a single request. Values are clamped to 1–50 (default: 50). **Returns:** `void`

```dart
op.setFlushBatchSize(25);
```

---

### Identity

#### `op.getVisitorId()`

Returns the stable visitor UUID for this install. Synchronous. No prefix. Use it to pass the visitor ID to another SDK, such as a mobile measurement partner.

**Returns:** `String?`

```dart
final visitorId = op.getVisitorId(); // e.g. "550e8400-e29b-41d4-a716-446655440000"
```

---

#### `op.setVisitorId(visitorId)`

Update the visitor ID after initialization. Use this for web-to-app identity stitching when the visitor ID arrives outside a deep link (for example from a WebView or a platform channel). Sets `is_manually_set_id: true` on events tracked until the app restarts; the visitor ID itself persists.

**Returns:** `Future<void>`

```dart
await op.setVisitorId('550e8400-e29b-41d4-a716-446655440000');
```

---

### Deep Link Attribution

#### `op.trackDeepLink(url)`

Parse a deep link URL for attribution data and send a `$deep_link_opened` event. Extracts UTM parameters, ad network click IDs, and `ours_visitor_id` for web-to-app identity stitching: when the link carries `ours_visitor_id`, the SDK adopts it so later events land on the same visitor profile as the web activity.

`$deep_link_opened` has no `eventProperties.url`. On iOS and Android its `eventProperties` holds only the SDK's mobile metadata (`mobile_contract_version`, `mobile_occurred_at`, `app_version`, `app_build`); on other platforms it is `null`. The full URL is not included in SDK diagnostic logs. Parsed attribution parameters are added to `defaultProperties`, so they appear on all subsequent `track()` calls. Calling `trackDeepLink()` again **replaces** the prior attribution rather than merging, so stale UTM keys don't leak into events triggered by a later link. Attribution lasts until the app quits; only the visitor ID persists across a restart.

Await the returned future before calling `track()` to ensure attribution and visitor identity are applied.

**Returns:** `Future<void>`

The SDK hooks nothing in the operating system, so your app hands over the URL it was opened with, on a cold start and on a warm open. With the [app_links](https://pub.dev/packages/app_links) package, version 6.0 or later (Flutter 3.16 or later), whose `uriLinkStream` also delivers the link that started the app. On Flutter 3.13 to 3.15, listen to `allUriLinkStream` instead:

```dart
import 'package:app_links/app_links.dart';

// Delivers the link that started the app, then each later link.
AppLinks().uriLinkStream.listen((uri) async {
  await op.trackDeepLink(uri.toString());
});
```

Alternatively, pass the launch URL at init time with `initialURL` (app_links 6.0 or later; on older versions call `getInitialAppLink()`):

```dart
final initialUri = await AppLinks().getInitialLink();
await op.init('YOUR_API_TOKEN', initialURL: initialUri?.toString());
```

**Supported parameters:**

| Category  | Parameters                                                                            |
| --------- | ------------------------------------------------------------------------------------- |
| UTM       | `utm_source`, `utm_medium`, `utm_campaign`, `utm_content`, `utm_term`, `utm_name`     |
| Google    | `gclid`, `gad_source`, `dclid`, `gbraid`, `wbraid`                                    |
| Meta      | `fbclid`, `fbc`, `fbp`                                                                |
| Microsoft | `msclkid`                                                                             |
| TikTok    | `ttclid`                                                                              |
| Twitter/X | `twclid`                                                                              |
| LinkedIn  | `li_fat_id`                                                                           |
| Reddit    | `rdt_cid`                                                                             |
| Snapchat  | `sccid`                                                                               |
| Pinterest | `epik`                                                                                |
| Quora     | `qclid`                                                                               |
| AppLovin  | `aleid`, `alart`, `axwrt`                                                             |
| Other     | `clickid`, `clid`, `ndclid`, `irclickid`, `im_ref`, `sacid`, `basis_cid`              |
| Identity  | `ours_visitor_id` — web-to-app visitor stitching                                      |

> **Note:** `esi` (Event Source Indicator) is configured in the AppLovin destination mapping in the Ours Privacy dashboard, not in the SDK. Set it to `"app"` for mobile events in your destination settings.

---

### Privacy Controls

If your app asks for consent first, start opted out and opt in once the person agrees:

```dart
await op.init('YOUR_API_TOKEN', optOutTrackingByDefault: true);

// When consent is granted
await op.optInTracking();
```

#### `op.optOutTracking()`

Stop all tracking immediately. Unsent queued events and the current mobile session are discarded, in-flight uploads are cancelled, and registered default event, user custom, user consent, and attribution properties are cleared. The current visitor ID is retained, so events after opt-in use that ID with a fresh mobile session. Await `flush()` first to attempt delivery; a failed request remains queued and is discarded by opt-out.

For an account switch, call `reset()` to generate a new visitor ID or `setVisitorId()` to adopt the intended ID, according to your app's policy, before tracking resumes. Keep PHI out of visitor IDs and manually supplied properties.

**Returns:** `Future<void>`

```dart
await op.flush();
await op.optOutTracking();
```

---

#### `op.optInTracking()`

Resume tracking after `optOutTracking()`. This also sends an `$opt_in` event.

**Returns:** `Future<void>`

---

#### `op.hasOptedOutTracking()`

Check whether the user has opted out of tracking.

**Returns:** `bool`. Until `init()` finishes loading the saved choice, this returns `true` to prevent tracking. Await `init()` before reading the saved decision.

```dart
if (op.hasOptedOutTracking()) {
  debugPrint('User has opted out');
}
```

---

### Shutdown and Errors

#### `op.close()`

Stop the instance: cancels its timers and in-flight uploads and detaches its app lifecycle listener. Completes after work already queued on the instance has finished. Unsent events stay in storage and are sent after the next `init()`. Afterwards every method other than `init()` and `close()` throws a `StateError` until `init()` is called again. Calling `close()` before `init()`, or twice, does nothing.

Apps normally never call it; use it in tests (see [Testing Your App](#testing-your-app)) or when discarding an instance.

**Returns:** `Future<void>`

```dart
await op.close();
```

---

#### `OursPrivacyException`

The error that SDK futures complete with when storage fails or saved SDK state cannot be read. It implements `Exception`, so `on Exception` catches it too.

| Field     | Type      | Description                                                         |
| --------- | --------- | ------------------------------------------------------------------- |
| `message` | `String`  | What failed                                                         |
| `cause`   | `Object?` | The underlying error, for example the storage backend's exception |

Calling a method before `init()` (or after `close()`) still throws a `StateError`, and an invalid argument still throws an `ArgumentError`: those are programming errors to fix, not runtime failures to catch.

```dart
try {
  await op.optOutTracking();
} on OursPrivacyException catch (error) {
  // Tracking is already off in memory; retry the save later.
  debugPrint('Could not save opt-out: ${error.message}');
}
```

---

## Persistence

The SDK persists the visitor ID, install marker, consent choice, unsent event queue, and mobile session state, so they survive app restarts. Default properties and link attribution are kept in memory only.

- **Storage backend.** By default the SDK uses `shared_preferences` (`NSUserDefaults` on iOS, `SharedPreferences` on Android), with keys prefixed `OURSPRIVACY_<token>_`. If the plugin is not registered (for example in a plain Dart test), the SDK falls back to in-memory storage, and nothing persists across restarts. Pass `storage:` to `init()` to supply your own `OursPrivacyStorage`.
- **`SharedPreferences.clear()` removes SDK state.** The SDK shares the app's `shared_preferences` store. Calling `clear()` in your app also deletes the visitor ID, the queued events, and an explicit opt-out. For consent-gated apps, use `optOutTrackingByDefault: true` so a cleared store starts opted out, and prefer removing your own keys individually.
- **Main isolate only.** Initialize and use the SDK on the main (UI) isolate. Each isolate has its own `shared_preferences` cache, so an instance in a background isolate (for example a push-notification or WorkManager handler) can overwrite the main isolate's queue or session with stale data.
- **Background flush on iOS is best effort.** See [`setFlushOnBackground`](#opsetflushonbackgroundenabled). Unsent events stay queued and are sent on the next flush.
- **Backups.** Android Auto Backup and iCloud restore can carry these preferences to a new device, which then keeps the visitor ID and does not send a new first-open.

---

## Testing Your App

In your app's widget and unit tests, give the SDK in-memory storage and a mock HTTP client so tests never touch `shared_preferences` or the network, and close it in `tearDown` so no timers are left running:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ours_privacy/ours_privacy.dart';

void main() {
  late OursPrivacy op;
  late List<http.Request> uploads;

  setUp(() async {
    uploads = [];
    op = OursPrivacy();
    await op.init(
      'test-token',
      storage: InMemoryStorage(),
      httpClient: MockClient((request) async {
        uploads.add(request);
        return http.Response('{"success":true}', 200);
      }),
    );
  });

  tearDown(() => op.close());

  test('tracks a purchase', () async {
    await op.track('Purchase', {'value': 49.99});
    await op.flush();
    expect(uploads.single.body, contains('Purchase'));
  });
}
```

`package:http/testing.dart` provides `MockClient`; add `http` to your `dev_dependencies` if your app does not already depend on it. In a `testWidgets` test, initialize and `await op.close()` inside the test body, because Flutter checks for pending timers before `tearDown` runs. If your app uses a single top-level instance, pass the same `storage:` and `httpClient:` arguments to the `init()` call your tests run.

Use only the public API in your tests. Files under `package:ours_privacy/src/` are internal and can change in any release.

---

## Payload Structure

The SDK sends a JSON body to `POST /ingest` on the configured `serverURL`. This is useful if you are building a proxy, using a local QA capture server, or verifying your data in the Ours Privacy dashboard.

```json
{
  "token": "your-project-token",
  "is_manually_set_id": false,
  "data": [
    {
      "event": "Purchase",
      "visitor_id": "550e8400-e29b-41d4-a716-446655440000",
      "distinct_id": "ecff9f0e-d4f8-4d9e-b2f8-8d9b2fcdf7b2",
      "eventProperties": {
        "price": 99,
        "mobile_contract_version": 1,
        "mobile_occurred_at": "2026-10-05T12:00:02.000Z",
        "app_version": "2.0.0",
        "app_build": "42"
      },
      "userProperties": {
        "custom_properties": {
          "tier": "pro"
        },
        "consent": {
          "marketing": true
        }
      },
      "defaultProperties": {
        "device_type": "mobile",
        "os_name": "iOS",
        "os_version": "17.5",
        "device_vendor": "Apple",
        "device_model": "iPhone16,1",
        "screen_width": 393,
        "screen_height": 852,
        "version": "flutter@1.0.0",
        "sid": "1791201600000"
      }
    }
  ]
}
```

**Key fields:**

| Field                              | Description                                                                                                |
| ---------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| `token`                            | Your source's API token                                                                                    |
| `is_manually_set_id`               | `true` when the visitor ID was set in this launch through `init(visitorId:)`, `setVisitorId()`, or `ours_visitor_id` in a deep link |
| `data`                             | Array of event objects in this batch                                                                       |
| `event`                            | Event name                                                                                                 |
| `visitor_id`                       | Stable visitor UUID for this install (no prefix)                                                           |
| `distinct_id`                      | Per-event UUID generated for this event occurrence                                                         |
| `eventProperties`                  | Caller event properties plus SDK-owned occurrence, contract, and host version metadata                     |
| `userProperties.custom_properties` | From `identify()` and `updateDefaultUserCustomProperties()`                                                |
| `userProperties.consent`           | From `identify()` and `updateDefaultUserConsentProperties()`                                               |
| `defaultProperties`                | Device/SDK metadata, attribution parameters, and the numeric session-start `sid`                           |

Device fields the platform cannot provide are omitted.

---

## FAQ

**Do I need to request permission through AppTrackingTransparency?**

No. Ours Privacy does not use IDFA or any advertising identifier, so no ATT permission is required on iOS.

**Why aren't my events showing up?**

Events are batched and sent every 10 seconds by default. Await `flush()` to send them immediately. Enable debug logging with `setLoggingEnabled(true)` to see what's happening.

**What platforms are supported?**

- Flutter 3.13 or later (Dart 3.1 or later)
- iOS and Android apps

The SDK needs no native code; Android release builds need the internet permission (see [Install](#1-install)). iOS and Android minimum versions follow your Flutter version and the `shared_preferences` plugin.

---

## Support

- [Documentation](https://docs.oursprivacy.com/docs/flutter-sdk)
- [GitHub Issues](https://github.com/with-ours/ours-privacy-flutter/issues)
- Email: support@oursprivacy.com
