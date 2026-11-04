import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/services/sync_account_crypto.dart';

// The auth key that Argon2id and HKDF give for the test email and password
// below. It is a known-answer vector that fails if key derivation ever
// changes, so existing accounts could no longer sign in. It is not a secret.
const _knownAuthKey = 'IHoVHQEpjK2FZWx-A6pY0n0IWCDneK--yKvPT8svT8Y'; // ggignore

void main() {
  test(
    'derives an auth key and wraps a data key that can be unwrapped',
    () async {
      final keys = await SyncAccountCrypto.deriveKeys(
        email: 'reader@example.com',
        password: 'TEST-ONLY-CRYPTO-PASSWORD',
      );
      final wrapped = await SyncAccountCrypto.createWrappedDataKey(
        keys.wrapKey,
      );
      final dataKey = await SyncAccountCrypto.unwrapDataKey(
        wrappedDataKey: wrapped,
        wrapKey: keys.wrapKey,
      );

      expect(keys.authKey, hasLength(43));
      expect(keys.authKey, _knownAuthKey);
      expect(dataKey, hasLength(32));
      expect(wrapped, isNot(contains('=')));
    },
  );

  test('rejects a wrapped key encrypted for a different password', () async {
    final first = await SyncAccountCrypto.deriveKeys(
      email: 'reader@example.com',
      password: 'TEST-ONLY-CRYPTO-PASSWORD',
    );
    final second = await SyncAccountCrypto.deriveKeys(
      email: 'reader@example.com',
      password: 'TEST-ONLY-OTHER-CRYPTO-PASSWORD',
    );
    final wrapped = await SyncAccountCrypto.createWrappedDataKey(first.wrapKey);

    await expectLater(
      SyncAccountCrypto.unwrapDataKey(
        wrappedDataKey: wrapped,
        wrapKey: second.wrapKey,
      ),
      throwsFormatException,
    );
  });
}
