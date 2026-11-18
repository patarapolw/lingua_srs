import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Android's own backup copies lessons and progress to the Google account
/// and to a new phone, but never secure storage: the secrets stay on the
/// device, and restored secure storage cannot be decrypted on another device.
/// These tests read the manifest and the backup rules, which they cannot run.
void main() {
  final manifest = File('android/app/src/main/AndroidManifest.xml')
      .readAsStringSync();
  final extractionRules = File(
    'android/app/src/main/res/xml/data_extraction_rules.xml',
  ).readAsStringSync();
  final backupRules = File('android/app/src/main/res/xml/backup_rules.xml')
      .readAsStringSync();

  // Everything that is backed up, and nothing else.
  const includes = [
    '<include domain="sharedpref" path="FlutterSharedPreferences.xml"/>',
    '<include domain="file" path="lesson_markdown"/>',
  ];

  String application() {
    final start = manifest.indexOf('<application');
    final end = manifest.indexOf('>', start);
    expect(start, isNot(-1));
    return manifest.substring(start, end);
  }

  /// The rules between `<name>` and `</name>`, without the comments.
  String section(String rules, String name) {
    final start = rules.indexOf('<$name');
    final end = rules.indexOf('</$name>', start);
    expect(start, isNot(-1), reason: 'No <$name> in the backup rules');
    expect(end, isNot(-1), reason: 'No </$name> in the backup rules');
    return rules
        .substring(start, end)
        .replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');
  }

  void expectOnlyIncludes(String rules, String name) {
    final body = section(rules, name);
    final found = RegExp(r'<(include|exclude)\b[^>]*/>')
        .allMatches(body)
        .map((match) => match[0])
        .toList();
    expect(found, unorderedEquals(includes), reason: name);
  }

  test('the application backs up with rules for every Android version', () {
    final attributes = application();
    expect(attributes, contains('android:allowBackup="true"'));
    expect(
      attributes,
      contains('android:fullBackupContent="@xml/backup_rules"'),
    );
    expect(
      attributes,
      contains('android:dataExtractionRules="@xml/data_extraction_rules"'),
    );
  });

  for (final name in ['cloud-backup', 'device-transfer']) {
    test('$name includes only preferences and lesson Markdown', () {
      expectOnlyIncludes(extractionRules, name);
    });
  }

  test('full backup content includes only preferences and lesson Markdown', () {
    expectOnlyIncludes(backupRules, 'full-backup-content');
  });

  test('no rule names secure storage', () {
    for (final rules in [extractionRules, backupRules]) {
      final withoutComments = rules.replaceAll(
        RegExp(r'<!--.*?-->', dotAll: true),
        '',
      );
      expect(withoutComments, isNot(contains('FlutterSecure')));
    }
  });
}
