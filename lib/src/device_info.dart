// Port of the Platform / Dimensions part of `getDefaultProperties` in
// javascript/oursprivacy-main.js (React Native SDK).
//
// Device fields follow the native SDKs rather than React Native where they
// differ:
// - iOS: `device_vendor: 'Apple'`, `device_model` from `hw.machine` (the
//   `uname` machine string, e.g. `iPhone15,2`; the Mac's `hw.model` for an
//   iOS app on a Mac), `os_version` parsed from
//   `Platform.operatingSystemVersion` ("Version 17.5 (Build …)" → "17.5").
// - Android: `device_vendor` = Build.MANUFACTURER, `device_model` =
//   Build.MODEL, `os_version` = Build.VERSION.RELEASE, all read with
//   `__system_property_get` (React Native sends the API level instead).
// Every native read is failure-tolerant: a failed read omits the field.
// dart:io and dart:ffi are only imported on platforms that have them, so the
// package still compiles for web.
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb, visibleForTesting;

import 'device_info_common.dart';
import 'device_info_stub.dart' if (dart.library.io) 'device_info_io.dart'
    as native;
import 'version.dart';

export 'device_info_common.dart'
    show parseAppleOSVersion, resolveAppleDeviceModel;

/// Logical screen size in pixels.
typedef OursPrivacyScreenSize = ({double width, double height});

/// Values for [OursPrivacyDeviceInfo.os].
abstract final class OursPrivacyOS {
  static const String ios = 'ios';
  static const String android = 'android';
  static const String web = 'web';
  static const String macos = 'macos';
  static const String windows = 'windows';
  static const String linux = 'linux';
  static const String fuchsia = 'fuchsia';
}

/// Device facts used for `defaultProperties` and for the mobile-platform
/// gate. Tests can supply a [StaticDeviceInfo] to force iOS, Android, web or
/// desktop.
abstract class OursPrivacyDeviceInfo {
  const OursPrivacyDeviceInfo();

  /// The process default: [debugOverride] when set, otherwise the real
  /// platform.
  static OursPrivacyDeviceInfo get current =>
      debugOverride ?? (_platform ??= PlatformDeviceInfo());
  static PlatformDeviceInfo? _platform;

  /// Test hook: when non-null, [current] returns this.
  @visibleForTesting
  static OursPrivacyDeviceInfo? debugOverride;

  /// Test hook: clears [debugOverride] and the cached platform reader.
  static void resetForTesting() {
    debugOverride = null;
    _platform = null;
  }

  /// Lower-case platform name, one of [OursPrivacyOS] (React Native's
  /// `Platform.OS` vocabulary).
  String get os;

  /// True only for an iOS or Android app build. A Flutter web build running
  /// in a mobile browser is not a mobile platform, so it never emits mobile
  /// analytics metadata.
  bool get isMobilePlatform =>
      os == OursPrivacyOS.ios || os == OursPrivacyOS.android;

  /// `os_name` on the wire: `iOS`, `Android`, or [os] for other platforms.
  String get osName => os == OursPrivacyOS.ios
      ? 'iOS'
      : os == OursPrivacyOS.android
          ? 'Android'
          : os;

  String? get osVersion;
  String? get deviceVendor;
  String? get deviceModel;

  /// Current logical screen size, or null when unknown. Read per event
  /// because view metrics can be empty early in startup.
  OursPrivacyScreenSize? get screenSize;

  /// Device part of every event's `defaultProperties`, in React Native's key
  /// order. Empty or unavailable values are omitted, as are zero screen
  /// dimensions.
  Map<String, Object?> defaultProperties() {
    final props = <String, Object?>{
      'device_type': 'mobile',
      'os_name': osName,
    };
    final version = osVersion;
    if (version != null && version.isNotEmpty) props['os_version'] = version;
    props['version'] = oursPrivacyLibraryVersion;
    final size = screenSize;
    if (size != null) {
      final width = _roundDimension(size.width);
      final height = _roundDimension(size.height);
      if (width != null) props['screen_width'] = width;
      if (height != null) props['screen_height'] = height;
    }
    final vendor = deviceVendor;
    if (vendor != null && vendor.isNotEmpty) props['device_vendor'] = vendor;
    final model = deviceModel;
    if (model != null && model.isNotEmpty) props['device_model'] = model;
    return props;
  }

  static int? _roundDimension(double value) {
    if (!value.isFinite || value <= 0) return null;
    final rounded = value.round();
    return rounded > 0 ? rounded : null;
  }
}

/// Fixed device facts, for tests and for hosts that want to control them.
class StaticDeviceInfo extends OursPrivacyDeviceInfo {
  const StaticDeviceInfo({
    required this.os,
    this.osVersion,
    this.deviceVendor,
    this.deviceModel,
    this.screenSize,
  });

  /// iPhone-like defaults.
  const StaticDeviceInfo.ios({
    this.osVersion = '17.5',
    this.deviceVendor = 'Apple',
    this.deviceModel = 'iPhone15,2',
    this.screenSize = (width: 375.0, height: 812.0),
  }) : os = OursPrivacyOS.ios;

  /// Android-phone-like defaults.
  const StaticDeviceInfo.android({
    this.osVersion = '14',
    this.deviceVendor = 'Google',
    this.deviceModel = 'Pixel 8',
    this.screenSize = (width: 412.0, height: 915.0),
  }) : os = OursPrivacyOS.android;

  const StaticDeviceInfo.web({this.screenSize})
      : os = OursPrivacyOS.web,
        osVersion = null,
        deviceVendor = null,
        deviceModel = null;

  @override
  final String os;
  @override
  final String? osVersion;
  @override
  final String? deviceVendor;
  @override
  final String? deviceModel;
  @override
  final OursPrivacyScreenSize? screenSize;
}

/// Reads the running platform. Native facts are read once, lazily, and
/// cached; the screen size is read on every call.
class PlatformDeviceInfo extends OursPrivacyDeviceInfo {
  PlatformDeviceInfo();

  NativeDeviceFacts? _facts;

  NativeDeviceFacts get _native {
    final cached = _facts;
    if (cached != null) return cached;
    NativeDeviceFacts facts;
    try {
      facts = native.readNativeDeviceFacts();
    } catch (_) {
      facts = const NativeDeviceFacts();
    }
    return _facts = facts;
  }

  @override
  String get os {
    if (kIsWeb) return OursPrivacyOS.web;
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
        return OursPrivacyOS.ios;
      case TargetPlatform.android:
        return OursPrivacyOS.android;
      case TargetPlatform.macOS:
        return OursPrivacyOS.macos;
      case TargetPlatform.windows:
        return OursPrivacyOS.windows;
      case TargetPlatform.linux:
        return OursPrivacyOS.linux;
      case TargetPlatform.fuchsia:
        return OursPrivacyOS.fuchsia;
    }
  }

  // Native facts are only meaningful when the binary really runs on the
  // platform `os` reports (tests can override defaultTargetPlatform).
  bool get _nativeMatchesOS => _native.os == os;

  @override
  String? get osVersion => _nativeMatchesOS ? _native.osVersion : null;

  @override
  String? get deviceVendor {
    if (os == OursPrivacyOS.ios) return 'Apple';
    return _nativeMatchesOS ? _native.deviceVendor : null;
  }

  @override
  String? get deviceModel => _nativeMatchesOS ? _native.deviceModel : null;

  @override
  OursPrivacyScreenSize? get screenSize {
    try {
      final views = ui.PlatformDispatcher.instance.views;
      if (views.isEmpty) return null;
      return screenSizeOf(views.first, os);
    } catch (_) {
      return null;
    }
  }

  /// Logical screen size for [view] on [os], like React Native's
  /// `Dimensions.get('screen')`.
  ///
  /// - Android: the display (maximum window metrics in dp).
  /// - iOS: the view. Flutter fills the iOS display from
  ///   `UIScreen.nativeBounds`, which is fixed in portrait and is the
  ///   physical panel, so it disagrees with `UIScreen.bounds` (what React
  ///   Native and the iOS SDK send) in landscape, on Plus models and under
  ///   Display Zoom. A full-screen app's view is `UIScreen.bounds`.
  @visibleForTesting
  static OursPrivacyScreenSize? screenSizeOf(ui.FlutterView view, String os) {
    if (os != OursPrivacyOS.ios) {
      try {
        final display = view.display;
        final ratio = display.devicePixelRatio;
        if (ratio > 0 && display.size.width > 0 && display.size.height > 0) {
          return (
            width: display.size.width / ratio,
            height: display.size.height / ratio,
          );
        }
      } catch (_) {
        // Fall back to the view's own size below.
      }
    }
    final ratio = view.devicePixelRatio;
    if (ratio <= 0) return null;
    return (
      width: view.physicalSize.width / ratio,
      height: view.physicalSize.height / ratio,
    );
  }
}
