import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/services/sync_client.dart';
import 'package:lingua_srs/services/sync_pairing.dart';
import 'package:lingua_srs/services/sync_record_cipher.dart';
import 'package:lingua_srs/services/sync_records.dart';

final _dataKey = List<int>.generate(32, (i) => i);
final _otherKey = List<int>.generate(32, (i) => 255 - i);
const _word = SyncRecordKey('vocab', 'auto-목적지');

/// Text that gzip cannot shrink much, so it needs several parts.
String _randomText(int length, int seed) {
  final random = Random(seed);
  const letters = 'abcdefghijklmnopqrstuvwxyz0123456789';
  return String.fromCharCodes([
    for (var i = 0; i < length; i++)
      letters.codeUnitAt(random.nextInt(letters.length)),
  ]);
}

SyncRecord _withId(SyncRecord record, {String? kind, String? id}) => SyncRecord(
  kind: kind ?? record.kind,
  id: id ?? record.id,
  updatedAt: record.updatedAt,
  data: record.data,
);

void main() {
  late SyncRecordCipher cipher;

  setUp(() async {
    cipher = await SyncRecordCipher.create(_dataKey);
  });

  group('record ids', () {
    test('are 43 base64url characters that hide the local id', () async {
      final id = await cipher.recordId(_word);

      expect(id, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
      expect(id, isNot(contains('목적지')));
    });

    test('are the same for the same key and record', () async {
      final again = await SyncRecordCipher.create(_dataKey);

      expect(await again.recordId(_word), await cipher.recordId(_word));
    });

    test('differ by kind, local id and data key', () async {
      final id = await cipher.recordId(_word);
      final other = await SyncRecordCipher.create(_otherKey);

      expect(
        await cipher.recordId(const SyncRecordKey('card', 'auto-목적지')),
        isNot(id),
      );
      expect(
        await cipher.recordId(const SyncRecordKey('vocab', 'auto-other')),
        isNot(id),
      );
      expect(await other.recordId(_word), isNot(id));
    });
  });

  group('a small record', () {
    test('is one record that decrypts to its contents', () async {
      final records = await cipher.encode(_word, {
        'notes': '목적지 means destination',
      }, updatedAt: 1234);

      final record = records.single;
      expect(record.kind, 'vocab');
      expect(record.id, await cipher.recordId(_word));
      expect(record.updatedAt, 1234);
      expect(record.deleted, isFalse);
      expect(record.data.keys, unorderedEquals(['v', 'n', 'c']));
      expect(jsonEncode(record.data), isNot(contains('destination')));

      final payload = await cipher.decode(record) as SyncContents;
      expect(payload.key, _word);
      expect(payload.schema, SyncRecordCipher.schema);
      expect(payload.data, {'notes': '목적지 means destination'});
    });

    test('uses a new nonce every time', () async {
      final first = await cipher.encode(_word, {'a': 1}, updatedAt: 1);
      final second = await cipher.encode(_word, {'a': 1}, updatedAt: 1);

      expect(first.single.data['n'], isNot(second.single.data['n']));
    });

    test('cannot be opened with another data key', () async {
      final record = (await cipher.encode(_word, {
        'a': 1,
      }, updatedAt: 1)).single;
      final other = await SyncRecordCipher.create(_otherKey);

      await expectLater(other.decode(record), throwsFormatException);
    });

    test('cannot be moved to another id or kind', () async {
      final record = (await cipher.encode(_word, {
        'a': 1,
      }, updatedAt: 1)).single;
      final otherId = await cipher.recordId(
        const SyncRecordKey('vocab', 'other'),
      );

      await expectLater(
        cipher.decode(_withId(record, id: otherId)),
        throwsFormatException,
      );
      await expectLater(
        cipher.decode(_withId(record, kind: 'card')),
        throwsFormatException,
      );
    });

    test('rejects an unknown envelope version', () async {
      final record = (await cipher.encode(_word, {
        'a': 1,
      }, updatedAt: 1)).single;

      await expectLater(
        cipher.decode(
          SyncRecord(
            kind: record.kind,
            id: record.id,
            updatedAt: record.updatedAt,
            data: {...record.data, 'v': 2},
          ),
        ),
        throwsFormatException,
      );
    });
  });

  group('a large record', () {
    const lesson = SyncRecordKey('lesson_md', 'lesson-1');
    final markdown = _randomText(120000, 7);

    test('is split into parts, each small enough for the Worker', () async {
      final records = await cipher.encode(lesson, {
        'markdown': markdown,
      }, updatedAt: 99);

      expect(records.length, greaterThan(2));
      for (final record in records) {
        expect(
          utf8.encode(jsonEncode(record.data)).length,
          lessThanOrEqualTo(SyncRecordCipher.maxEnvelopeBytes),
        );
        expect(record.updatedAt, 99);
        expect(record.kind, 'lesson_md');
      }
      // The head that lists the parts comes last, after the parts.
      expect(records.last.id, await cipher.recordId(lesson));
    });

    test('joins back together from its parts', () async {
      final records = await cipher.encode(lesson, {
        'markdown': markdown,
      }, updatedAt: 99);
      final payloads = [for (final r in records) await cipher.decode(r)];

      final head = payloads.last as SyncSplitHead;
      final parts = {
        for (final part in payloads.whereType<SyncPart>())
          part.index: part.bytes,
      };
      expect(head.parts, records.length - 1);
      expect(
        payloads.whereType<SyncPart>().every((part) => part.head == lesson),
        isTrue,
      );

      final joined = cipher.join(head, parts);
      expect(joined.key, lesson);
      expect(joined.data, {'markdown': markdown});
    });

    test('refuses to join with a part missing or out of place', () async {
      final records = await cipher.encode(lesson, {
        'markdown': markdown,
      }, updatedAt: 99);
      final payloads = [for (final r in records) await cipher.decode(r)];
      final head = payloads.last as SyncSplitHead;
      final parts = {
        for (final part in payloads.whereType<SyncPart>())
          part.index: part.bytes,
      };

      expect(
        () => cipher.join(head, Map.of(parts)..remove(2)),
        throwsFormatException,
      );
      expect(
        () => cipher.join(head, {...parts, 1: parts[2]!, 2: parts[1]!}),
        throwsFormatException,
      );
    });
  });

  group('deletion', () {
    test('is a tombstone with the record id', () async {
      final record = await cipher.tombstone(_word, updatedAt: 5);

      expect(record.deleted, isTrue);
      expect(record.id, await cipher.recordId(_word));
      expect(record.data, isEmpty);
    });

    test('a tombstone has nothing to decrypt', () async {
      final record = await cipher.tombstone(_word, updatedAt: 5);

      await expectLater(cipher.decode(record), throwsArgumentError);
    });
  });

  group('SyncDataKey', () {
    final endpoint = Uri.parse('https://sync.example.com');

    test('round-trips through JSON', () {
      final key = SyncDataKey(
        endpoint: endpoint,
        email: 'reader@example.com',
        createdAt: 42,
        key: _dataKey,
        authKey: 'derived-auth-key',
      );

      final restored = SyncDataKey.fromJson(key.toJson());
      expect(restored.authKey, 'derived-auth-key');

      expect(restored.endpoint, endpoint);
      expect(restored.email, 'reader@example.com');
      expect(restored.createdAt, 42);
      expect(restored.key, _dataKey);
    });

    test('rejects a key that is not 32 bytes', () {
      final json = SyncDataKey(
        endpoint: endpoint,
        email: 'reader@example.com',
        createdAt: null,
        key: _dataKey,
      ).toJson();

      expect(
        () => SyncDataKey.fromJson({
          ...json,
          'key': base64Url.encode([1, 2]),
        }),
        throwsFormatException,
      );
    });

    test('belongs only to its own server and email', () {
      final key = SyncDataKey(
        endpoint: endpoint,
        email: 'reader@example.com',
        createdAt: 42,
        key: _dataKey,
      );
      const password = 'correct horse battery staple';

      expect(
        key.belongsTo(
          SyncPairing(
            endpoint: endpoint,
            email: 'reader@example.com',
            password: password,
          ),
        ),
        isTrue,
      );
      expect(
        key.belongsTo(
          SyncPairing(
            endpoint: endpoint,
            email: 'other@example.com',
            password: password,
          ),
        ),
        isFalse,
      );
      expect(
        key.belongsTo(
          SyncPairing(
            endpoint: Uri.parse('https://other.example.com'),
            email: 'reader@example.com',
            password: password,
          ),
        ),
        isFalse,
      );
    });
  });

  group('packs', () {
    test('hold many records in records the Worker accepts', () async {
      final entries = [
        for (var i = 0; i < 400; i++)
          SyncPackEntry(
            SyncRecordKey('vocab', 'w$i'),
            updatedAt: 1000 + i,
            data: {'text': _randomText(300, i)},
          ),
      ];

      final result = await cipher.pack('device/1', entries, updatedAt: 5000);

      expect(result.tooLarge, isEmpty);
      // Text gzip cannot shrink still needs several packs.
      expect(result.packs.length, greaterThan(1));
      expect(result.packs.length, lessThan(20));
      final read = <SyncPackEntry>[];
      for (final pack in result.packs) {
        expect(pack.record.kind, SyncKinds.pack);
        expect(pack.record.updatedAt, 5000);
        expect(
          utf8.encode(jsonEncode(pack.record.data)).length,
          lessThanOrEqualTo(SyncRecordCipher.maxEnvelopeBytes),
        );
        final payload = await cipher.decode(pack.record) as SyncPack;
        expect(
          payload.entries.map((entry) => entry.key),
          pack.entries.map((entry) => entry.key),
        );
        read.addAll(payload.entries);
      }
      expect(read.length, 400);
      expect(read[7].key, const SyncRecordKey('vocab', 'w7'));
      expect(read[7].updatedAt, 1007);
      expect(read[7].schema, SyncRecordCipher.schema);
      expect(read[7].data, {'text': _randomText(300, 7)});
    });

    test('leave out a record too large for a pack of its own', () async {
      final large = SyncPackEntry(
        const SyncRecordKey('lesson_md', 'big'),
        updatedAt: 1,
        data: {'markdown': _randomText(60000, 1)},
      );
      final small = SyncPackEntry(
        const SyncRecordKey('lesson', 'l1'),
        updatedAt: 1,
        data: {'title': 'Food'},
      );

      final result = await cipher.pack('p', [small, large], updatedAt: 1);

      expect(result.tooLarge, [large]);
      expect(result.packs.single.entries, [small]);
    });

    test('carry a schema an app from before packs does not read', () async {
      // An older app reads the pack as contents of a newer schema, and
      // reports that it needs an update instead of losing records.
      expect(SyncRecordCipher.packSchema, greaterThan(SyncRecordCipher.schema));
    });
  });
}
