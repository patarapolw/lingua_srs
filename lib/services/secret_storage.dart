import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract interface class SecretStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class PlatformSecretStorage implements SecretStorage {
  const PlatformSecretStorage();

  /// macOS uses the login keychain, not the data protection keychain. The
  /// data protection keychain needs the `keychain-access-groups` entitlement,
  /// which needs a provisioning profile, so an unsigned or ad-hoc signed build
  /// could not store anything (`errSecMissingEntitlement`).
  static const MacOsOptions macOsOptions = MacOsOptions(
    usesDataProtectionKeychain: false,
  );

  static const FlutterSecureStorage _storage = FlutterSecureStorage(
    mOptions: macOsOptions,
  );

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}
