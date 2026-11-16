# Changelog

## 1.0.0

- Initial release of the Ours Privacy Flutter SDK for iOS and Android apps, written in Dart with no native setup. Requires Flutter 3.13+ (Dart 3.1+).
- Track events, identify users, and manage default event, user custom, and consent properties; events are batched, persisted across restarts, and sent every 10 seconds or on `flush()`.
- Opt in to canonical `$mobile_*` lifecycle events (first open, app open, session start/end, engagement, app update) with `trackAutomaticEvents: true`; call `trackScreen()` from a `NavigatorObserver` for screen views. Invalid screen labels are ignored with a warning.
- Consent controls: `optOutTrackingByDefault`, `optInTracking()`, and `optOutTracking()`, which discards unsent events and cancels uploads in progress.
- Web-to-app identity and attribution with `trackDeepLink()`, `setVisitorId()`, and `getVisitorId()`: `ours_visitor_id`, UTM parameters, and ad click IDs are read from links without sending the raw URL.
- No IDFA or advertising identifiers; no AppTrackingTransparency prompt is needed.
- Storage failures surface as `OursPrivacyException`. For tests, pass `storage: InMemoryStorage()` and `httpClient:` to `init()`, and call `close()` to stop the SDK's timers and lifecycle listener.
