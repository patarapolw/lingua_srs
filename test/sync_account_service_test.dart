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
  setUp(() {
    SyncPairing.defaultEndpoint = _endpoint;
    SyncAccountService.clearKeyCache();
  });
  tearDown(() {
    SyncPairing.defaultEndpoint = null;
    SyncAccountService.clearKeyCache();
    SyncAccountService.now = DateTime.now;
  });

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

  test('unlocks the data key and returns the account identity', () async {
    final dataKey = List<int>.generate(32, (i) => i * 3);
    final keys = await SyncAccountCrypto.deriveKeys(
      email: _email,
      password: _password,
    );
    final wrappedDataKey = await SyncAccountCrypto.wrapDataKey(
      dataKey: dataKey,
      wrapKey: keys.wrapKey,
    );
    final requests = <http.Request>[];
    final service = SyncAccountService(
      clientFactory: () => MockClient((request) async {
        requests.add(request);
        return _json({
          'wrappedDataKey': wrappedDataKey,
          'kdf': SyncAccountCrypto.kdf,
          'createdAt': 1762171200000,
        });
      }),
    );

    final unlocked = await service.unlockDataKey(
      SyncPairing(email: _email, password: _password),
    );

    expect(unlocked.key, dataKey);
    expect(unlocked.createdAt, 1762171200000);
    expect(unlocked.email, _email);
    expect(unlocked.endpoint, _endpoint);
    expect(requests.single.method, 'GET');
    expect(requests.single.url.path, '/v1/account');
  });

  test('refuses to unlock a data key with the wrong password', () async {
    final keys = await SyncAccountCrypto.deriveKeys(
      email: _email,
      password: _password,
    );
    final wrappedDataKey = await SyncAccountCrypto.wrapDataKey(
      dataKey: List<int>.filled(32, 7),
      wrapKey: keys.wrapKey,
    );
    final service = SyncAccountService(
      clientFactory: () => MockClient(
        (request) async => _json({
          'wrappedDataKey': wrappedDataKey,
          'kdf': SyncAccountCrypto.kdf,
        }),
      ),
    );

    await expectLater(
      service.unlockDataKey(
        SyncPairing(email: _email, password: 'a-different-test-password'),
      ),
      throwsFormatException,
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

  group('pairing links and servers', () {
    SyncPairing local() => SyncPairing(
      endpoint: Uri.parse('http://localhost:8787'),
      email: _email,
      password: _password,
    );

    // A fake server that keeps the one invite it is given.
    http.Client Function() fakeServer() {
      Object? payload;
      return () => MockClient((request) async {
        if (request.method == 'POST') {
          payload = (jsonDecode(request.body) as Map)['payload'];
          return _json({'token': 'a' * 64});
        }
        return _json({'payload': payload});
      });
    }

    test(
      'a link to another server is refused unless that is allowed',
      () async {
        final server = fakeServer();
        final link = await SyncAccountService(
          clientFactory: server,
          allowCustomServer: true,
        ).createPairingLink(local());

        await expectLater(
          SyncAccountService(
            clientFactory: server,
            allowCustomServer: false,
          ).redeemPairingLink(link),
          throwsFormatException,
        );
        expect(
          await SyncAccountService(
            clientFactory: server,
            allowCustomServer: true,
          ).redeemPairingLink(link),
          local(),
        );
      },
    );

    test('a link to the built-in server is always followed', () async {
      final server = fakeServer();
      final pairing = SyncPairing(email: _email, password: _password);
      final link = await SyncAccountService(
        clientFactory: server,
        allowCustomServer: false,
      ).createPairingLink(pairing);

      expect(
        await SyncAccountService(
          clientFactory: server,
          allowCustomServer: false,
        ).redeemPairingLink(link),
        pairing,
      );
    });
  });

  group('derives the password key once per sign-in', () {
    final wrapKey = List<int>.generate(32, (i) => i + 1);
    final dataKey = List<int>.generate(32, (i) => i * 5);
    final derived = <String>[];

    // A fast stand-in for Argon2id that records every derivation.
    Future<SyncAccountKeys> fakeDerive({
      required String email,
      required String password,
    }) async {
      derived.add('$email|$password');
      await Future<void>.delayed(Duration.zero);
      return SyncAccountKeys(authKey: 'auth-$password', wrapKey: wrapKey);
    }

    setUp(derived.clear);

    SyncAccountService serviceFor({
      bool failAccount = false,
      List<http.Request>? requests,
    }) => SyncAccountService(
      deriveKeys: fakeDerive,
      clientFactory: () => MockClient((request) async {
        requests?.add(request);
        if (request.url.host == 'api.pwnedpasswords.com') {
          return http.Response('0000000000000000000000000000000000:0\n', 200);
        }
        if (request.method == 'GET') {
          if (failAccount) return _json({'error': 'unauthorized'}, 401);
          return _json({
            'wrappedDataKey': await SyncAccountCrypto.wrapDataKey(
              dataKey: dataKey,
              wrapKey: wrapKey,
            ),
            'kdf': SyncAccountCrypto.kdf,
            'createdAt': 1762171200000,
          });
        }
        return _json({'status': 'ok'});
      }),
    );

    final pairing = SyncPairing(email: _email, password: _password);

    test(
      'sign-up derives once for create, confirm and the first sync',
      () async {
        final service = serviceFor();

        await service.createAccount(pairing);
        await service.confirmAccount(pairing, '12345678');
        // Each screen makes its own service; the first sync does too.
        final unlocked = await serviceFor().unlockDataKey(pairing);

        expect(unlocked.key, dataKey);
        expect(derived, ['$_email|$_password']);
      },
    );

    test('sign-in derives once for the check and the first sync', () async {
      await serviceFor().validateCredentials(pairing);
      await serviceFor().unlockDataKey(pairing);

      expect(derived, hasLength(1));
    });

    test('the first sync clears the keys, so the next one derives', () async {
      await serviceFor().unlockDataKey(pairing);
      await serviceFor().unlockDataKey(pairing);

      expect(derived, hasLength(2));
    });

    test('concurrent steps share one derivation', () async {
      final service = serviceFor();

      await Future.wait([
        service.validateCredentials(pairing),
        service.validateCredentials(pairing),
        service.confirmAccount(pairing, '12345678'),
      ]);

      expect(derived, hasLength(1));
    });

    test('a different email or password derives again', () async {
      final service = serviceFor();

      await service.confirmAccount(pairing, '12345678');
      await service.confirmAccount(
        SyncPairing(email: 'other@example.com', password: _password),
        '12345678',
      );
      await service.confirmAccount(
        SyncPairing(
          email: 'other@example.com',
          password: 'another-test-only-password',
        ),
        '12345678',
      );

      expect(derived, [
        '$_email|$_password',
        'other@example.com|$_password',
        'other@example.com|another-test-only-password',
      ]);
    });

    test('an equivalent spelling of the password reuses the keys', () async {
      final service = serviceFor();

      await service.confirmAccount(
        SyncPairing(email: _email, password: 'test-only-pass\u00e9-passphrase'),
        '12345678',
      );
      await service.confirmAccount(
        SyncPairing(
          email: _email,
          password: 'test-only-passe\u0301-passphrase',
        ),
        '12345678',
      );

      expect(derived, hasLength(1));
    });

    test('a failed sign-in clears the keys', () async {
      await expectLater(
        serviceFor(failAccount: true).validateCredentials(pairing),
        throwsA(anything),
      );
      await serviceFor().validateCredentials(pairing);

      expect(derived, hasLength(2));
    });

    test('a failed derivation is not kept', () async {
      var calls = 0;
      final service = SyncAccountService(
        deriveKeys: ({required email, required password}) async {
          calls++;
          if (calls == 1) throw StateError('derivation failed');
          return SyncAccountKeys(authKey: 'auth', wrapKey: wrapKey);
        },
        clientFactory: () => MockClient((_) async => _json({'status': 'ok'})),
      );

      await expectLater(
        service.confirmAccount(pairing, '12345678'),
        throwsStateError,
      );
      await service.confirmAccount(pairing, '12345678');

      expect(calls, 2);
    });

    test(
      'clearKeyCache, as signing out does, makes the next step derive',
      () async {
        final service = serviceFor();

        await service.confirmAccount(pairing, '12345678');
        SyncAccountService.clearKeyCache();
        await service.confirmAccount(pairing, '12345678');

        expect(derived, hasLength(2));
      },
    );

    test('deleting the account clears the keys', () async {
      final service = serviceFor();

      await service.deleteAccount(pairing);
      await service.confirmAccount(pairing, '12345678');

      expect(derived, hasLength(2));
    });

    test('the keys expire if no sync follows', () async {
      var clock = DateTime(2026, 11, 16, 9);
      SyncAccountService.now = () => clock;
      final service = serviceFor();

      await service.validateCredentials(pairing);
      clock = clock.add(const Duration(minutes: 4));
      await service.validateCredentials(pairing);
      expect(derived, hasLength(1));

      clock = clock.add(const Duration(minutes: 2));
      await service.validateCredentials(pairing);
      expect(derived, hasLength(2));
    });

    test('changing the password derives once per password, then the '
        'first sync reuses the new keys', () async {
      const newPassword = 'test-only-new-password-for-account';
      final service = serviceFor();

      final updated = await service.changePassword(pairing, newPassword);
      await serviceFor().unlockDataKey(updated);

      expect(derived, ['$_email|$_password', '$_email|$newPassword']);
    });

    test('a refused password change clears the keys', () async {
      await expectLater(
        serviceFor(failAccount: true)
            .changePassword(pairing, 'test-only-new-password-for-account'),
        throwsA(anything),
      );
      await serviceFor().validateCredentials(pairing);

      expect(derived, hasLength(2));
    });
  });
}
