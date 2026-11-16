// App lifecycle wiring: the Flutter counterpart of the `AppState` handling in
// javascript/oursprivacy-main.js (`_subscribeToAppState`).
//
// Two layers:
//  * [LifecycleSource] delivers raw app states. [FlutterLifecycleSource]
//    wraps `AppLifecycleListener`; tests drive [ManualLifecycleSource].
//  * [LifecycleStateMachine] turns the raw state stream into the session
//    calls React Native makes, so the orchestrator only maps a
//    [LifecycleTransition] to `MobileSession` methods.
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/widgets.dart'
    show
        AppLifecycleListener,
        AppLifecycleState,
        WidgetsBinding,
        WidgetsFlutterBinding;

/// SDK-owned mirror of Flutter's `AppLifecycleState`, so the orchestrator
/// and its tests do not depend on the framework enum.
enum OursAppState { resumed, inactive, hidden, paused, detached }

/// Maps a Flutter state to [OursAppState]. Null for null, or for a state
/// added by a later Flutter version.
OursAppState? oursAppStateFromFlutter(AppLifecycleState? state) {
  if (state == null) return null;
  if (state == AppLifecycleState.resumed) return OursAppState.resumed;
  if (state == AppLifecycleState.inactive) return OursAppState.inactive;
  if (state == AppLifecycleState.hidden) return OursAppState.hidden;
  if (state == AppLifecycleState.paused) return OursAppState.paused;
  if (state == AppLifecycleState.detached) return OursAppState.detached;
  return null;
}

/// Source of raw app lifecycle states.
abstract class LifecycleSource {
  /// Starts delivering every state change to [onChange], synchronously from
  /// the platform callback. Calling it again replaces the callback.
  void start(void Function(OursAppState state) onChange);

  /// The state the app is in now, or null when unknown (for example before
  /// [start], or before the engine reported a state).
  OursAppState? get currentState;

  /// Stops delivery. [start] may be called again afterwards.
  void dispose();
}

/// [LifecycleSource] backed by Flutter's `AppLifecycleListener`
/// (`onStateChange`, Flutter 3.13+).
///
/// Constructing it does not touch `WidgetsBinding`; [start] calls
/// `WidgetsFlutterBinding.ensureInitialized()` and attaches the listener,
/// and [currentState] reads `WidgetsBinding.instance.lifecycleState` only
/// after [start]. `AppLifecycleListener` does not replay the current state,
/// so read [currentState] when you need it (cold start).
class FlutterLifecycleSource implements LifecycleSource {
  FlutterLifecycleSource();

  AppLifecycleListener? _listener;
  WidgetsBinding? _binding;
  void Function(OursAppState state)? _onChange;

  @override
  void start(void Function(OursAppState state) onChange) {
    _onChange = onChange;
    if (_listener != null) return;
    final binding = WidgetsFlutterBinding.ensureInitialized();
    _binding = binding;
    _listener = AppLifecycleListener(
      binding: binding,
      onStateChange: _handle,
    );
  }

  void _handle(AppLifecycleState state) {
    final mapped = oursAppStateFromFlutter(state);
    final onChange = _onChange;
    if (mapped != null && onChange != null) onChange(mapped);
  }

  @override
  OursAppState? get currentState =>
      oursAppStateFromFlutter(_binding?.lifecycleState);

  @override
  void dispose() {
    _onChange = null;
    _listener?.dispose();
    _listener = null;
    _binding = null;
  }
}

/// [LifecycleSource] driven by hand, for tests.
@visibleForTesting
class ManualLifecycleSource implements LifecycleSource {
  ManualLifecycleSource([this.currentState]);

  void Function(OursAppState state)? _onChange;
  int startCount = 0;
  bool disposed = false;

  @override
  OursAppState? currentState;

  bool get isStarted => _onChange != null;

  @override
  void start(void Function(OursAppState state) onChange) {
    startCount++;
    disposed = false;
    _onChange = onChange;
  }

  /// Sets [currentState] and delivers [state] if started.
  void emit(OursAppState state) {
    currentState = state;
    _onChange?.call(state);
  }

  @override
  void dispose() {
    disposed = true;
    _onChange = null;
  }
}

/// Session work implied by a lifecycle state change.
enum LifecycleTransition {
  /// `resumed` after a [pause]: call `session.resume(at)`; if it returns
  /// false, call `session.foreground(automaticEnabled: ..., at: at)`. Then
  /// start the checkpoint timer.
  foregroundFromResume,

  /// `resumed` otherwise: `session.foreground(automaticEnabled: ..., at: at)`,
  /// then start the checkpoint timer.
  foreground,

  /// `inactive` while foregrounded: `session.pause(at: at)` and stop the
  /// checkpoint timer.
  pause,

  /// First of `hidden`/`paused`/`detached` on the way down:
  /// `session.background(at: at)`, stop the checkpoint timer, and flush if
  /// flush-on-background is enabled.
  background,
}

/// Pure converter from raw [OursAppState]s to [LifecycleTransition]s.
///
/// Flutter synthesizes intermediate states, so going down is
/// `resumed -> inactive -> hidden -> paused` and coming up is
/// `paused -> hidden -> inactive -> resumed`. Mapping:
///
/// | State      | Condition                          | Transition             |
/// | ---------- | ---------------------------------- | ---------------------- |
/// | `resumed`  | previous transition was [LifecycleTransition.pause] | [LifecycleTransition.foregroundFromResume] |
/// | `resumed`  | otherwise                          | [LifecycleTransition.foreground] |
/// | `inactive` | foregrounded                       | [LifecycleTransition.pause] |
/// | `inactive` | not foregrounded (on the way up)   | none                   |
/// | `hidden`, `paused`, `detached` | not yet backgrounded | [LifecycleTransition.background] |
/// | `hidden`, `paused`, `detached` | already backgrounded | none            |
///
/// * Background is edge-triggered: emitted once on the way down at the first
///   of `hidden`/`paused`/`detached`, never again until the next `resumed`,
///   and never on the way up. So flush runs once per backgrounding.
/// * `inactive` pauses on both iOS and Android (React Native pauses only on
///   iOS, so its Android emits a second app-open after a permission dialog).
///   Shade, dialog or app switcher and back is `inactive -> resumed`:
///   resume, no `$mobile_app_open`.
/// * Normal backgrounding is pause then background: the engagement fact is
///   emitted at pause and `background()` just clears the paused flag.
/// * A repeated state is ignored.
/// * The engine reports a full-screen native view controller (iOS) or
///   another in-app Activity (Android) covering the Flutter view with the
///   same states as leaving the app, so returning from one is a background
///   then a foreground with a new `$mobile_app_open`. Dart has no app-level
///   foreground signal to tell them apart.
///
/// [foregrounded] and [inactive] mirror RN's `_appForegrounded` and
/// `_appInactive`. Like RN, which updates them inside its serialized
/// handler, the orchestrator should call [handle] inside its serialized
/// operation (after capturing the time point synchronously in the
/// callback). Before init completes, buffer the latest state instead and
/// call [seed] once storage has loaded.
class LifecycleStateMachine {
  LifecycleStateMachine();

  OursAppState? _lastState;
  bool _foregrounded = false;
  bool _inactive = false;
  bool _backgrounded = false;

  /// RN `_appForegrounded`: the app is resumed and not paused.
  bool get foregrounded => _foregrounded;

  /// RN `_appInactive`: paused by `inactive` while foregrounded.
  bool get inactive => _inactive;

  /// A [LifecycleTransition.background] was emitted (or seeded) and no
  /// `resumed` has arrived since.
  bool get backgrounded => _backgrounded;

  /// The last state passed to [handle] or [seed].
  OursAppState? get lastState => _lastState;

  /// Sets the flags from a known current state without emitting a
  /// transition (cold start and re-init, RN `initialize`):
  /// `resumed` -> foregrounded; `inactive` -> inactive (RN sets
  /// `_appInactive = currentState === 'inactive'`); `hidden`/`paused`/
  /// `detached` -> backgrounded; null -> nothing known.
  void seed(OursAppState? state) {
    _lastState = state;
    _foregrounded = state == OursAppState.resumed;
    _inactive = state == OursAppState.inactive;
    _backgrounded = state == OursAppState.hidden ||
        state == OursAppState.paused ||
        state == OursAppState.detached;
  }

  /// Applies [state] and returns the transition to perform, or null.
  LifecycleTransition? handle(OursAppState state) {
    if (state == _lastState) return null;
    _lastState = state;
    switch (state) {
      case OursAppState.resumed:
        final wasInactive = _inactive;
        _foregrounded = true;
        _inactive = false;
        _backgrounded = false;
        return wasInactive
            ? LifecycleTransition.foregroundFromResume
            : LifecycleTransition.foreground;
      case OursAppState.inactive:
        if (!_foregrounded) return null;
        _foregrounded = false;
        _inactive = true;
        return LifecycleTransition.pause;
      case OursAppState.hidden:
      case OursAppState.paused:
      case OursAppState.detached:
        _foregrounded = false;
        _inactive = false;
        if (_backgrounded) return null;
        _backgrounded = true;
        return LifecycleTransition.background;
    }
  }
}
