import 'dart:convert';
import 'dart:isolate';

import 'package:cryptography_plus/cryptography_plus.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:hashlib/hashlib.dart' show Argon2, Argon2Type;
import 'package:unorm_dart/unorm_dart.dart' as unorm;

class SyncAccountKeys {
  final String authKey;
  final List<int> wrapKey;

  const SyncAccountKeys({required this.authKey, required this.wrapKey});
}

class SyncAccountCrypto {
  static const kdf = {
    'alg': 'argon2id',
    'memoryKiB': 65536,
    'passes': 3,
    'lanes': 1,
  };
  static final _cipher = AesGcm.with256bits();

  /// The password as key derivation sees it, in Unicode form NFKC.
  ///
  /// The same text typed on different devices can be different but equivalent
  /// characters: an accented letter can be one character or a letter followed
  /// by a combining mark (macOS and Windows keyboards differ), and full-width
  /// digits are the same digits. Without this they would give different keys.
  /// Plain ASCII, which most passwords are, is unchanged, and the saved
  /// password stays exactly as typed.
  static String normalizePassword(String password) => unorm.nfkc(password);

  static Future<SyncAccountKeys> deriveKeys({
    required String email,
    required String password,
  }) async {
    final normalizedPassword = normalizePassword(password);
    final master = await Isolate.run(
      () => argon2id(utf8.encode(normalizedPassword), email),
    );
    final authKey = await _deriveKey(master, 'auth');
    final wrapKey = await _deriveKey(master, 'wrap');
    return SyncAccountKeys(
      authKey: base64Url.encode(authKey).replaceAll('=', ''),
      wrapKey: wrapKey,
    );
  }

  /// The Argon2id master key for [password] (UTF-8, already normalized) and
  /// [email], with the parameters in [kdf]. It runs on the calling isolate:
  /// [deriveKeys] calls it off the UI isolate.
  ///
  /// It uses hashlib's pure Dart Argon2id, about twice as fast as
  /// cryptography_plus's `DartArgon2id` and giving the same bytes, so
  /// existing accounts keep their keys (#167). The known-answer test in
  /// `test/sync_account_crypto_test.dart` guards that. A native Argon2 is not
  /// used: `serverpod_argon2` failed to load on Android.
  @visibleForTesting
  static List<int> argon2id(List<int> password, String email) => Argon2(
    type: Argon2Type.argon2id,
    memorySizeKB: kdf['memoryKiB'] as int,
    iterations: kdf['passes'] as int,
    parallelism: kdf['lanes'] as int,
    hashLength: 32,
    salt: utf8.encode('linguasrs:$email'),
  ).convert(password).bytes;

  /// The keys derived from a recovery code's secret (see
  /// `SyncRecoveryCode`): an auth key, of which the server keeps only a hash,
  /// and a key that wraps the data key. The secret is 160 random bits, so it
  /// needs no slow key derivation; HKDF with labels of their own keeps these
  /// keys apart from the password's.
  static Future<SyncAccountKeys> deriveRecoveryKeys(List<int> secret) async {
    final authKey = await _deriveKey(secret, 'recovery-auth');
    final wrapKey = await _deriveKey(secret, 'recovery-wrap');
    return SyncAccountKeys(
      authKey: base64Url.encode(authKey).replaceAll('=', ''),
      wrapKey: wrapKey,
    );
  }

  static Future<String> createWrappedDataKey(List<int> wrapKey) async {
    final dataKey = await _cipher.newSecretKey();
    final wrapped = await _cipher.encrypt(
      await dataKey.extractBytes(),
      secretKey: SecretKey(wrapKey),
    );
    return base64Url.encode(wrapped.concatenation()).replaceAll('=', '');
  }

  static Future<List<int>> unwrapDataKey({
    required String wrappedDataKey,
    required List<int> wrapKey,
  }) async {
    final bytes = base64Url.decode(base64Url.normalize(wrappedDataKey));
    if (bytes.length <= _cipher.nonceLength + _cipher.macAlgorithm.macLength) {
      throw const FormatException('Sync account has an invalid wrapped key.');
    }
    final secretBox = SecretBox.fromConcatenation(
      bytes,
      nonceLength: _cipher.nonceLength,
      macLength: _cipher.macAlgorithm.macLength,
    );
    try {
      return await _cipher.decrypt(secretBox, secretKey: SecretKey(wrapKey));
    } on SecretBoxAuthenticationError {
      throw const FormatException(
        'The sync password does not unlock this account.',
      );
    }
  }

  static Future<String> wrapDataKey({
    required List<int> dataKey,
    required List<int> wrapKey,
  }) async {
    final wrapped = await _cipher.encrypt(
      dataKey,
      secretKey: SecretKey(wrapKey),
    );
    return base64Url.encode(wrapped.concatenation()).replaceAll('=', '');
  }

  static Future<List<int>> _deriveKey(List<int> master, String purpose) async {
    final key = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
      secretKey: SecretKey(master),
      nonce: List.filled(32, 0),
      info: utf8.encode(purpose),
    );
    return key.extractBytes();
  }
}
