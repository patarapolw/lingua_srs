import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The Linux runner is C++, which these tests cannot run, so they check its
/// source instead. Starting the app a second time must not open a second
/// copy on the same data folder (#104).
void main() {
  final source = File('linux/runner/my_application.cc').readAsStringSync();

  test('the application is unique, found by its application id', () {
    expect(source, isNot(contains('G_APPLICATION_NON_UNIQUE')));
    expect(source, contains('"application-id", APPLICATION_ID'));
  });

  test('a second activation presents the open window', () {
    final activate = source.indexOf('static void my_application_activate(');
    final existing = source.indexOf('gtk_application_get_windows(', activate);
    final present = source.indexOf('gtk_window_present(', activate);
    final create = source.indexOf('gtk_application_window_new(', activate);

    expect(activate, isNot(-1));
    expect(existing, isNot(-1));
    expect(present, isNot(-1));
    expect(create, isNot(-1));
    expect(existing, lessThan(create));
    expect(present, lessThan(create));
  });
}
