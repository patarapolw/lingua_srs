import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// Collects what the code under test passes to [debugPrint] instead of
/// printing it, so a test that expects a warning can check it without
/// filling the test output. The usual [debugPrint] is put back after the test.
List<String> captureDebugPrints() {
  final printed = <String>[];
  final original = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) {
    if (message != null) printed.add(message);
  };
  addTearDown(() => debugPrint = original);
  return printed;
}
