import 'package:lingua_srs/services/secret_storage.dart';
import 'package:lingua_srs/services/storage_service.dart';

class MemorySecretStorage implements SecretStorage {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

/// A keychain that fails, like a locked or missing keyring on Linux.
class BrokenSecretStorage implements SecretStorage {
  const BrokenSecretStorage({this.failReads = true, this.failWrites = true});

  final bool failReads;
  final bool failWrites;

  @override
  Future<String?> read(String key) async {
    if (failReads) throw StateError('keyring is locked');
    return null;
  }

  @override
  Future<void> write(String key, String value) async {
    if (failWrites) throw StateError('keyring is locked');
  }

  @override
  Future<void> delete(String key) async {
    if (failWrites) throw StateError('keyring is locked');
  }
}

void setUpSecretStorage() {
  StorageService.secretStorageForTesting = MemorySecretStorage();
}
