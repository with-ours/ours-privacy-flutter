// Native device reads for dart:io platforms. Every read is failure-tolerant:
// any error (missing symbol, unexpected platform, FFI failure) omits that
// field.
import 'dart:ffi';
import 'dart:io' show Platform;

import 'package:ffi/ffi.dart';

import 'device_info_common.dart';

export 'device_info_common.dart' show NativeDeviceFacts;

NativeDeviceFacts readNativeDeviceFacts() {
  if (Platform.isIOS) {
    return NativeDeviceFacts(
      os: 'ios',
      osVersion: _guard(() => parseAppleOSVersion(
            Platform.operatingSystemVersion,
          )),
      deviceVendor: 'Apple',
      deviceModel: resolveAppleDeviceModel(
        machine: _guard(() => _sysctlString('hw.machine')),
        readModel: () => _guard(() => _sysctlString('hw.model')),
        isSimulator:
            _guard(() => Platform.environment['SIMULATOR_DEVICE_NAME']) != null,
      ),
    );
  }
  if (Platform.isAndroid) {
    final properties = _AndroidSystemProperties.open();
    String? read(List<String> names) {
      if (properties == null) return null;
      for (final name in names) {
        final value = _guard(() => properties.get(name));
        if (value != null) return value;
      }
      return null;
    }

    return NativeDeviceFacts(
      os: 'android',
      // Build.VERSION.RELEASE (the user-facing version, e.g. "14").
      osVersion: read(const ['ro.build.version.release']),
      // Build.MANUFACTURER, falling back to Build.BRAND like React Native.
      deviceVendor: read(const ['ro.product.manufacturer', 'ro.product.brand']),
      // Build.MODEL.
      deviceModel: read(const ['ro.product.model']),
    );
  }
  if (Platform.isMacOS) {
    return NativeDeviceFacts(
      os: 'macos',
      osVersion: _guard(() => parseAppleOSVersion(
            Platform.operatingSystemVersion,
          )),
    );
  }
  return NativeDeviceFacts(os: _guard(() => Platform.operatingSystem));
}

String? _guard(String? Function() read) {
  try {
    return nonEmpty(read());
  } catch (_) {
    return null;
  }
}

typedef _SysctlByNameNative = Int32 Function(
    Pointer<Utf8>, Pointer<Void>, Pointer<Size>, Pointer<Void>, Size);
typedef _SysctlByName = int Function(
    Pointer<Utf8>, Pointer<Void>, Pointer<Size>, Pointer<Void>, int);

/// `sysctlbyname(name)` as a string (Darwin only).
String? _sysctlString(String name) {
  final sysctlbyname = DynamicLibrary.process()
      .lookupFunction<_SysctlByNameNative, _SysctlByName>('sysctlbyname');
  final cName = name.toNativeUtf8();
  final size = calloc<Size>();
  Pointer<Uint8>? buffer;
  try {
    if (sysctlbyname(cName, nullptr, size, nullptr, 0) != 0) return null;
    final length = size.value;
    if (length <= 0 || length > 4096) return null;
    buffer = calloc<Uint8>(length + 1);
    if (sysctlbyname(cName, buffer.cast(), size, nullptr, 0) != 0) {
      return null;
    }
    return buffer.cast<Utf8>().toDartString();
  } finally {
    calloc.free(cName);
    calloc.free(size);
    if (buffer != null) calloc.free(buffer);
  }
}

typedef _PropertyGetNative = Int32 Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _PropertyGet = int Function(Pointer<Utf8>, Pointer<Utf8>);

/// Reads Android system properties through bionic's
/// `__system_property_get`, the same source as android.os.Build.
class _AndroidSystemProperties {
  _AndroidSystemProperties(this._get);

  /// PROP_VALUE_MAX from <sys/system_properties.h>.
  static const int _valueMax = 92;

  final _PropertyGet _get;

  static _AndroidSystemProperties? open() {
    for (final library in _libraries()) {
      try {
        return _AndroidSystemProperties(
          library.lookupFunction<_PropertyGetNative, _PropertyGet>(
            '__system_property_get',
          ),
        );
      } catch (_) {
        // Try the next library.
      }
    }
    return null;
  }

  static Iterable<DynamicLibrary> _libraries() sync* {
    try {
      yield DynamicLibrary.open('libc.so');
    } catch (_) {}
    try {
      yield DynamicLibrary.process();
    } catch (_) {}
  }

  String? get(String name) {
    final cName = name.toNativeUtf8();
    final value = calloc<Uint8>(_valueMax + 1);
    try {
      final length = _get(cName, value.cast());
      if (length <= 0) return null;
      return value.cast<Utf8>().toDartString();
    } finally {
      calloc.free(cName);
      calloc.free(value);
    }
  }
}
