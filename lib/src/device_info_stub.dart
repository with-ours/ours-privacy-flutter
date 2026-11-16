// Native device reads for platforms without dart:io (web): nothing is known.
import 'device_info_common.dart';

export 'device_info_common.dart' show NativeDeviceFacts;

NativeDeviceFacts readNativeDeviceFacts() => const NativeDeviceFacts();
