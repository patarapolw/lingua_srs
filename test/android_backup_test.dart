import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Android's own backup must not copy the app's data to the Google account
/// or to a new phone: the secrets in secure storage stay on the device, and
/// restored secure storage cannot be decrypted on another device. These tests
/// read the manifest and the backup rules, which they cannot run.
void main() {
  final manifest = File('android/app/src/main/AndroidManifest.xml')
      .readAsStringSync();
  final rules = File('android/app/src/main/res/xml/data_extraction_rules.xml')
      .readAsStringSync();

  const domains = [
    'root',
    'file',
    'database',
    'sharedpref',
    'external',
    'device_root',
    'device_file',
    'device_database',
    'device_sharedpref',
  ];

  String application() {
    final start = manifest.indexOf('<application');
    final end = manifest.indexOf('>', start);
    expect(start, isNot(-1));
    return manifest.substring(start, end);
  }

  String section(String name) {
    final start = rules.indexOf('<$name');
    final end = rules.indexOf('</$name>', start);
    expect(start, isNot(-1), reason: 'No <$name> in the backup rules');
    expect(end, isNot(-1), reason: 'No </$name> in the backup rules');
    return rules.substring(start, end);
  }

  test('the application turns off backup', () {
    expect(application(), contains('android:allowBackup="false"'));
  });

  test('the application uses the data extraction rules', () {
    expect(
      application(),
      contains('android:dataExtractionRules="@xml/data_extraction_rules"'),
    );
  });

  test('the application has no full backup content that includes files', () {
    expect(application(), isNot(contains('android:fullBackupContent="@')));
  });

  for (final name in ['cloud-backup', 'device-transfer']) {
    test('$name excludes every domain and includes nothing', () {
      final body = section(name);
      expect(body, isNot(contains('<include')));
      for (final domain in domains) {
        expect(
          body,
          contains('<exclude domain="$domain" path="."/>'),
          reason: '$name does not exclude $domain',
        );
      }
    });
  }
}
