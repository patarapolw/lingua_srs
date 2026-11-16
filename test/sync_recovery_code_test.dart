import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/services/sync_account_crypto.dart';
import 'package:lingua_srs/services/sync_recovery_code.dart';

void main() {
  group('SyncRecoveryCode', () {
    test('makes 160-bit secrets', () {
      final secret = SyncRecoveryCode.newSecret();

      expect(secret, hasLength(20));
      expect(secret.every((byte) => byte >= 0 && byte < 256), isTrue);
      expect(SyncRecoveryCode.newSecret(), isNot(secret));
    });

    test('formats a secret as 8 groups of 4 Crockford base32 characters', () {
      final code = SyncRecoveryCode.format(List<int>.filled(20, 0));

      expect(code, '0000-0000-0000-0000-0000-0000-0000-0000');
      expect(
        SyncRecoveryCode.format(List<int>.filled(20, 255)),
        'ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ',
      );
      // 0x00 0x44 0x32 0x14 0xC7 is 00000 00001 00010 00011 00100 00101
      // 00110 00111 in 5-bit groups.
      expect(
        SyncRecoveryCode.format([
          0x00, 0x44, 0x32, 0x14, 0xC7, //
          ...List<int>.filled(15, 0),
        ]).substring(0, 9),
        '0123-4567',
      );
    });

    test('never uses I, L, O or U', () {
      final random = Random(7);
      for (var i = 0; i < 200; i++) {
        final code = SyncRecoveryCode.format(
          SyncRecoveryCode.newSecret(random),
        );
        expect(
          RegExp(r'^[0-9A-HJKMNP-TV-Z]{4}(-[0-9A-HJKMNP-TV-Z]{4}){7}$')
              .hasMatch(code),
          isTrue,
          reason: code,
        );
      }
    });

    test('reads back what it wrote, for many random secrets', () {
      final random = Random(127);
      for (var i = 0; i < 500; i++) {
        final secret = SyncRecoveryCode.newSecret(random);
        expect(SyncRecoveryCode.parse(SyncRecoveryCode.format(secret)), secret);
      }
    });

    test('reads a code typed back loosely', () {
      final secret = SyncRecoveryCode.newSecret(Random(1));
      final code = SyncRecoveryCode.format(secret);
      final typed = code
          .toLowerCase()
          .replaceAll('-', ' ')
          .replaceAll('0', 'o')
          .replaceAll('1', 'l');

      expect(SyncRecoveryCode.parse(typed), secret);
      expect(SyncRecoveryCode.parse(code.replaceAll('-', '')), secret);
      expect(SyncRecoveryCode.parse('  $code\n'), secret);
      expect(SyncRecoveryCode.parse(code.replaceAll('1', 'I')), secret);
    });

    test(
      'refuses codes that are too short, too long or have other symbols',
      () {
        final code = SyncRecoveryCode.format(SyncRecoveryCode.newSecret());
        for (final bad in [
          '',
          code.substring(0, code.length - 1),
          '${code}0',
          code.replaceRange(0, 1, 'U'),
          code.replaceRange(0, 1, '*'),
          code.replaceRange(0, 1, 'é'),
        ]) {
          expect(
            () => SyncRecoveryCode.parse(bad),
            throwsFormatException,
            reason: bad,
          );
        }
      },
    );

    test('does not repeat the code in its errors', () {
      final code = SyncRecoveryCode.format(SyncRecoveryCode.newSecret());
      try {
        SyncRecoveryCode.parse('${code}X');
        fail('should have thrown');
      } on FormatException catch (error) {
        expect(error.toString(), isNot(contains(code.substring(0, 4))));
      }
    });
  });

  group('recovery keys', () {
    test('are the same for the same code', () async {
      final secret = SyncRecoveryCode.newSecret(Random(3));
      final a = await SyncAccountCrypto.deriveRecoveryKeys(secret);
      final b = await SyncAccountCrypto.deriveRecoveryKeys(
        SyncRecoveryCode.parse(SyncRecoveryCode.format(secret)),
      );

      expect(a.authKey, b.authKey);
      expect(a.wrapKey, b.wrapKey);
      expect(a.wrapKey, hasLength(32));
      // Unpadded base64url of 32 bytes, as the Worker expects for auth keys.
      expect(RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(a.authKey), isTrue);
    });

    test('differ between codes, and between the auth and wrap keys', () async {
      final a = await SyncAccountCrypto.deriveRecoveryKeys(
        List<int>.filled(20, 1),
      );
      final b = await SyncAccountCrypto.deriveRecoveryKeys(
        List<int>.filled(20, 2),
      );

      expect(a.authKey, isNot(b.authKey));
      expect(a.wrapKey, isNot(b.wrapKey));
    });

    test('match a fixed example, so the derivation cannot change', () async {
      // A code written down years ago must still work. Computed with
      // HKDF-SHA256 (RFC 5869), a zero salt and the labels as info.
      final secret = List<int>.generate(20, (i) => i);
      expect(
        SyncRecoveryCode.format(secret),
        '000G-40R4-0M30-E209-185G-R38E-1W81-24GK',
      );

      final keys = await SyncAccountCrypto.deriveRecoveryKeys(secret);

      // Compared as bytes: the auth key is sent as unpadded base64url.
      expect(base64Url.decode(base64Url.normalize(keys.authKey)), [
        92, 189, 176, 164, 183, 59, 236, 136, 169, 226, 220, 153, 196, 213, //
        19, 239, 117, 148, 224, 94, 236, 116, 80, 91, 211, 234, 25, 183, 24, //
        70, 9, 217,
      ]);
      expect(keys.wrapKey, [
        160, 206, 21, 226, 68, 47, 127, 41, 103, 127, 194, 31, 63, 168, 96, //
        146, 229, 52, 82, 199, 192, 35, 254, 180, 197, 117, 211, 63, 206, //
        191, 206, 117,
      ]);
    });

    test('wrap and unwrap the data key', () async {
      final dataKey = List<int>.generate(32, (i) => 255 - i);
      final keys = await SyncAccountCrypto.deriveRecoveryKeys(
        SyncRecoveryCode.newSecret(),
      );
      final wrapped = await SyncAccountCrypto.wrapDataKey(
        dataKey: dataKey,
        wrapKey: keys.wrapKey,
      );

      expect(
        await SyncAccountCrypto.unwrapDataKey(
          wrappedDataKey: wrapped,
          wrapKey: keys.wrapKey,
        ),
        dataKey,
      );
      final other = await SyncAccountCrypto.deriveRecoveryKeys(
        SyncRecoveryCode.newSecret(),
      );
      expect(
        () => SyncAccountCrypto.unwrapDataKey(
          wrappedDataKey: wrapped,
          wrapKey: other.wrapKey,
        ),
        throwsFormatException,
      );
    });
  });
}
