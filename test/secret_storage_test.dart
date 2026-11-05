import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/services/storage_service.dart';
import 'package:lingua_srs/services/sync_pairing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'secret_storage_mock.dart';

void main() {
  late MemorySecretStorage secrets;

  setUp(() {
    secrets = MemorySecretStorage();
    StorageService.secretStorageForTesting = secrets;
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'stores the DeepSeek API key securely and removes it when cleared',
    () async {
      await StorageService.saveDeepSeekApiKey(' secret-key ');

      expect(await StorageService.loadDeepSeekApiKey(), 'secret-key');
      expect(secrets.values['lingua_srs_deepseek_api_key'], 'secret-key');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('lingua_srs_deepseek_api_key'), isNull);

      await StorageService.saveDeepSeekApiKey('');

      expect(await StorageService.loadDeepSeekApiKey(), isEmpty);
      expect(secrets.values, isEmpty);
    },
  );

  test('migrates the legacy DeepSeek API key out of preferences', () async {
    SharedPreferences.setMockInitialValues({
      'lingua_srs_deepseek_api_key': 'legacy-key',
    });

    expect(await StorageService.loadDeepSeekApiKey(), 'legacy-key');
    expect(secrets.values['lingua_srs_deepseek_api_key'], 'legacy-key');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('lingua_srs_deepseek_api_key'), isNull);
  });

  test(
    'stores sync sign-in credentials securely and deletes them on sign-out',
    () async {
      SyncPairing.defaultEndpoint = Uri.parse('https://sync.example.com');
      addTearDown(() => SyncPairing.defaultEndpoint = null);
      final pairing = SyncPairing(
        email: 'reader@example.com',
        password: 'passphrase',
      );

      await StorageService.saveSyncPairing(pairing);

      expect(await StorageService.loadSyncPairing(), pairing);
      expect(secrets.values['lingua_srs_sync_pairing'], pairing.link);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('lingua_srs_sync_pairing'), isNull);

      await StorageService.saveSyncPairing(null);

      expect(await StorageService.loadSyncPairing(), isNull);
      expect(secrets.values, isEmpty);
    },
  );

  test('migrates legacy sync credentials out of preferences', () async {
    SyncPairing.defaultEndpoint = Uri.parse('https://sync.example.com');
    addTearDown(() => SyncPairing.defaultEndpoint = null);
    final pairing = SyncPairing(
      email: 'reader@example.com',
      password: 'passphrase',
    );
    SharedPreferences.setMockInitialValues({
      'lingua_srs_sync_pairing': pairing.link,
    });

    expect(await StorageService.loadSyncPairing(), pairing);
    expect(secrets.values['lingua_srs_sync_pairing'], pairing.link);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('lingua_srs_sync_pairing'), isNull);
  });
}
