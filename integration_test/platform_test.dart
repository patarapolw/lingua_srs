// Runs on a real desktop build, not in `flutter test`'s host VM, to check what
// unit tests cannot: the OS keychain and, on macOS, the sandbox entitlements.
//
//   flutter test integration_test -d macos
//   flutter test integration_test -d linux   # needs an unlocked keyring
//
// CI runs it in .github/workflows/desktop.yml.
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:lingua_srs/services/secret_storage.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const key = 'lingua_srs_integration_test_secret';
  const storage = PlatformSecretStorage();

  tearDown(() => storage.delete(key));

  test('stores, reads back and deletes a secret in the OS keychain', () async {
    await storage.delete(key);
    expect(await storage.read(key), isNull);

    await storage.write(key, 'first value');
    expect(await storage.read(key), 'first value');

    await storage.write(key, 'second value');
    expect(await storage.read(key), 'second value');

    await storage.delete(key);
    expect(await storage.read(key), isNull);
  });

  test('can make an outgoing HTTPS request', () async {
    // On macOS the app sandbox blocks this without the
    // com.apple.security.network.client entitlement.
    final response = await http
        .get(Uri.parse('https://example.com/'))
        .timeout(const Duration(seconds: 30));
    expect(response.statusCode, 200);
  });
}
