import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/services/sync_change_tracker.dart';
import 'package:lingua_srs/services/sync_client.dart';
import 'package:lingua_srs/services/sync_engine.dart';
import 'package:lingua_srs/services/sync_record_cipher.dart';
import 'package:lingua_srs/services/sync_records.dart';

import 'fake_sync_worker.dart';

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
  Future<void> apply(
    String deviceId,
    Map<SyncRecordKey, Map<String, dynamic>?> changes, {
    bool firstSync = false,
  }) async {
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

/// Keeps its own copy of [kept] instead of the pulled one, as the app does
/// with a card reviewed more recently on this device.
class KeepingStore extends MemoryStore {
  KeepingStore(this.kept);

  final SyncRecordKey kept;

  @override
  Future<void> apply(
    String deviceId,
    Map<SyncRecordKey, Map<String, dynamic>?> changes, {
    bool firstSync = false,
  }) => super.apply(deviceId, {...changes}..remove(kept), firstSync: firstSync);
}

class Device {
  Device(
    this.worker,
    this.cipher,
    this.clock, {
    this.createdAt = 1000,
    MemoryStore? store,
  }) : store = store ?? MemoryStore();

  final FakeWorker worker;
  final SyncRecordCipher cipher;
  final Clock clock;
  final int? createdAt;
  final MemoryStore store;
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

  test('a push stopped by the daily write limit goes on from there', () async {
    // Fewer records than go in packs, so each is a server record.
    for (var i = 0; i < 150; i++) {
      a.store.records[SyncRecordKey('vocab', 'w$i')] = {'word': 'w$i'};
    }
    worker.writesLeft = 100;

    await expectLater(
      a.sync(),
      throwsA(
        isA<SyncException>().having((e) => e.statusCode, 'statusCode', 429),
      ),
    );

    // The batch that got through is kept as pushed.
    expect(worker.rows.length, 100);
    expect(a.tracker.pending.length, 50);

    // The next day only the rest is sent.
    worker.writesLeft = 50;
    clock.now += 1000;
    final next = await a.sync();

    expect(next.outcome, SyncOutcome.synced);
    expect(next.pushed, 50);
    expect(worker.rows.length, 150);
    expect(a.tracker.pending, isEmpty);
  });

  group('a large push goes in packs', () {
    SyncRecordKey lesson(int i) => SyncRecordKey('lesson', 'l$i');

    void addLessons(Device device, int count) {
      for (var i = 0; i < count; i++) {
        device.store.records[lesson(i)] = {
          'title': 'Lesson $i',
          'text': 'Some words to study in lesson number $i. ' * 10,
        };
      }
    }

    test('a first sync of a large library fits the daily limit', () async {
      addLessons(a, 3000);
      // Far fewer than one write per record.
      worker.writesLeft = 100;

      final pushed = await a.sync();

      expect(pushed.pushed, 3000);
      expect(worker.rows.length, lessThan(100));
      expect(a.tracker.pending, isEmpty);

      clock.now += 1000;
      final pulled = await b.sync();

      expect(pulled.pulled, 3000);
      expect(pulled.unreadable, 0);
      expect(b.store.records, a.store.records);
      expect(b.tracker.pending, isEmpty);
    });

    test('a later change of a packed record reaches a new device', () async {
      addLessons(a, 300);
      await a.sync();

      clock.now += 1000;
      a.store.records[lesson(7)] = {'title': 'Changed'};
      a.store.records.remove(lesson(8));
      await a.sync();

      clock.now += 1000;
      await b.sync();

      expect(b.store.records[lesson(7)], {'title': 'Changed'});
      // A deletion after the pack keeps the record deleted.
      expect(b.store.records.containsKey(lesson(8)), isFalse);
      expect(b.store.records.length, 299);
    });

    test('an older copy in a pack does not undo a newer one', () async {
      a.store.records[lesson(1)] = {'title': 'First'};
      await a.sync();
      // An edit after the first sync is stamped with the time.
      clock.now += 5000;
      a.store.records[lesson(1)] = {'title': 'New'};
      await a.sync();
      expect(a.tracker.records[lesson(1)]!.updatedAt, clock.now);
      // Pull that edit back, so the pack below comes in a pull of its own.
      await a.sync();

      // Another device's pack, written with an older copy.
      final packs = await cipher.pack('other', [
        SyncPackEntry(
          lesson(1),
          updatedAt: clock.now - 4000,
          data: {'title': 'Old'},
        ),
        SyncPackEntry(
          lesson(2),
          updatedAt: clock.now - 4000,
          data: {'title': 'Two'},
        ),
      ], updatedAt: clock.now);
      await SyncClient(
        endpoint: Uri.parse('https://sync.example.com'),
        email: 'reader@example.com',
        authKey: 'test-auth-key',
        client: worker.client(),
      ).push([for (final pack in packs.packs) pack.record]);

      clock.now += 1000;
      await a.sync();
      await b.sync();

      for (final device in [a, b]) {
        expect(device.store.records[lesson(1)], {'title': 'New'});
        expect(device.store.records[lesson(2)], {'title': 'Two'});
      }
      expect(a.tracker.pending, isEmpty);
    });
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
    expect(
      worker.isDeleted('sentence', await cipher.recordId(_sentence)),
      isTrue,
    );
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

  test('joining an account keeps its copy unless this one is newer', () async {
    const card = SyncRecordKey('card', 'c1');
    a.store.records[_lesson] = {'title': 'On the account'};
    a.store.records[card] = {'lastReviewed': '2026-11-01T00:00:00.000Z'};
    await a.sync();

    clock.now += 100000;
    // B has studied too before signing in: its lesson edit has no known
    // time, but its card was reviewed after A's.
    b.store.records[_lesson] = {'title': 'On the new device'};
    b.store.records[card] = {'lastReviewed': '2026-11-03T00:00:00.000Z'};
    await b.sync();
    await a.sync();

    expect(b.store.records[_lesson], {'title': 'On the account'});
    expect(a.store.records[card], {'lastReviewed': '2026-11-03T00:00:00.000Z'});
    expect(b.tracker.hasPulled, isTrue);
  });

  test('pushes back what the store kept instead of the pulled copy', () async {
    a.store.records[_lesson] = {'title': 'Food'};
    await a.sync();
    final keeper = Device(worker, cipher, clock, store: KeepingStore(_lesson));
    keeper.store.records[_lesson] = {'title': 'Kept here'};
    await keeper.sync();

    clock.now += 1000;
    await a.sync();

    expect(keeper.store.records[_lesson], {'title': 'Kept here'});
    expect(a.store.records[_lesson], {'title': 'Kept here'});
  });

  test('an edit of a sentence beats its deletion on another device', () async {
    a.store.records[_sentence] = {'text': 'Old'};
    await a.sync();
    await b.sync();

    clock.now += 1000;
    // B edits the sentence, but has not synced yet when A deletes it later,
    // as A does when it merges a duplicate.
    b.store.records[_sentence] = {'text': 'Edited on B'};
    b.tracker.track(b.store.snapshot(b.tracker.deviceId), now: clock.now);
    clock.now += 1000;
    a.store.records.remove(_sentence);
    await a.sync();

    clock.now += 1000;
    await b.sync();
    await a.sync();

    expect(b.store.records[_sentence], {'text': 'Edited on B'});
    expect(a.store.records[_sentence], {'text': 'Edited on B'});
  });

  test('a newer deletion of a lesson still wins over an older edit', () async {
    a.store.records[_lesson] = {'title': 'Food'};
    await a.sync();
    await b.sync();

    clock.now += 1000;
    b.store.records[_lesson] = {'title': 'Edited on B'};
    b.tracker.track(b.store.snapshot(b.tracker.deviceId), now: clock.now);
    clock.now += 1000;
    a.store.records.remove(_lesson);
    await a.sync();
    await b.sync();

    expect(b.store.records.containsKey(_lesson), isFalse);
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
