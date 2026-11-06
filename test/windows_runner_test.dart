import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The Windows runner is C++, which these tests cannot run, so they check
/// its source instead. Starting the app a second time must not open a
/// second copy on the same data folder (#104); the behaviour itself was
/// checked by hand on Windows.
void main() {
  final source = File('windows/runner/main.cpp').readAsStringSync();

  test('a second start is stopped before it opens a window', () {
    final guard = source.indexOf('ERROR_ALREADY_EXISTS');
    final window = source.indexOf('window.Create(');

    expect(source, contains('CreateMutex('));
    expect(guard, isNot(-1));
    expect(window, isNot(-1));
    expect(guard, lessThan(window));
  });

  test('the guard is named after the app, per Windows session', () {
    expect(source, contains(r'L"Local\\cc.polv.lingua.srs.single-instance"'));
  });

  test('the copy already running is brought to the front', () {
    expect(source, contains('ShowRunningInstance();'));
    expect(source, contains('SetForegroundWindow('));
  });
}
