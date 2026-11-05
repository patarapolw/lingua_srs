import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lingua_srs/services/sync_client.dart';

const _email = 'reader@example.com';
const _authKey = 'not-a-real-auth-key';

// What a server sees: the email and the derived key, never the password.
final _basic = 'Basic ${base64.encode(utf8.encode('$_email:$_authKey'))}';

SyncClient _syncClient({
  required http.Client client,
  String endpoint = 'https://sync.example.com',
}) => SyncClient(
  endpoint: Uri.parse(endpoint),
  email: _email,
  authKey: _authKey,
  client: client,
);

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

Map<String, dynamic> _record(String id, {bool deleted = false}) => {
  'kind': 'lesson',
  'id': id,
  'updatedAt': 1000,
  'deleted': deleted,
  'data': deleted ? <String, dynamic>{} : {'title': id},
};

void main() {
  group('SyncClient account lifecycle', () {
    test(
      'creates an account without Basic auth and confirms with the code',
      () async {
        final requests = <http.Request>[];
        final client = _syncClient(
          client: MockClient((request) async {
            requests.add(request);
            return request.url.path.endsWith('/confirm')
                ? _json({'status': 'verified'})
                : _json({'status': 'confirmation_sent'}, 202);
          }),
        );

        await client.createAccount(
          authKey: 'derived-key',
          wrappedDataKey: 'wrapped-key',
          kdf: const {'alg': 'argon2id'},
        );
        await client.confirmAccount(authKey: 'derived-key', code: '12345678');

        expect(requests.map((request) => request.url.path), [
          '/v1/accounts',
          '/v1/accounts/confirm',
        ]);
        expect(requests.every((request) => request.method == 'POST'), isTrue);
        expect(
          requests.every((request) => request.headers['Authorization'] == null),
          isTrue,
        );
        expect(jsonDecode(requests.first.body), {
          'email': _email,
          'authKey': 'derived-key',
          'wrappedDataKey': 'wrapped-key',
          'kdf': {'alg': 'argon2id'},
        });
        expect(jsonDecode(requests.last.body), {
          'email': _email,
          'authKey': 'derived-key',
          'code': '12345678',
        });
      },
    );

    test(
      'gets and updates account key material using the signed-in key',
      () async {
        final requests = <http.Request>[];
        final client = _syncClient(
          client: MockClient((request) async {
            requests.add(request);
            return request.method == 'GET'
                ? _json({
                    'wrappedDataKey': 'old-wrapped-key',
                    'kdf': {'alg': 'argon2id'},
                    'createdAt': 1762171200000,
                  })
                : _json({'status': 'ok'});
          }),
        );

        final account = await client.getAccount();
        await client.changePassword(
          authKey: 'new-derived-key',
          wrappedDataKey: 'new-wrapped-key',
          kdf: const {'alg': 'argon2id'},
        );

        expect(account.wrappedDataKey, 'old-wrapped-key');
        expect(account.kdf['alg'], 'argon2id');
        expect(account.createdAt, 1762171200000);
        expect(requests.map((request) => request.method), ['GET', 'PUT']);
        expect(
          requests.every(
            (request) => request.headers['Authorization'] == _basic,
          ),
          isTrue,
        );
        expect(jsonDecode(requests.last.body), {
          'authKey': 'new-derived-key',
          'wrappedDataKey': 'new-wrapped-key',
          'kdf': {'alg': 'argon2id'},
        });
      },
    );
  });

  group('SyncClient.getAccount createdAt', () {
    test('is null from a Worker that does not send it', () async {
      final client = _syncClient(
        client: MockClient(
          (request) async => _json({
            'wrappedDataKey': 'wrapped-key',
            'kdf': {'alg': 'argon2id'},
          }),
        ),
      );

      final account = await client.getAccount();

      expect(account.wrappedDataKey, 'wrapped-key');
      expect(account.createdAt, isNull);
    });

    test('rejects a createdAt that is not a whole number', () async {
      final client = _syncClient(
        client: MockClient(
          (request) async => _json({
            'wrappedDataKey': 'wrapped-key',
            'kdf': {'alg': 'argon2id'},
            'createdAt': '2026-11-03',
          }),
        ),
      );

      await expectLater(client.getAccount(), throwsA(isA<SyncException>()));
    });
  });

  group('SyncClient.pull', () {
    test('asks for changes since the cursor with the bearer key', () async {
      late http.Request seen;
      final client = _syncClient(
        client: MockClient((request) async {
          seen = request;
          return _json({
            'records': [_record('a'), _record('b', deleted: true)],
            'cursor': 12,
            'hasMore': false,
          });
        }),
      );

      final result = await client.pull(since: 7, limit: 50);

      expect(seen.method, 'GET');
      expect(
        seen.url.toString(),
        'https://sync.example.com/v1/changes'
        '?since=7&limit=50',
      );
      expect(seen.headers['Authorization'], _basic);
      expect(result.cursor, 12);
      expect(result.hasMore, isFalse);
      expect(result.records.map((r) => r.id), ['a', 'b']);
      expect(result.records[0].data['title'], 'a');
      expect(result.records[1].deleted, isTrue);
    });

    test('keeps the path prefix of the endpoint', () async {
      late Uri seen;
      final client = _syncClient(
        endpoint: 'https://example.com/lingua',
        client: MockClient((request) async {
          seen = request.url;
          return _json({'records': [], 'cursor': 0, 'hasMore': false});
        }),
      );

      await client.pull();

      expect(seen.path, '/lingua/v1/changes');
    });

    test('pullAll follows pages until there are no more', () async {
      final sinceValues = <String?>[];
      final client = _syncClient(
        client: MockClient((request) async {
          final since = request.url.queryParameters['since'];
          sinceValues.add(since);
          return since == '0'
              ? _json({
                  'records': [_record('a')],
                  'cursor': 5,
                  'hasMore': true,
                })
              : _json({
                  'records': [_record('b')],
                  'cursor': 9,
                  'hasMore': false,
                });
        }),
      );

      final result = await client.pullAll();

      expect(sinceValues, ['0', '5']);
      expect(result.records.map((r) => r.id), ['a', 'b']);
      expect(result.cursor, 9);
      expect(result.hasMore, isFalse);
    });

    test('pullAll stops if the cursor does not advance', () async {
      final client = _syncClient(
        client: MockClient(
          (_) async => _json({'records': [], 'cursor': 0, 'hasMore': true}),
        ),
      );

      expect(client.pullAll(), throwsA(isA<SyncException>()));
    });

    test('rejects malformed responses', () async {
      for (final response in [
        http.Response('not json', 200),
        _json({'records': 'nope', 'cursor': 0, 'hasMore': false}),
        _json({
          'records': [
            {'kind': 'lesson'},
          ],
          'cursor': 0,
          'hasMore': false,
        }),
        _json([]),
      ]) {
        final client = _syncClient(client: MockClient((_) async => response));

        await expectLater(client.pull(), throwsA(isA<SyncException>()));
      }
    });

    test('reports a rejected key as unauthorized', () async {
      final client = _syncClient(
        client: MockClient((_) async => http.Response('bad key', 401)),
      );

      await expectLater(
        client.pull(),
        throwsA(
          isA<SyncException>()
              .having((e) => e.statusCode, 'statusCode', 401)
              .having((e) => e.isUnauthorized, 'isUnauthorized', isTrue),
        ),
      );
    });
  });

  group('SyncClient.push', () {
    test('posts records as JSON and returns how many were kept', () async {
      late http.Request seen;
      final client = _syncClient(
        client: MockClient((request) async {
          seen = request;
          return _json({'accepted': 1});
        }),
      );

      final accepted = await client.push([
        const SyncRecord(
          kind: 'lesson',
          id: 'a',
          updatedAt: 1000,
          data: {'title': 'a'},
        ),
        const SyncRecord.tombstone(kind: 'lesson', id: 'b', updatedAt: 2000),
      ]);

      expect(accepted, 1);
      expect(seen.method, 'POST');
      expect(seen.url.path, '/v1/changes');
      expect(seen.headers['Authorization'], _basic);
      expect(seen.headers['Content-Type'], startsWith('application/json'));
      final body = jsonDecode(seen.body) as Map<String, dynamic>;
      expect(body['records'], [
        {
          'kind': 'lesson',
          'id': 'a',
          'updatedAt': 1000,
          'deleted': false,
          'data': {'title': 'a'},
        },
        {
          'kind': 'lesson',
          'id': 'b',
          'updatedAt': 2000,
          'deleted': true,
          'data': <String, dynamic>{},
        },
      ]);
    });

    test('splits large pushes into batches', () async {
      final batchSizes = <int>[];
      final client = _syncClient(
        client: MockClient((request) async {
          final records =
              (jsonDecode(request.body) as Map<String, dynamic>)['records']
                  as List;
          batchSizes.add(records.length);
          return _json({'accepted': records.length});
        }),
      );

      final accepted = await client.push([
        for (var i = 0; i < 250; i++)
          SyncRecord(kind: 'sentence', id: '$i', updatedAt: i),
      ]);

      expect(batchSizes, [100, 100, 50]);
      expect(accepted, 250);
    });

    test('sends nothing when there is nothing to push', () async {
      var requests = 0;
      final client = _syncClient(
        client: MockClient((_) async {
          requests++;
          return _json({'accepted': 0});
        }),
      );

      expect(await client.push(const []), 0);
      expect(requests, 0);
    });

    test('rejects a response without an accepted count', () async {
      final client = _syncClient(
        client: MockClient((_) async => _json({'ok': true})),
      );

      await expectLater(
        client.push([const SyncRecord(kind: 'lesson', id: 'a', updatedAt: 1)]),
        throwsA(isA<SyncException>()),
      );
    });
  });

  group('SyncClient inbox', () {
    test('fetchInbox lists items sent by another app', () async {
      late http.Request seen;
      final client = _syncClient(
        client: MockClient((request) async {
          seen = request;
          return _json({
            'items': [
              {'id': 'i1', 'text': 'vocabulary: []', 'createdAt': 3000},
            ],
          });
        }),
      );

      final items = await client.fetchInbox();

      expect(seen.method, 'GET');
      expect(seen.url.path, '/v1/inbox');
      expect(items.single.id, 'i1');
      expect(items.single.text, 'vocabulary: []');
      expect(items.single.createdAt, 3000);
    });

    test('fetchInbox rejects malformed items', () async {
      final client = _syncClient(
        client: MockClient(
          (_) async => _json({
            'items': [
              {'id': 'i1'},
            ],
          }),
        ),
      );

      await expectLater(client.fetchInbox(), throwsA(isA<SyncException>()));
    });

    test('ackInbox deletes the item', () async {
      late http.Request seen;
      final client = _syncClient(
        client: MockClient((request) async {
          seen = request;
          return http.Response('', 204);
        }),
      );

      await client.ackInbox('i1');

      expect(seen.method, 'DELETE');
      expect(seen.url.path, '/v1/inbox/i1');
    });
  });
}
