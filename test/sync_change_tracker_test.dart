import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/services/sync_change_tracker.dart';
import 'package:lingua_srs/services/sync_records.dart';

const _lesson = SyncRecordKey('lesson', 'l1');
const _sentence = SyncRecordKey('sentence', 's1');
const _vocab = SyncRecordKey('vocab', 'v1');
const _card = SyncRecordKey('card', 'c1');

void main() {
  group('SyncChangeTracker.track', () {
    test('sees every record as new the first time', () {
      final tracker = SyncChangeTracker(deviceId: 'device');

      final changed = tracker.track({
        _lesson: {'title': 'A'},
        _sentence: {'text': 'B'},
      }, now: 1000);

      expect(changed, unorderedEquals([_lesson, _sentence]));
      expect(tracker.pending, unorderedEquals([_lesson, _sentence]));
      expect(tracker.records[_lesson]!.updatedAt, 1000);
    });

    test('ignores records that did not change', () {
      final tracker = SyncChangeTracker(deviceId: 'device');
      tracker.track({
        _lesson: {'title': 'A', 'unit': 'U'},
      }, now: 1000);

      final changed = tracker.track({
        _lesson: {'unit': 'U', 'title': 'A'},
      }, now: 2000);

      expect(changed, isEmpty);
      expect(tracker.records[_lesson]!.updatedAt, 1000);
    });

    test('stamps a changed record with the time it was noticed', () {
      final tracker = SyncChangeTracker(deviceId: 'device');
      tracker.track({
        _lesson: {'title': 'A'},
      }, now: 1000);
      tracker.markPushed(_lesson, 1000);

      final changed = tracker.track({
        _lesson: {'title': 'B'},
      }, now: 2000);

      expect(changed, [_lesson]);
      expect(tracker.records[_lesson]!.updatedAt, 2000);
      expect(tracker.pending, [_lesson]);
    });

    test('keeps a removed record as deleted, so the deletion syncs', () {
      final tracker = SyncChangeTracker(deviceId: 'device');
      tracker.track({
        _lesson: {'title': 'A'},
        _sentence: {'text': 'B'},
      }, now: 1000);

      final changed = tracker.track({
        _lesson: {'title': 'A'},
      }, now: 2000);

      final state = tracker.records[_sentence]!;
      expect(changed, [_sentence]);
      expect(state.deleted, isTrue);
      expect(state.pending, isTrue);
      expect(state.updatedAt, 2000);
      expect(
        tracker.track({
          _lesson: {'title': 'A'},
        }, now: 3000),
        isEmpty,
      );
    });

    test('brings a deleted record back when it reappears', () {
      final tracker = SyncChangeTracker(deviceId: 'device');
      tracker.track({
        _sentence: {'text': 'B'},
      }, now: 1000);
      tracker.track({}, now: 2000);

      final changed = tracker.track({
        _sentence: {'text': 'B'},
      }, now: 3000);

      expect(changed, [_sentence]);
      expect(tracker.records[_sentence]!.deleted, isFalse);
      expect(tracker.records[_sentence]!.updatedAt, 3000);
    });

    test('never deletes vocab and card records', () {
      final tracker = SyncChangeTracker(deviceId: 'device');
      tracker.track({
        _vocab: {'notes': ''},
        _card: {'interval': 1},
      }, now: 1000);

      final changed = tracker.track({}, now: 2000);

      expect(changed, isEmpty);
      expect(tracker.records[_vocab]!.deleted, isFalse);
      expect(tracker.records[_card]!.deleted, isFalse);
    });

    test('keeps a change newer than the last one when the clock goes back', () {
      final tracker = SyncChangeTracker(deviceId: 'device');
      tracker.track({
        _lesson: {'title': 'A'},
      }, now: 5000);

      tracker.track({
        _lesson: {'title': 'B'},
      }, now: 1000);

      expect(tracker.records[_lesson]!.updatedAt, 5001);
    });
  });

  group('SyncChangeTracker pushing', () {
    test('lists pending records oldest change first', () {
      final tracker = SyncChangeTracker(deviceId: 'device');
      tracker.track({
        _sentence: {'text': 'B'},
      }, now: 2000);
      tracker.track({
        _sentence: {'text': 'B'},
        _lesson: {'title': 'A'},
      }, now: 3000);

      expect(tracker.pending, [_sentence, _lesson]);
    });

    test('markPushed clears only the version that was pushed', () {
      final tracker = SyncChangeTracker(deviceId: 'device');
      tracker.track({
        _lesson: {'title': 'A'},
      }, now: 1000);
      tracker.track({
        _lesson: {'title': 'B'},
      }, now: 2000);

      tracker.markPushed(_lesson, 1000);
      expect(tracker.pending, [_lesson]);

      tracker.markPushed(_lesson, 2000);
      expect(tracker.pending, isEmpty);
    });
  });

  group('SyncChangeTracker storage', () {
    test('round-trips through JSON', () {
      final tracker = SyncChangeTracker(deviceId: 'device')..cursor = 42;
      tracker.track({
        _lesson: {'title': 'A'},
        const SyncRecordKey('discussion', 'lesson:a/b'): {'messages': []},
      }, now: 1000);
      tracker.markPushed(_lesson, 1000);
      tracker.track({
        const SyncRecordKey('discussion', 'lesson:a/b'): {'messages': []},
      }, now: 2000);

      final restored = SyncChangeTracker.fromJson(tracker.toJson());

      expect(restored.deviceId, 'device');
      expect(restored.cursor, 42);
      expect(restored.pending, tracker.pending);
      expect(restored.records[_lesson]!.deleted, isTrue);
      expect(
        restored.track({
          const SyncRecordKey('discussion', 'lesson:a/b'): {'messages': []},
        }, now: 3000),
        isEmpty,
      );
    });

    test('rejects state from another version or with missing fields', () {
      final json = SyncChangeTracker(deviceId: 'device').toJson();

      for (final bad in [
        {...json, 'version': 2},
        {...json, 'deviceId': ''},
        {...json, 'cursor': '0'},
        {...json, 'records': []},
      ]) {
        expect(
          () => SyncChangeTracker.fromJson(bad),
          throwsFormatException,
          reason: '$bad',
        );
      }
    });

    test('makes a random device id', () {
      expect(SyncChangeTracker().deviceId, isNot(SyncChangeTracker().deviceId));
    });

    test('reset forgets records and the cursor but keeps the device id', () {
      final tracker = SyncChangeTracker(deviceId: 'device')..cursor = 9;
      tracker.track({
        _lesson: {'title': 'A'},
      }, now: 1000);

      tracker.reset();

      expect(tracker.deviceId, 'device');
      expect(tracker.cursor, 0);
      expect(tracker.records, isEmpty);
    });
  });

  group('SyncChangeTracker and the server', () {
    test('a pulled version is not pending and not seen as a change', () {
      final tracker = SyncChangeTracker(deviceId: 'device');

      tracker.acceptRemote(
        _lesson,
        hash: SyncSnapshot.hash({'title': 'A'}),
        updatedAt: 500,
        parts: 3,
      );

      expect(tracker.pending, isEmpty);
      expect(tracker.records[_lesson]!.parts, 3);
      expect(
        tracker.track({
          _lesson: {'title': 'A'},
        }, now: 1000),
        isEmpty,
      );
    });

    test('a local change keeps the part count and the block', () {
      final tracker = SyncChangeTracker(deviceId: 'device');
      tracker.track({
        _lesson: {'title': 'A'},
      }, now: 1000);
      tracker.markPushed(_lesson, 1000, parts: 4);
      tracker.block(_lesson, 2000);

      tracker.track({
        _lesson: {'title': 'B'},
      }, now: 3000);

      final state = tracker.records[_lesson]!;
      expect(state.parts, 4);
      expect(state.blocked, isTrue);
    });

    test('recordLocal makes a version to push at the given time', () {
      final tracker = SyncChangeTracker(deviceId: 'device');

      tracker.recordLocal(_lesson, hash: 'h', updatedAt: 777);

      expect(tracker.pending, [_lesson]);
      expect(tracker.records[_lesson]!.updatedAt, 777);
    });

    test('held parts and blocks survive saving', () {
      final tracker = SyncChangeTracker(deviceId: 'device');
      tracker.holdPart(_lesson, 2, [1, 2, 3]);
      tracker.block(_sentence, 10);

      final restored = SyncChangeTracker.fromJson(
        jsonDecode(jsonEncode(tracker.toJson())) as Map<String, dynamic>,
      );

      expect(restored.heldParts(_lesson), {
        2: [1, 2, 3],
      });
      expect(restored.records[_sentence]!.blocked, isTrue);
      restored.releaseParts(_lesson);
      expect(restored.heldParts(_lesson), isEmpty);
    });
  });

  group('SyncChangeTracker before the first pull', () {
    int stampNew(SyncRecordKey key, Map<String, dynamic> data) =>
        data['changedAt'] as int? ?? 0;

    test('stamps new records with when they really changed', () {
      final tracker = SyncChangeTracker(deviceId: 'device');

      tracker.track({
        _lesson: {'title': 'A'},
        _card: {'changedAt': 700},
      }, now: 5000, stampNew: stampNew);

      expect(tracker.records[_lesson]!.updatedAt, 0);
      expect(tracker.records[_card]!.updatedAt, 700);
      expect(tracker.pending, unorderedEquals([_lesson, _card]));
    });

    test('stamps later edits, and anything after the first pull, with now',
        () {
      final tracker = SyncChangeTracker(deviceId: 'device');
      tracker.track({
        _lesson: {'title': 'A'},
      }, now: 5000, stampNew: stampNew);

      tracker.track({
        _lesson: {'title': 'B'},
      }, now: 6000, stampNew: stampNew);
      expect(tracker.records[_lesson]!.updatedAt, 6000);

      tracker.hasPulled = true;
      tracker.track({
        _lesson: {'title': 'B'},
        _sentence: {'text': 'new'},
      }, now: 7000, stampNew: stampNew);
      expect(tracker.records[_sentence]!.updatedAt, 7000);
    });

    test('is remembered, and forgotten by reset', () {
      final tracker = SyncChangeTracker(deviceId: 'device')..hasPulled = true;

      final restored = SyncChangeTracker.fromJson(
        jsonDecode(jsonEncode(tracker.toJson())) as Map<String, dynamic>,
      );
      expect(restored.hasPulled, isTrue);

      restored.reset();
      expect(restored.hasPulled, isFalse);
    });

    test('state saved before it was kept counts a cursor as having pulled',
        () {
      final json = SyncChangeTracker(deviceId: 'device').toJson()
        ..['cursor'] = 5;

      expect(SyncChangeTracker.fromJson(json).hasPulled, isTrue);
    });
  });
}
