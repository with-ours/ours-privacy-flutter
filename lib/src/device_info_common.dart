// Shared by device_info.dart and its conditional native readers.

/// Facts read from the operating system. [os] is the platform the binary
/// actually runs on (React Native `Platform.OS` vocabulary), or null when
/// unknown (web).
class NativeDeviceFacts {
  const NativeDeviceFacts({
    this.os,
    this.osVersion,
    this.deviceVendor,
    this.deviceModel,
  });

  final String? os;
  final String? osVersion;
  final String? deviceVendor;
  final String? deviceModel;
}

/// Parses the iOS/macOS `Platform.operatingSystemVersion` string
/// ("Version 17.5 (Build 21F79)" → "17.5"). Returns a bare dotted version
/// unchanged and null for anything else.
String? parseAppleOSVersion(String? raw) {
  if (raw == null) return null;
  final match = RegExp(r'Version\s+(\d+(?:\.\d+)*)').firstMatch(raw);
  if (match != null) return match.group(1);
  final trimmed = raw.trim();
  return RegExp(r'^\d+(?:\.\d+)*$').hasMatch(trimmed) ? trimmed : null;
}

/// The iOS `device_model`. Normally [machine] (`hw.machine`, the `uname`
/// machine string the iOS SDK sends, e.g. `iPhone15,2`). An iPhone or iPad
/// app running on an Apple-silicon Mac sees the CPU architecture there
/// (`arm64`); like the iOS SDK, report the Mac model (`hw.model`, e.g.
/// `Mac16,7`) instead. The simulator also sees the architecture, and the iOS
/// SDK sends it unchanged, so [isSimulator] keeps it.
String? resolveAppleDeviceModel({
  required String? machine,
  required String? Function() readModel,
  required bool isSimulator,
}) {
  if (machine == null || isSimulator) return machine;
  if (machine != 'arm64' && machine != 'arm64e' && machine != 'x86_64') {
    return machine;
  }
  String? model;
  try {
    model = nonEmpty(readModel());
  } catch (_) {
    model = null;
  }
  return model != null && model.startsWith('Mac') ? model : machine;
}

/// Trims [value] and maps empty to null.
String? nonEmpty(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}
