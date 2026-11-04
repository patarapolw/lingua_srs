import 'dart:convert';
import 'dart:isolate';

import 'package:cryptography_plus/cryptography_plus.dart';
import 'package:cryptography_plus/dart.dart';

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
  static const _argon2 = DartArgon2id(
    memory: 65536,
    iterations: 3,
    parallelism: 1,
    hashLength: 32,
  );
  static final _cipher = AesGcm.with256bits();

  static Future<SyncAccountKeys> deriveKeys({
    required String email,
    required String password,
  }) async {
    final master = await Isolate.run(() async {
      final key = await _argon2.deriveKey(
        secretKey: SecretKey(utf8.encode(password)),
        nonce: utf8.encode('linguasrs:$email'),
      );
      return (await key.extractBytes()).toList();
    });
    final authKey = await _deriveKey(master, 'auth');
    final wrapKey = await _deriveKey(master, 'wrap');
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
