// Test hooks for the Ours Privacy SDK. Not exported by
// `package:ours_privacy/ours_privacy.dart`; tests import this file directly:
//
//   import 'package:ours_privacy/src/testing.dart';
//
// This file exists for this package's own tests and is not covered by
// semantic versioning: it can change or disappear in any release. Apps
// should test through the public API instead (`init(storage:
// InMemoryStorage(), httpClient: ...)` and `close()` in `tearDown`).
//
// It provides the seams React Native's tests get from Jest module mocks:
// - [createOursPrivacyForTesting]: an `OursPrivacy` whose next `init` uses
//   the given [OursPrivacyEnvironment] (device info / platform, lifecycle
//   source, wall and monotonic clocks, timer factory, network).
// - [setDefaultOursPrivacyEnvironmentForTesting]: the same for every
//   `OursPrivacy()` created without its own environment.
// - [oursPrivacyImplOf]: the instance's current `OursPrivacyMain` (RN tests'
//   `op.oursprivacyImpl`), to inspect its state or call the token-taking
//   methods (null before `init` and after `close`).
// - [resetOursPrivacyForTesting]: forgets every process-wide registry (queue,
//   persistence, network, config, device info override, default environment,
//   log sink), like `jest.resetModules()`.
//
// With fake_async, pass clocks derived from the fake clock, for example:
//   wallNow: () => start + async.elapsed.inMilliseconds,
//   monotonicNow: () => async.elapsed.inMilliseconds,
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../ours_privacy.dart';
import 'config.dart';
import 'core.dart';
import 'device_info.dart';
import 'logger.dart';
import 'network.dart';
import 'oursprivacy_main.dart';
import 'persistent.dart';
import 'queue.dart';

export 'device_info.dart'
    show OursPrivacyDeviceInfo, OursPrivacyOS, StaticDeviceInfo;
export 'lifecycle.dart'
    show LifecycleSource, ManualLifecycleSource, OursAppState;
export 'logger.dart' show OursPrivacyLogLevel, oursPrivacyLogSink;
export 'oursprivacy_main.dart'
    show OursPrivacyEnvironment, OursPrivacyInitOptions, OursPrivacyMain;

/// Creates an [OursPrivacy] whose `init` calls use [environment].
@visibleForTesting
OursPrivacy createOursPrivacyForTesting(OursPrivacyEnvironment environment) {
  final op = OursPrivacy();
  setOursPrivacyEnvironmentForTesting(op, environment);
  return op;
}

/// Sets the environment [op]'s next `init` uses (null restores the default).
@visibleForTesting
void setOursPrivacyEnvironmentForTesting(
  OursPrivacy op,
  OursPrivacyEnvironment? environment,
) {
  oursPrivacyEnvironments[op] = environment;
}

/// Sets the environment for every [OursPrivacy] without its own (null
/// restores the real platform).
@visibleForTesting
void setDefaultOursPrivacyEnvironmentForTesting(
  OursPrivacyEnvironment? environment,
) {
  oursPrivacyDefaultEnvironment = environment;
}

/// The implementation behind [op] after its latest `init`, or null before
/// `init` and after `close`.
@visibleForTesting
OursPrivacyMain? oursPrivacyImplOf(OursPrivacy op) => oursPrivacyImpls[op];

/// Resets every process-wide registry the SDK keeps. Call in `setUp`.
@visibleForTesting
void resetOursPrivacyForTesting() {
  // Same as core.dart's resetOursPrivacyFoundationForTesting().
  OursPrivacyCore.resetForTesting();
  OursPrivacyQueueManager.resetForTesting();
  OursPrivacyPersistent.resetForTesting();
  OursPrivacyNetwork.resetForTesting();
  OursPrivacyConfig.instance.resetForTesting();
  OursPrivacyDeviceInfo.resetForTesting();
  oursPrivacyDefaultEnvironment = null;
  oursPrivacyLogSink = null;
}
