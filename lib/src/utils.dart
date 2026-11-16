import 'dart:math';

final Random _random = Random.secure();

/// RFC 4122 version 4 UUID, lowercase, from a cryptographically secure source.
String uuidv4() {
  final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// ISO-8601 UTC timestamp with exactly three fractional digits, from epoch ms,
/// matching JavaScript `new Date(ms).toISOString()`.
String isoFromMilliseconds(int ms) {
  final t = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
  String two(int v) => v.toString().padLeft(2, '0');
  final year = t.year.toString().padLeft(4, '0');
  final millis = t.millisecond.toString().padLeft(3, '0');
  return '$year-${two(t.month)}-${two(t.day)}T${two(t.hour)}:'
      '${two(t.minute)}:${two(t.second)}.${millis}Z';
}
