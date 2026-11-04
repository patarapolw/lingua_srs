import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lingua_srs/services/sync_account_crypto.dart';
import 'package:lingua_srs/services/sync_account_service.dart';
import 'package:lingua_srs/services/sync_pairing.dart';

const _email = 'reader@example.com';
const _password = 'test-only-account-passphrase';
final _endpoint = Uri.parse('https://sync.example.com');

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

void main() {
  setUp(() => SyncPairing.defaultEndpoint = _endpoint);
  tearDown(() => SyncPairing.defaultEndpoint = null);

  test(
    'creates an account and confirms it before returning to sign-in',
    () async {
      final requests = <http.Request>[];
      final service = SyncAccountService(
        clientFactory: () => MockClient((request) async {
          requests.add(request);
          if (request.url.host == 'api.pwnedpasswords.com') {
            return http.Response('0000000000000000000000000000000000:0\n', 200);
          }
          return request.url.path.endsWith('/confirm')
              ? _json({'status': 'verified'})
              : _json({'status': 'confirmation_sent'}, 202);
        }),
      );
      final pairing = SyncPairing(email: _email, password: _password);

      await service.createAccount(pairing);
      await service.confirmAccount(pairing, '12345678');

      final signup = requests.firstWhere(
        (request) => request.url.path == '/v1/accounts',
      );
      final signupBody = jsonDecode(signup.body) as Map<String, dynamic>;
      expect(signup.headers['Authorization'], isNull);
      expect(signupBody['email'], _email);
      expect(signupBody['authKey'], isNot(_password));
      expect(signupBody['wrappedDataKey'], isA<String>());
      expect(signupBody['kdf'], SyncAccountCrypto.kdf);
      expect(
        requests.any(
          (request) =>
              request.url.path == '/v1/accounts/confirm' &&
              (jsonDecode(request.body) as Map)['code'] == '12345678',
        ),
        isTrue,
      );
    },
  );

  test('validates account credentials before sign-in', () async {
    final requests = <http.Request>[];
    final service = SyncAccountService(
      clientFactory: () => MockClient((request) async {
        requests.add(request);
        return _json({
          'wrappedDataKey': 'wrapped',
          'kdf': SyncAccountCrypto.kdf,
        });
      }),
    );

    await service.validateCredentials(
      SyncPairing(email: _email, password: _password),
    );

    expect(requests, hasLength(1));
    expect(requests.single.method, 'GET');
    expect(requests.single.url.path, '/v1/account');
    expect(requests.single.headers['authorization'], startsWith('Basic '));
  });

  test('changes the password by re-wrapping the existing data key', () async {
    const newPassword = 'test-only-new-password-for-account';
    const dataKey = [
      0,
      1,
      2,
      3,
      4,
      5,
      6,
      7,
      8,
      9,
      10,
      11,
      12,
      13,
      14,
      15,
      16,
      17,
      18,
      19,
      20,
      21,
      22,
      23,
      24,
      25,
      26,
      27,
      28,
      29,
      30,
      31,
    ];
    final current = SyncPairing(email: _email, password: _password);
    final currentKeys = await SyncAccountCrypto.deriveKeys(
      email: _email,
      password: _password,
    );
    final oldWrappedDataKey = await SyncAccountCrypto.wrapDataKey(
      dataKey: dataKey,
      wrapKey: currentKeys.wrapKey,
    );
    http.Request? updateRequest;
    final service = SyncAccountService(
      clientFactory: () => MockClient((request) async {
        if (request.url.host == 'api.pwnedpasswords.com') {
          return http.Response('0000000000000000000000000000000000:0\n', 200);
        }
        if (request.method == 'GET') {
          return _json({
            'wrappedDataKey': oldWrappedDataKey,
            'kdf': SyncAccountCrypto.kdf,
          });
        }
        updateRequest = request;
        return _json({'status': 'ok'});
      }),
    );

    final updated = await service.changePassword(current, newPassword);

    expect(updated.password, newPassword);
    expect(updateRequest?.method, 'PUT');
    final body = jsonDecode(updateRequest!.body) as Map<String, dynamic>;
    final newKeys = await SyncAccountCrypto.deriveKeys(
      email: _email,
      password: newPassword,
    );
    expect(body['authKey'], newKeys.authKey);
    expect(
      await SyncAccountCrypto.unwrapDataKey(
        wrappedDataKey: body['wrappedDataKey'] as String,
        wrapKey: newKeys.wrapKey,
      ),
      dataKey,
    );
  });

  test('creates an encrypted one-time pairing link and redeems it', () async {
    final pairing = SyncPairing(email: _email, password: _password);
    String? encryptedPayload;
    final service = SyncAccountService(
      clientFactory: () => MockClient((request) async {
        if (request.method == 'POST') {
          expect(request.url.path, '/v1/account/pairing');
          expect(request.headers['Authorization'], startsWith('Basic '));
          encryptedPayload =
              (jsonDecode(request.body) as Map<String, dynamic>)['payload']
                  as String;
          return _json({'token': 'a' * 64});
        }
        expect(request.url.path, '/v1/pairings/${'a' * 64}');
        expect(request.headers['Authorization'], isNull);
        return _json({'payload': encryptedPayload});
      }),
    );

    final link = await service.createPairingLink(pairing);
    final uri = Uri.parse(link);

    expect(uri.host, 'pair');
    expect(uri.queryParameters['token'], 'a' * 64);
    expect(uri.queryParameters['endpoint'], _endpoint.toString());
    expect(uri.fragment, isNotEmpty);
    expect(link, isNot(contains(_password)));
    expect(encryptedPayload, isNot(contains(_password)));
    expect(await service.redeemPairingLink(link), pairing);
  });

  test('deletes the remote account using authenticated credentials', () async {
    final pairing = SyncPairing(email: _email, password: _password);
    late http.Request request;
    final service = SyncAccountService(
      clientFactory: () => MockClient((seen) async {
        request = seen;
        return http.Response('', 204);
      }),
    );

    await service.deleteAccount(pairing);

    expect(request.method, 'DELETE');
    expect(request.url.path, '/v1/account');
    expect(request.headers['Authorization'], startsWith('Basic '));
  });
}
