import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/ai_discussion_message.dart';
import 'package:lingua_srs/models/lesson.dart';
import 'package:lingua_srs/models/sentence.dart';
import 'package:lingua_srs/models/srs_card.dart';
import 'package:lingua_srs/models/vocab_item.dart';
import 'package:lingua_srs/services/sync_records.dart';

const _settings = SyncSettings(
  maxReviews24h: 100,
  maxNewCards24h: 10,
  autoplayAudio: true,
  pronunciationOptions: {'vocabulary_ipa', 'sentence_romanization'},
);

Map<SyncRecordKey, Map<String, dynamic>> _build({
  List<Lesson> lessons = const [],
  List<Sentence> sentences = const [],
  Map<String, List<AiDiscussionMessage>> aiDiscussions = const {},
  Map<String, int> lessonOrder = const {},
  Map<DateTime, int> dailyReviewCounts = const {},
  List<DateTime> reviewTimestamps = const [],
}) => SyncSnapshot.build(
  lessons: lessons,
  sentences: sentences,
  mergeHistory: const [],
  aiDiscussions: aiDiscussions,
  lessonOrder: lessonOrder,
  settings: _settings,
  dailyReviewCounts: dailyReviewCounts,
  reviewTimestamps: reviewTimestamps,
  deviceId: 'device-a',
);

VocabItem _vocab({String id = 'word'}) => VocabItem(
  id: id,
  targetWord: '목적지',
  translation: 'destination',
  pos: 'nouns',
  notes: 'A note',
  cardTargetToNative: SrsCard(
    id: 'card-tn',
    direction: CardDirection.targetToNative,
    backNotes: 'Back note',
    interval: 3,
  ),
  cardNativeToTarget: SrsCard(
    id: 'card-nt',
    direction: CardDirection.nativeToTarget,
    isEnabled: false,
  ),
);

void main() {
  group('SyncSnapshot.build', () {
    test('keeps shared details and cards out of the lesson record', () {
      final lesson = Lesson(
        id: 'lesson-1',
        title: 'L1',
        vocabularies: [_vocab()],
      );

      final records = _build(lessons: [lesson]);
      final entry =
          (records[const SyncRecordKey('lesson', 'lesson-1')]!['vocabularies']
                      as List)
                  .single
              as Map;

      expect(entry['targetWord'], '목적지');
      expect(entry['translation'], 'destination');
      for (final field in [
        'notes',
        'audioUrl',
        'cardTargetToNative',
        'cardNativeToTarget',
      ]) {
        expect(entry.containsKey(field), isFalse, reason: field);
      }
    });

    test('puts card settings in vocab and scheduling in card', () {
      final lesson = Lesson(
        id: 'lesson-1',
        title: 'L1',
        vocabularies: [_vocab()],
      );

      final records = _build(lessons: [lesson]);
      final vocab = records[const SyncRecordKey('vocab', 'word')]!;
      final card = records[const SyncRecordKey('card', 'card-tn')]!;

      expect(vocab['notes'], 'A note');
      expect(vocab['cards'], {
        'targetToNative': {
          'id': 'card-tn',
          'isEnabled': true,
          'frontHint': '',
          'backNotes': 'Back note',
        },
        'nativeToTarget': {
          'id': 'card-nt',
          'isEnabled': false,
          'frontHint': '',
          'backNotes': '',
        },
      });
      expect(card['interval'], 3);
      expect(card['vocabId'], 'word');
      expect(card.containsKey('backNotes'), isFalse);
      expect(card.containsKey('isEnabled'), isFalse);
      expect(
        records.containsKey(const SyncRecordKey('card', 'card-nt')),
        isTrue,
      );
    });

    test('stores a word used by two lessons once', () {
      final first = Lesson(id: 'a', title: 'A', vocabularies: [_vocab()]);
      final second = Lesson(id: 'b', title: 'B', vocabularies: [_vocab()]);

      final records = _build(lessons: [first, second]);

      expect(records.keys.where((key) => key.kind == 'vocab'), hasLength(1));
      expect(records.keys.where((key) => key.kind == 'card'), hasLength(2));
      expect(records.keys.where((key) => key.kind == 'lesson'), hasLength(2));
    });

    test('has a Markdown record only for a lesson with Markdown', () {
      final records = _build(
        lessons: [
          Lesson(id: 'with', title: 'With', markdownContent: '# Hello'),
          Lesson(id: 'without', title: 'Without'),
        ],
      );

      expect(records[const SyncRecordKey('lesson_md', 'with')], {
        'markdown': '# Hello',
      });
      expect(
        records.containsKey(const SyncRecordKey('lesson_md', 'without')),
        isFalse,
      );
    });

    test('adds sentences, discussions, the lesson order and settings', () {
      final records = _build(
        sentences: [
          Sentence(id: 's1', targetText: '가요', translationText: 'Go'),
        ],
        aiDiscussions: {
          'word:none': [
            const AiDiscussionMessage(role: 'user', content: 'Why?'),
          ],
        },
        lessonOrder: {'folder:a': 2},
      );

      expect(
        records[const SyncRecordKey('sentence', 's1')]!['targetText'],
        '가요',
      );
      expect(records[const SyncRecordKey('discussion', 'word:none')], {
        'messages': [
          {'role': 'user', 'content': 'Why?'},
        ],
      });
      expect(records[const SyncRecordKey('lesson_order', 'lesson_order')], {
        'order': {'folder:a': 2},
      });
      expect(records[const SyncRecordKey('settings', 'settings')], {
        'maxReviews24h': 100,
        'maxNewCards24h': 10,
        'autoplayAudio': true,
        'pronunciationOptions': ['sentence_romanization', 'vocabulary_ipa'],
      });
    });

    test("writes activity per device and day, with that day's reviews", () {
      final day = DateTime(2026, 11, 5);
      final review = DateTime(2026, 11, 5, 9, 30);
      final otherDay = DateTime(2026, 11, 4, 23, 0);

      final records = _build(
        dailyReviewCounts: {day: 7},
        reviewTimestamps: [review, otherDay],
      );

      expect(records[const SyncRecordKey('activity', 'device-a:2026-11-05')], {
        'day': '2026-11-05',
        'count': 7,
        'reviews': [review.toUtc().toIso8601String()],
      });
    });
  });

  group('SyncSnapshot.hash', () {
    test('does not depend on the order of keys', () {
      expect(
        SyncSnapshot.hash({
          'a': 1,
          'b': {'x': 1, 'y': 2},
        }),
        SyncSnapshot.hash({
          'b': {'y': 2, 'x': 1},
          'a': 1,
        }),
      );
    });

    test('changes with the contents', () {
      expect(SyncSnapshot.hash({'a': 1}), isNot(SyncSnapshot.hash({'a': 2})));
    });
  });

  group('SyncRecordKey', () {
    test('round-trips an id that contains a slash', () {
      const key = SyncRecordKey('discussion', 'lesson:a/b');

      expect(SyncRecordKey.parse(key.storageKey), key);
    });

    test('rejects a key without a kind', () {
      expect(() => SyncRecordKey.parse('/id'), throwsFormatException);
      expect(() => SyncRecordKey.parse('nokind'), throwsFormatException);
    });
  });

  group('SyncSnapshot.knownChangeTime', () {
    test("is a card's last review", () {
      expect(
        SyncSnapshot.knownChangeTime(const SyncRecordKey('card', 'c'), {
          'lastReviewed': '2026-11-05T10:00:00.000Z',
        }),
        DateTime.utc(2026, 11, 5, 10).millisecondsSinceEpoch,
      );
      expect(
        SyncSnapshot.knownChangeTime(const SyncRecordKey('card', 'c'), {
          'lastReviewed': null,
        }),
        0,
      );
    });

    test("is a discussion's latest message", () {
      expect(
        SyncSnapshot.knownChangeTime(const SyncRecordKey('discussion', 'd'), {
          'messages': [
            {
              'role': 'user',
              'content': 'a',
              'createdAt': '2026-11-05T12:00:00.000Z',
            },
            {
              'role': 'user',
              'content': 'b',
              'createdAt': '2026-11-05T09:00:00.000Z',
            },
            {'role': 'user', 'content': 'c'},
          ],
        }),
        DateTime.utc(2026, 11, 5, 12).millisecondsSinceEpoch,
      );
    });

    test('is 0 when the contents do not tell', () {
      expect(
        SyncSnapshot.knownChangeTime(const SyncRecordKey('lesson', 'l'), {
          'title': 'Food',
        }),
        0,
      );
    });
  });
}
