import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lingua_srs/services/sync_change_tracker.dart';
import 'package:lingua_srs/services/sync_client.dart';
import 'package:lingua_srs/services/sync_engine.dart';
import 'package:lingua_srs/services/sync_record_cipher.dart';
import 'package:lingua_srs/services/sync_records.dart';

/// The Worker's `/v1/account` and `/v1/changes`, in memory: the newest
/// `updatedAt` wins, and every stored change gets the next change number.
class FakeWorker {
  int createdAt = 1000;
  bool rejectSignIn = false;
  final rows = <String, Map<String, dynamic>>{};
  int seq = 0;
  int pushRequests = 0;

  http.Client client() => MockClient(_handle);

  Future<http.Response> _handle(http.Request request) async {
    http.Response json(Object body, [int status = 200]) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );
    if (rejectSignIn) return json({'error': 'invalid_credentials'}, 401);

    switch ((request.method, request.url.path)) {
      case ('GET', '/v1/account'):
        return json({
          'wrappedDataKey': 'unused',
          'kdf': {'alg': 'argon2id'},
          'createdAt': createdAt,
        });
      case ('GET', '/v1/changes'):
        final since = int.parse(request.url.queryParameters['since'] ?? '0');
        final limit = int.parse(request.url.queryParameters['limit'] ?? '500');
        final changed =
            rows.values.where((row) => (row['seq'] as int) > since).toList()
              ..sort((a, b) => (a['seq'] as int).compareTo(b['seq'] as int));
        final page = changed.take(limit).toList();
        return json({
          'records': [
            for (final row in page) Map.of(row)..remove('seq'),
          ],
          'cursor': page.isEmpty ? since : page.last['seq'],
          'hasMore': changed.length > limit,
        });
      case ('POST', '/v1/changes'):
        pushRequests++;
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        var accepted = 0;
        for (final record in body['records'] as List) {
          final row = Map<String, dynamic>.from(record as Map);
          final key = '${row['kind']}/${row['id']}';
          final existing = rows[key];
          if (existing != null &&
              (existing['updatedAt'] as int) >= (row['updatedAt'] as int)) {
            continue;
          }
          if (row['deleted'] == true) row['data'] = <String, dynamic>{};
          rows[key] = {...row, 'seq': ++seq};
          accepted++;
        }
        return json({'accepted': accepted});
    }
    return json({'error': 'not_found'}, 404);
  }

  bool isDeleted(String kind, String id) =>
      rows['$kind/$id']?['deleted'] == true;
}

class MemoryStore implements SyncRecordStore {
  final records = <SyncRecordKey, Map<String, dynamic>>{};
  int applyCalls = 0;

  @override
  Map<SyncRecordKey, Map<String, dynamic>> snapshot(String deviceId) => {
    for (final entry in records.entries)
      entry.key: Map<String, dynamic>.from(
        jsonDecode(jsonEncode(entry.value)) as Map,
      ),
  };

  @override
  Future<void> apply(Map<SyncRecordKey, Map<String, dynamic>?> changes) async {
    applyCalls++;
    for (final entry in changes.entries) {
      if (entry.value == null) {
        records.remove(entry.key);
      } else {
        records[entry.key] = entry.value!;
      }
    }
  }
}

class Clock {
  int now = 1000000;
}

class Device {
  Device(this.worker, this.cipher, this.clock, {this.createdAt = 1000});

  final FakeWorker worker;
  final SyncRecordCipher cipher;
  final Clock clock;
  final int? createdAt;
  final store = MemoryStore();
  final tracker = SyncChangeTracker();

  Future<SyncResult> sync() => SyncEngine(
    client: SyncClient(
      endpoint: Uri.parse('https://sync.example.com'),
      email: 'reader@example.com',
      authKey: 'test-auth-key',
      client: worker.client(),
    ),
    cipher: cipher,
    store: store,
    tracker: tracker,
    accountCreatedAt: createdAt,
    save: () async {},
    clock: () => clock.now,
  ).sync();
}

const _lesson = SyncRecordKey('lesson', 'l1');
const _sentence = SyncRecordKey('sentence', 's1');
const _chat = SyncRecordKey('discussion', 'word:none');

void main() {
  late FakeWorker worker;
  late SyncRecordCipher cipher;
  late Clock clock;
  late Device a;
  late Device b;

  setUp(() async {
    worker = FakeWorker();
    cipher = await SyncRecordCipher.create(List<int>.generate(32, (i) => i));
    clock = Clock();
    a = Device(worker, cipher, clock);
    b = Device(worker, cipher, clock);
  });

  test('a record made on one device reaches the other', () async {
    a.store.records[_lesson] = {'title': 'Food'};

    final pushed = await a.sync();
    clock.now += 1000;
    final pulled = await b.sync();

    expect(pushed.outcome, SyncOutcome.synced);
    expect(pushed.pushed, greaterThanOrEqualTo(1));
    expect(pulled.pulled, 1);
    expect(b.store.records[_lesson], {'title': 'Food'});
    expect(b.tracker.pending, isEmpty);
  });

  test('a second sync with nothing changed sends nothing', () async {
    a.store.records[_lesson] = {'title': 'Food'};
    await a.sync();
    final requests = worker.pushRequests;
    final applies = a.store.applyCalls;

    final again = await a.sync();

    expect(again.pushed, 0);
    expect(again.pulled, 0);
    expect(worker.pushRequests, requests);
    expect(a.store.applyCalls, applies);
  });

  test('an edit and a deletion travel both ways', () async {
    a.store.records[_lesson] = {'title': 'Food'};
    a.store.records[_sentence] = {'text': 'Hi'};
    await a.sync();
    await b.sync();

    clock.now += 1000;
    b.store.records[_lesson] = {'title': 'Food and drink'};
    b.store.records.remove(_sentence);
    await b.sync();
    await a.sync();

    expect(a.store.records[_lesson], {'title': 'Food and drink'});
    expect(a.store.records.containsKey(_sentence), isFalse);
    expect(worker.isDeleted('sentence', await cipher.recordId(_sentence)),
        isTrue);
  });

  test('when both edit offline, the later edit wins on both', () async {
    a.store.records[_lesson] = {'title': 'Food'};
    await a.sync();
    await b.sync();

    clock.now += 1000;
    a.store.records[_lesson] = {'title': 'Earlier'};
    await a.sync();
    clock.now += 1000;
    b.store.records[_lesson] = {'title': 'Later'};
    // B has not pulled A's edit yet, and its own edit is newer.
    await b.sync();
    await a.sync();

    expect(a.store.records[_lesson], {'title': 'Later'});
    expect(b.store.records[_lesson], {'title': 'Later'});
  });

  test('an older offline edit loses to a newer one from the server', () async {
    a.store.records[_lesson] = {'title': 'Food'};
    await a.sync();
    await b.sync();

    clock.now += 1000;
    b.store.records[_lesson] = {'title': 'Older, on B'};
    // B notices its edit now, but only syncs after A's newer one.
    b.tracker.track(b.store.snapshot(b.tracker.deviceId), now: clock.now);
    clock.now += 1000;
    a.store.records[_lesson] = {'title': 'Newer, on A'};
    await a.sync();
    await b.sync();

    expect(b.store.records[_lesson], {'title': 'Newer, on A'});
  });

  test('AI discussion messages from both devices are kept', () async {
    Map<String, dynamic> message(String content, String at) => {
      'role': 'user',
      'content': content,
      'createdAt': at,
    };
    a.store.records[_chat] = {
      'messages': [message('First', '2026-11-05T10:00:00.000Z')],
    };
    await a.sync();
    await b.sync();

    clock.now += 1000;
    a.store.records[_chat] = {
      'messages': [
        message('First', '2026-11-05T10:00:00.000Z'),
        message('From A', '2026-11-05T11:00:00.000Z'),
      ],
    };
    b.store.records[_chat] = {
      'messages': [
        message('First', '2026-11-05T10:00:00.000Z'),
        message('From B', '2026-11-05T10:30:00.000Z'),
      ],
    };
    await a.sync();
    await b.sync();
    await a.sync();

    final expected = [
      message('First', '2026-11-05T10:00:00.000Z'),
      message('From B', '2026-11-05T10:30:00.000Z'),
      message('From A', '2026-11-05T11:00:00.000Z'),
    ];
    expect(a.store.records[_chat]!['messages'], expected);
    expect(b.store.records[_chat]!['messages'], expected);
  });

  test('a large record is split, joined, and its old parts deleted', () async {
    const markdown = SyncRecordKey('lesson_md', 'l1');
    final random = Random(3);
    final text = String.fromCharCodes([
      for (var i = 0; i < 120000; i++) 97 + random.nextInt(26),
    ]);
    a.store.records[markdown] = {'markdown': text};
    await a.sync();
    await b.sync();
    expect(b.store.records[markdown], {'markdown': text});
    final parts = a.tracker.records[markdown]!.parts;
    expect(parts, greaterThan(1));

    clock.now += 1000;
    a.store.records[markdown] = {'markdown': 'Short now'};
    await a.sync();
    await b.sync();

    expect(b.store.records[markdown], {'markdown': 'Short now'});
    expect(a.tracker.records[markdown]!.parts, 0);
    for (var index = 1; index <= parts; index++) {
      final id = await cipher.recordId(SyncEngine.partKey(markdown, index));
      expect(worker.isDeleted('lesson_md', id), isTrue, reason: 'part $index');
    }
  });

  test('a record from a newer app is left alone and not overwritten', () async {
    a.store.records[_lesson] = {'title': 'Food'};
    await a.sync();
    await b.sync();

    clock.now += 1000;
    // A newer app on A writes the lesson in a format this app does not know.
    final newer = await cipher.encode(
      _lesson,
      {'title': 'Food', 'icon': 'bowl'},
      updatedAt: clock.now,
      schemaVersion: SyncRecordCipher.schema + 1,
    );
    await SyncClient(
      endpoint: Uri.parse('https://sync.example.com'),
      email: 'reader@example.com',
      authKey: 'test-auth-key',
      client: worker.client(),
    ).push(newer);

    clock.now += 1000;
    b.store.records[_lesson] = {'title': 'Edited on the old app'};
    final result = await b.sync();

    expect(result.needsAppUpdate, [_lesson]);
    expect(b.store.records[_lesson], {'title': 'Edited on the old app'});
    final stored = worker.rows['lesson/${await cipher.recordId(_lesson)}']!;
    final payload = await cipher.decode(SyncRecord.fromJson(stored));
    expect((payload as SyncContents).schema, SyncRecordCipher.schema + 1);
  });

  test('a rejected sign-in stops without changing anything', () async {
    a.store.records[_lesson] = {'title': 'Food'};
    worker.rejectSignIn = true;

    final result = await a.sync();

    expect(result.outcome, SyncOutcome.signInRejected);
    expect(worker.rows, isEmpty);
    expect(a.store.records[_lesson], {'title': 'Food'});
  });

  test('a re-created account stops before anything is sent', () async {
    a.store.records[_lesson] = {'title': 'Food'};
    worker.createdAt = 2000;

    final result = await a.sync();

    expect(result.outcome, SyncOutcome.accountChanged);
    expect(worker.rows, isEmpty);
  });

  test('a record encrypted with another key is skipped and counted', () async {
    final stranger = Device(
      worker,
      await SyncRecordCipher.create(List<int>.filled(32, 9)),
      clock,
    );
    stranger.store.records[_lesson] = {'title': 'Not yours'};
    await stranger.sync();

    final result = await b.sync();

    expect(result.unreadable, 1);
    expect(b.store.records, isEmpty);
  });

  group('mergeDiscussions', () {
    test('keeps messages without a time before timed ones', () {
      final merged = SyncEngine.mergeDiscussions(
        {
          'messages': [
            {'role': 'user', 'content': 'Old'},
          ],
        },
        {
          'messages': [
            {
              'role': 'user',
              'content': 'New',
              'createdAt': '2026-11-05T10:00:00.000Z',
            },
            {'role': 'user', 'content': 'Old'},
          ],
        },
      );

      expect(
        [for (final m in merged['messages'] as List) (m as Map)['content']],
        ['Old', 'New'],
      );
    });
  });
}
