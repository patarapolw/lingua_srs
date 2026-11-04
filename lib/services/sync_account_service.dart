import 'dart:convert';
import 'dart:math';

import 'package:cryptography_plus/cryptography_plus.dart';
import 'package:http/http.dart' as http;

import 'sync_account_crypto.dart';
import 'sync_client.dart';
import 'sync_pairing.dart';
import 'sync_password_policy.dart';

class SyncAccountService {
  final http.Client Function() _clientFactory;
  static final _pairingCipher = AesGcm.with256bits();

  SyncAccountService({http.Client Function()? clientFactory})
    : _clientFactory = clientFactory ?? http.Client.new;

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
    final keys = await SyncAccountCrypto.deriveKeys(
      email: pairing.email,
      password: pairing.password,
    );
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
    final keys = await SyncAccountCrypto.deriveKeys(
      email: pairing.email,
      password: pairing.password,
    );
    final client = _client(pairing, keys.authKey);
    try {
      await client.confirmAccount(authKey: keys.authKey, code: code);
    } finally {
      client.close();
    }
  }

  Future<void> validateCredentials(SyncPairing pairing) async {
    final keys = await SyncAccountCrypto.deriveKeys(
      email: pairing.email,
      password: pairing.password,
    );
    final client = _client(pairing, keys.authKey);
    try {
      await client.getAccount();
    } finally {
      client.close();
    }
  }

  Future<SyncPairing> changePassword(
    SyncPairing current,
    String newPassword,
  ) async {
    await _checkPassword(newPassword);
    final currentKeys = await SyncAccountCrypto.deriveKeys(
      email: current.email,
      password: current.password,
    );
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
      final newKeys = await SyncAccountCrypto.deriveKeys(
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
      return SyncPairing(
        endpoint: current.endpoint,
        email: current.email,
        password: newPassword,
      );
    } finally {
      client.close();
    }
  }

  Future<String> createPairingLink(SyncPairing pairing) async {
    final keys = await SyncAccountCrypto.deriveKeys(
      email: pairing.email,
      password: pairing.password,
    );
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
    final normalizedEndpoint = SyncPairing(
      endpoint: endpoint,
      email: 'pairing@example.com',
      password: 'temporary',
    ).endpoint;
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
    final keys = await SyncAccountCrypto.deriveKeys(
      email: pairing.email,
      password: pairing.password,
    );
    final client = _client(pairing, keys.authKey);
    try {
      await client.deleteAccount();
    } finally {
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
