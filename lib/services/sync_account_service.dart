import 'dart:convert';
import 'dart:math';

import 'package:cryptography_plus/cryptography_plus.dart';
import 'package:flutter/foundation.dart' show kReleaseMode, visibleForTesting;
import 'package:http/http.dart' as http;

import 'sync_account_crypto.dart';
import 'sync_client.dart';
import 'sync_pairing.dart';
import 'sync_recovery_code.dart';
import 'sync_password_policy.dart';
import 'sync_record_cipher.dart';

typedef SyncKeyDeriver = Future<SyncAccountKeys> Function({
  required String email,
  required String password,
});

class SyncAccountService {
  final http.Client Function() _clientFactory;
  final bool _allowCustomServer;
  final SyncKeyDeriver _deriveKeys;
  static final _pairingCipher = AesGcm.with256bits();

  /// The keys derived for the last email and password, so that the steps of one
  /// sign-up, sign-in or password change derive them once, not once per step.
  ///
  /// Argon2id is slow on purpose (64 MiB, 3 passes). Every screen makes its own
  /// [SyncAccountService], so the cache is static. It is in memory only: it is
  /// never written to disk, preferences, logs or error messages. It holds the
  /// derived keys, which the app also keeps for the session, and the
  /// normalized password for matching, which [SyncPairing] already holds.
  ///
  /// Lifetime: it is dropped as soon as it has done its job (the first sync
  /// unlocking the data key), after a failed sign-in, on sign-out and account
  /// deletion ([clearKeyCache]), and after [_keyCacheLifetime] at the latest,
  /// so a sign-in check that no sync follows does not leave keys behind. A
  /// password change replaces it with the keys of the new password.
  static _CachedKeys? _cache;
  static const _keyCacheLifetime = Duration(minutes: 5);

  @visibleForTesting
  static DateTime Function() now = DateTime.now;

  /// Forgets the cached keys. Call it when signing out.
  static void clearKeyCache() => _cache = null;

  /// A pairing link names the server it belongs to. Release builds only follow
  /// links to the built-in server, because a link from anywhere could
  /// otherwise move this device onto someone else's. [allowCustomServer]
  /// defaults to true in debug and profile builds, for a local Worker.
  SyncAccountService({
    http.Client Function()? clientFactory,
    bool? allowCustomServer,
    @visibleForTesting SyncKeyDeriver? deriveKeys,
  }) : _clientFactory = clientFactory ?? http.Client.new,
       _allowCustomServer = allowCustomServer ?? !kReleaseMode,
       _deriveKeys = deriveKeys ?? SyncAccountCrypto.deriveKeys;

  /// The keys for [email] and [password]: the cached ones when they were
  /// derived for the same email and password, otherwise derived now. Calls made
  /// while a derivation is running share it instead of starting another.
  Future<SyncAccountKeys> _keys(String email, String password) {
    final normalized = SyncAccountCrypto.normalizePassword(password);
    final cached = _cache;
    if (cached != null &&
        cached.email == email &&
        cached.password == normalized &&
        now().isBefore(cached.expires)) {
      return cached.keys;
    }
    final entry = _CachedKeys(
      email,
      normalized,
      _deriveKeys(email: email, password: password),
      now().add(_keyCacheLifetime),
    );
    _cache = entry;
    // A failed derivation must not be kept. Only remove this entry: a clear or
    // a newer sign-in may have replaced it.
    entry.keys.then<void>(
      (_) {},
      onError: (_) {
        if (identical(_cache, entry)) _cache = null;
      },
    );
    return entry.keys;
  }

  Future<String> generatePassphrase() async {
    final client = _clientFactory();
    try {
      return await SyncPasswordPolicy.generatePassphrase(client: client);
    } finally {
      client.close();
    }
  }

  Future<void> createAccount(SyncPairing pairing) async {
    await _checkPassword(pairing.password);
    final keys = await _keys(pairing.email, pairing.password);
    final wrappedDataKey = await SyncAccountCrypto.createWrappedDataKey(
      keys.wrapKey,
    );
    final client = _client(pairing, keys.authKey);
    try {
      await client.createAccount(
        authKey: keys.authKey,
        wrappedDataKey: wrappedDataKey,
        kdf: SyncAccountCrypto.kdf,
      );
    } finally {
      client.close();
    }
  }

  Future<void> confirmAccount(SyncPairing pairing, String code) async {
    final keys = await _keys(pairing.email, pairing.password);
    final client = _client(pairing, keys.authKey);
    try {
      await client.confirmAccount(authKey: keys.authKey, code: code);
    } finally {
      client.close();
    }
  }

  Future<void> validateCredentials(SyncPairing pairing) async {
    final keys = await _keys(pairing.email, pairing.password);
    final client = _client(pairing, keys.authKey);
    try {
      await client.getAccount();
    } catch (_) {
      // A failed sign-in must not leave its keys behind.
      clearKeyCache();
      rethrow;
    } finally {
      client.close();
    }
  }

  /// Downloads the account's wrapped data key and unlocks it with the
  /// password, for encrypting records. Also returns the account's `createdAt`,
  /// which identifies it.
  Future<SyncDataKey> unlockDataKey(SyncPairing pairing) async {
    final keys = await _keys(pairing.email, pairing.password);
    final client = _client(pairing, keys.authKey);
    try {
      final account = await client.getAccount();
      if (!_supportsKdf(account.kdf)) {
        throw const FormatException(
          'This account uses an unsupported key derivation format.',
        );
      }
      return SyncDataKey(
        endpoint: pairing.endpoint,
        email: pairing.email,
        createdAt: account.createdAt,
        key: await SyncAccountCrypto.unwrapDataKey(
          wrappedDataKey: account.wrappedDataKey,
          wrapKey: keys.wrapKey,
        ),
        authKey: keys.authKey,
      );
    } finally {
      // The sign-in is complete (the key is stored, or it failed): the keys
      // have done their job.
      clearKeyCache();
      client.close();
    }
  }

  Future<SyncPairing> changePassword(
    SyncPairing current,
    String newPassword,
  ) async {
    await _checkPassword(newPassword);
    final currentKeys = await _keys(current.email, current.password);
    final client = _client(current, currentKeys.authKey);
    try {
      final account = await client.getAccount();
      if (!_supportsKdf(account.kdf)) {
        throw const FormatException(
          'This account uses an unsupported key derivation format.',
        );
      }
      final dataKey = await SyncAccountCrypto.unwrapDataKey(
        wrappedDataKey: account.wrappedDataKey,
        wrapKey: currentKeys.wrapKey,
      );
      // Not cached yet: the server may still refuse the change.
      final newKeys = await _deriveKeys(
        email: current.email,
        password: newPassword,
      );
      final wrappedDataKey = await SyncAccountCrypto.wrapDataKey(
        dataKey: dataKey,
        wrapKey: newKeys.wrapKey,
      );
      await client.changePassword(
        authKey: newKeys.authKey,
        wrappedDataKey: wrappedDataKey,
        kdf: SyncAccountCrypto.kdf,
      );
      // The next sync unlocks the data key with the new password; it reuses
      // these keys instead of deriving them again.
      _cache = _CachedKeys(
        current.email,
        SyncAccountCrypto.normalizePassword(newPassword),
        Future.value(newKeys),
        now().add(_keyCacheLifetime),
      );
      return SyncPairing(
        endpoint: current.endpoint,
        email: current.email,
        password: newPassword,
      );
    } catch (_) {
      clearKeyCache();
      rethrow;
    } finally {
      client.close();
    }
  }

  /// Creates a recovery code for the account and uploads what the server
  /// needs to check it later: a hash of the auth key derived from it, and the
  /// data key wrapped by the key derived from it. Replaces any earlier code.
  /// Returns the code, formatted for writing down.
  ///
  /// The code and its keys stay in memory: the caller shows the code once and
  /// lets it go. Nothing here logs it or puts it in an error message.
  Future<String> createRecoveryCode(SyncPairing pairing) async {
    final keys = await _keys(pairing.email, pairing.password);
    final client = _client(pairing, keys.authKey);
    try {
      final account = await client.getAccount();
      if (!_supportsKdf(account.kdf)) {
        throw const FormatException(
          'This account uses an unsupported key derivation format.',
        );
      }
      final dataKey = await SyncAccountCrypto.unwrapDataKey(
        wrappedDataKey: account.wrappedDataKey,
        wrapKey: keys.wrapKey,
      );
      final secret = SyncRecoveryCode.newSecret();
      final recoveryKeys = await SyncAccountCrypto.deriveRecoveryKeys(secret);
      await client.setRecovery(
        recoveryKey: recoveryKeys.authKey,
        wrappedDataKey: await SyncAccountCrypto.wrapDataKey(
          dataKey: dataKey,
          wrapKey: recoveryKeys.wrapKey,
        ),
      );
      return SyncRecoveryCode.format(secret);
    } finally {
      client.close();
    }
  }

  /// Recovers the account of [pairing] with its recovery [code], giving it
  /// the new password in [pairing]. Returns the sign-in to save.
  ///
  /// The device proves the code to the server with the key derived from it,
  /// gets the data key wrapped by the code, unwraps it, wraps it with the new
  /// password and replaces the account's auth key and wrapped key. Nothing is
  /// re-encrypted. The code is used up: the account has no recovery code
  /// afterwards, so the caller makes a new one. Other devices are refused at
  /// their next sync, as after a password change.
  ///
  /// The code and the keys derived from it stay in memory, and no error
  /// message repeats them. A code that cannot be read throws
  /// [FormatException] before anything is sent; one the server refuses
  /// throws [SyncException] with status 400.
  Future<SyncPairing> recoverAccount(SyncPairing pairing, String code) async {
    final secret = SyncRecoveryCode.parse(code);
    await _checkPassword(pairing.password);
    final recoveryKeys = await SyncAccountCrypto.deriveRecoveryKeys(secret);
    final client = SyncClient(
      endpoint: pairing.endpoint,
      email: pairing.email,
      authKey: '',
      client: _clientFactory(),
    );
    try {
      final recoveryWrapped = await client.startRecovery(
        recoveryKey: recoveryKeys.authKey,
      );
      final List<int> dataKey;
      try {
        dataKey = await SyncAccountCrypto.unwrapDataKey(
          wrappedDataKey: recoveryWrapped,
          wrapKey: recoveryKeys.wrapKey,
        );
      } on FormatException {
        throw const FormatException(
          'The recovery code does not unlock this account.',
        );
      }
      // Not cached yet: the server may still refuse the change.
      final newKeys = await _deriveKeys(
        email: pairing.email,
        password: pairing.password,
      );
      await client.completeRecovery(
        recoveryKey: recoveryKeys.authKey,
        authKey: newKeys.authKey,
        wrappedDataKey: await SyncAccountCrypto.wrapDataKey(
          dataKey: dataKey,
          wrapKey: newKeys.wrapKey,
        ),
        kdf: SyncAccountCrypto.kdf,
      );
      // The first sync and the new recovery code reuse these keys.
      _cache = _CachedKeys(
        pairing.email,
        SyncAccountCrypto.normalizePassword(pairing.password),
        Future.value(newKeys),
        now().add(_keyCacheLifetime),
      );
      return pairing;
    } finally {
      client.close();
    }
  }

  Future<String> createPairingLink(SyncPairing pairing) async {
    final keys = await _keys(pairing.email, pairing.password);
    final random = Random.secure();
    final key = List<int>.generate(32, (_) => random.nextInt(256));
    final encrypted = await _pairingCipher.encrypt(
      utf8.encode(
        jsonEncode({'email': pairing.email, 'password': pairing.password}),
      ),
      secretKey: SecretKey(key),
    );
    final payload = base64Url
        .encode(encrypted.concatenation())
        .replaceAll('=', '');
    final client = _client(pairing, keys.authKey);
    try {
      final token = await client.createPairingInvite(payload);
      return Uri(
        scheme: SyncPairing.scheme,
        host: 'pair',
        queryParameters: {
          'endpoint': pairing.endpoint.toString(),
          'token': token,
        },
        fragment: base64Url.encode(key).replaceAll('=', ''),
      ).toString();
    } finally {
      client.close();
    }
  }

  Future<SyncPairing> redeemPairingLink(String text) async {
    final Uri uri;
    try {
      uri = Uri.parse(text.trim());
    } on FormatException {
      throw const FormatException('Not a LinguaSRS pairing link.');
    }
    final token = uri.queryParameters['token'];
    final endpointText = uri.queryParameters['endpoint'];
    final keyText = uri.fragment;
    if (uri.scheme != SyncPairing.scheme ||
        uri.host != 'pair' ||
        token == null ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(token) ||
        endpointText == null ||
        keyText.isEmpty) {
      throw const FormatException('Not a LinguaSRS pairing link.');
    }
    final endpoint = Uri.tryParse(endpointText);
    if (endpoint == null) {
      throw const FormatException('Pairing link has an invalid server.');
    }
    final normalizedEndpoint = SyncPairing.normalizeServer(endpoint);
    if (!_allowCustomServer &&
        normalizedEndpoint != SyncPairing.defaultEndpoint) {
      throw const FormatException(
        'This pairing link is for a different sync server.',
      );
    }
    final key = _decodeBase64Url(keyText);
    if (key.length != 32) {
      throw const FormatException('Pairing link has an invalid key.');
    }
    final client = SyncClient(
      endpoint: normalizedEndpoint,
      email: '',
      authKey: '',
      client: _clientFactory(),
    );
    try {
      final payload = await client.redeemPairingInvite(token);
      final encrypted = _decodeBase64Url(payload);
      if (encrypted.length <=
          _pairingCipher.nonceLength + _pairingCipher.macAlgorithm.macLength) {
        throw const FormatException('Pairing invite is invalid or expired.');
      }
      final box = SecretBox.fromConcatenation(
        encrypted,
        nonceLength: _pairingCipher.nonceLength,
        macLength: _pairingCipher.macAlgorithm.macLength,
      );
      final decoded = jsonDecode(
        utf8.decode(
          await _pairingCipher.decrypt(box, secretKey: SecretKey(key)),
        ),
      );
      if (decoded is! Map ||
          decoded['email'] is! String ||
          decoded['password'] is! String) {
        throw const FormatException('Pairing invite is invalid.');
      }
      return SyncPairing(
        endpoint: normalizedEndpoint,
        email: decoded['email'] as String,
        password: decoded['password'] as String,
      );
    } on SecretBoxAuthenticationError {
      throw const FormatException('Pairing link has an invalid key.');
    } finally {
      client.close();
    }
  }

  Future<void> deleteAccount(SyncPairing pairing) async {
    final keys = await _keys(pairing.email, pairing.password);
    final client = _client(pairing, keys.authKey);
    try {
      await client.deleteAccount();
    } finally {
      clearKeyCache();
      client.close();
    }
  }

  List<int> _decodeBase64Url(String text) {
    try {
      return base64Url.decode(base64Url.normalize(text));
    } on FormatException {
      throw const FormatException('Pairing link is invalid.');
    }
  }

  Future<void> _checkPassword(String password) async {
    final client = _clientFactory();
    try {
      await SyncPasswordPolicy.check(password: password, client: client);
    } finally {
      client.close();
    }
  }

  SyncClient _client(SyncPairing pairing, String authKey) => SyncClient(
    endpoint: pairing.endpoint,
    email: pairing.email,
    authKey: authKey,
    client: _clientFactory(),
  );

  bool _supportsKdf(Map<String, dynamic> kdf) =>
      kdf['alg'] == SyncAccountCrypto.kdf['alg'] &&
      kdf['memoryKiB'] == SyncAccountCrypto.kdf['memoryKiB'] &&
      kdf['passes'] == SyncAccountCrypto.kdf['passes'] &&
      kdf['lanes'] == SyncAccountCrypto.kdf['lanes'];
}

class _CachedKeys {
  final String email;

  /// The password in the form key derivation sees it (NFKC), so equivalent
  /// spellings of one password share keys, as they do when derived.
  final String password;
  final Future<SyncAccountKeys> keys;
  final DateTime expires;

  const _CachedKeys(this.email, this.password, this.keys, this.expires);
}
