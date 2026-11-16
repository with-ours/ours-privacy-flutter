# Ours Privacy Flutter SDK demo

This app exercises the Ours Privacy Flutter SDK on iOS and Android. It depends on the SDK in the parent directory (`ours_privacy: {path: ../}`), so edits to the SDK show up on the next run.

The app needs Flutter 3.47 or later. The SDK itself supports Flutter 3.13 and later; the demo needs a newer Flutter because its iOS shell uses the UIScene lifecycle (which `app_links` 7 supports) and its UI uses `package:material_ui`.

## Run it

Pass a token for a test source with `--dart-define`. Never commit a real token. Without one, the app uses the placeholder `YOUR_API_TOKEN`, shows a warning, and the server rejects its events.

```sh
cd example
flutter pub get
flutter run --dart-define=OURSPRIVACY_TOKEN=<your test source token>
```

| Define | Default | Effect |
| --- | --- | --- |
| `OURSPRIVACY_TOKEN` | `YOUR_API_TOKEN` (placeholder) | The source token passed to `init`. |
| `OURSPRIVACY_SERVER_URL` | SDK default (`https://cdn.oursprivacy.com`) | Sends events to another server, for example a local capture server. |
| `OURSPRIVACY_TRACK_AUTOMATIC_EVENTS` | `true` | Starting value of `trackAutomaticEvents`. You can also change it in the app, which calls `init` again. |

The app also passes `appVersion: '1.0.0'`, `appBuild: '1'`, `defaultEventProperties: {'demo_app': true}`, and `defaultUserCustomProperties: {'test_user': true}`. Debug builds turn on SDK logging, so each queued event shows in the `flutter run` console.

## What it shows

The home screen shows the server, the current visitor ID (`getVisitorId()`), the opt-out state, and the result of the last action. The buttons are:

- **Track Event**: `track('button_pressed')`, then `flush()`.
- **Identify User**: `identify()` with an email, `externalId`, and `customProperties`, then `flush()`.
- **Update Defaults + Track**: `updateDefaultEventProperties()` and `updateDefaultUserConsentProperties()`, then tracks an event.
- **Open Schedule**: opens a second route. The `OursScreenObserver` from the SDK docs calls `trackScreen('Home')` and `trackScreen('Schedule')` as routes change.
- **Track Deep Link (warm start)**: `trackDeepLink()` with UTM parameters, click IDs, and `ours_visitor_id`.
- **Track After Attribution**: tracks an event that carries the latest link attribution.
- **Set Visitor ID Manually**: `setVisitorId()`, then tracks an event.
- **Opt Out** and **Opt In**: `optOutTracking()`, and `optInTracking()` (which sends `$opt_in`).
- **Flush** and **Reset**: `flush()`, and `reset()` (which generates a new visitor ID).

## Deep links

The app registers the custom scheme `oursdemo://` and hands every link it is opened with to `op.trackDeepLink()` through [app_links](https://pub.dev/packages/app_links), on a cold start and on a warm open. Flutter's own deep linking is turned off (`flutter_deeplinking_enabled` on Android, `FlutterDeepLinkingEnabled` on iOS), so a link is never pushed as a route.

Open a link on a running simulator or emulator:

```sh
# iOS simulator
xcrun simctl openurl booted 'oursdemo://open?utm_source=newsletter&ours_visitor_id=6f1c2a4e-0b7d-4c3e-9a51-2e8f0d6b7c10'

# Android emulator
adb shell am start -a android.intent.action.VIEW \
  -d 'oursdemo://open?utm_source=newsletter\&ours_visitor_id=6f1c2a4e-0b7d-4c3e-9a51-2e8f0d6b7c10'
```

The visitor ID on screen changes to the link's `ours_visitor_id`, and the next flush sends `$deep_link_opened` with the link's attribution (not the URL).

## Platform setup

- Android: `minSdk` 24, which Flutter, `shared_preferences`, and `app_links` require. Debug builds allow plain HTTP only to `10.0.2.2`, `127.0.0.1`, and `localhost`, for a local capture server.
- iOS: deployment target 15.0, from the Flutter template (`shared_preferences` and `app_links` need 13.0). `NSAllowsLocalNetworking` permits a local capture server.
