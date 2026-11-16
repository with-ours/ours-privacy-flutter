// Runs in its own isolate (test file), with nothing initializing a Flutter
// binding first: `testWidgets` initializes the binding when it is declared,
// so this check cannot share a file with widget tests.
import 'package:flutter/widgets.dart' show WidgetsBinding;
import 'package:flutter_test/flutter_test.dart';
import 'package:ours_privacy/ours_privacy.dart';

void main() {
  test('OursPrivacy() does not touch the Flutter binding', () async {
    final op = OursPrivacy();
    await op.close();
    expect(() => WidgetsBinding.instance, throwsA(anything));
  });
}
