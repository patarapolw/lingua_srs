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

void setUpSecretStorage() {
  StorageService.secretStorageForTesting = MemorySecretStorage();
}
