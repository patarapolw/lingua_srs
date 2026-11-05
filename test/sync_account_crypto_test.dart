import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/services/sync_account_crypto.dart';

import 'odd_text.dart';

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

  group('password normalization', () {
    test('equivalent spellings are the same password', () {
      // An accent typed as one character or as a letter and a combining mark,
      // which different platforms and keyboards produce.
      const composed = 'caf\u00e9 \u00c5ngstr\u00f6m';
      const decomposed = 'cafe\u0301 A\u030angstro\u0308m';

      expect(SyncAccountCrypto.normalizePassword(decomposed), composed);
      expect(SyncAccountCrypto.normalizePassword(composed), composed);
      // Full-width letters and digits, and a ligature.
      expect(
        SyncAccountCrypto.normalizePassword('\uff21\uff22\uff23\uff11\uff12'),
        'ABC12',
      );
      expect(SyncAccountCrypto.normalizePassword('o\ufb03ce'), 'office');
    });

    test('plain ASCII is unchanged, so existing accounts are not affected', () {
      for (var seed = 0; seed < 200; seed++) {
        final random = Random(seed);
        final password = String.fromCharCodes([
          for (var i = 0; i < 1 + random.nextInt(60); i++)
            0x20 + random.nextInt(0x7f - 0x20),
        ]);

        expect(
          SyncAccountCrypto.normalizePassword(password),
          password,
          reason: 'seed $seed',
        );
      }
    });

    test('normalizing twice changes nothing, for any characters', () {
      for (var seed = 0; seed < 300; seed++) {
        final once = SyncAccountCrypto.normalizePassword(oddText(Random(seed)));

        expect(
          SyncAccountCrypto.normalizePassword(once),
          once,
          reason: 'seed $seed, code points ${hex(once)}',
        );
      }
    });

    test('spellings of a password derive the same keys', () async {
      final composed = await SyncAccountCrypto.deriveKeys(
        email: 'reader@example.com',
        password: 'TEST-ONLY caf\u00e9',
      );
      final decomposed = await SyncAccountCrypto.deriveKeys(
        email: 'reader@example.com',
        password: 'TEST-ONLY cafe\u0301',
      );

      expect(decomposed.authKey, composed.authKey);
      expect(decomposed.wrapKey, composed.wrapKey);
    });
  });
}
