import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/services/secret_storage.dart';

/// Whether the plist at [path] sets boolean [key] to true.
bool _entitlementEnabled(String path, String key) {
  final plist = File(path).readAsStringSync();
  return RegExp('<key>${RegExp.escape(key)}</key>\\s*<true/>').hasMatch(plist);
}

void main() {
  const entitlements = [
    'macos/Runner/DebugProfile.entitlements',
    'macos/Runner/Release.entitlements',
  ];

  for (final path in entitlements) {
    test('$path allows outgoing connections', () {
      // The app sandbox blocks outgoing connections without this, so sync,
      // DeepSeek, audio and images would all fail on macOS.
      expect(
        _entitlementEnabled(path, 'com.apple.security.network.client'),
        isTrue,
      );
    });
  }

  test('macOS secrets need no keychain-access-groups entitlement', () {
    expect(
      PlatformSecretStorage.macOsOptions.usesDataProtectionKeychain,
      isFalse,
    );
  });
}
