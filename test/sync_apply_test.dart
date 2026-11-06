import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/ai_discussion_message.dart';
import 'package:lingua_srs/models/lesson.dart';
import 'package:lingua_srs/models/sentence.dart';
import 'package:lingua_srs/models/srs_card.dart';
import 'package:lingua_srs/models/vocab_item.dart';
import 'package:lingua_srs/services/sync_apply.dart';
import 'package:lingua_srs/services/sync_records.dart';

SyncAppData _empty(String deviceId) => SyncAppData(
  deviceId: deviceId,
  lessons: [],
  sentences: [],
  mergeHistory: [],
  aiDiscussions: {},
  lessonOrder: {},
  maxReviews24h: 100,
  maxNewCards24h: 10,
  autoplayAudio: true,
  pronunciationOptions: {},
  remoteActivity: {},
);

Map<SyncRecordKey, Map<String, dynamic>> _snapshot(
  SyncAppData data, {
  Map<DateTime, int> dailyReviewCounts = const {},
}) => SyncSnapshot.build(
  lessons: data.lessons,
  sentences: data.sentences,
  mergeHistory: data.mergeHistory,
  aiDiscussions: data.aiDiscussions,
  lessonOrder: data.lessonOrder,
  settings: SyncSettings(
    maxReviews24h: data.maxReviews24h,
    maxNewCards24h: data.maxNewCards24h,
    autoplayAudio: data.autoplayAudio,
    pronunciationOptions: data.pronunciationOptions,
  ),
  dailyReviewCounts: dailyReviewCounts,
  reviewTimestamps: const [],
  deviceId: data.deviceId,
);

VocabItem _word(String id, {int interval = 0, String notes = ''}) => VocabItem(
  id: id,
  targetWord: 'word-$id',
  translation: 'meaning-$id',
  pos: 'nouns',
  notes: notes,
  sentenceIds: ['s1'],
  cardTargetToNative: SrsCard(
    id: '$id-tn',
    direction: CardDirection.targetToNative,
    interval: interval,
    repetitions: interval > 0 ? 2 : 0,
    status: interval > 0 ? SrsStatus.review : SrsStatus.isNew,
    dueDate: DateTime.utc(2026, 11, 10),
    lastReviewed: interval > 0 ? DateTime.utc(2026, 11, 4) : null,
    backNotes: 'back of $id',
  ),
  cardNativeToTarget: SrsCard(
    id: '$id-nt',
    direction: CardDirection.nativeToTarget,
    isEnabled: false,
    dueDate: DateTime.utc(2026, 11, 10),
  ),
);

/// Two lessons sharing word `w2`, Markdown, a sentence, a discussion, an
/// order and settings.
SyncAppData _filled() {
  final data = _empty('device-a');
  final shared = _word('w2', interval: 4, notes: 'shared note');
  data.lessons = [
    Lesson(
      id: 'l1',
      title: 'Food',
      markdownContent: '# Food',
      vocabularies: [_word('w1', interval: 2), shared],
    ),
    Lesson(
      id: 'l2',
      title: 'Drink',
      vocabularies: [
        VocabItem(
          id: 'w2',
          targetWord: 'word-w2',
          translation: 'meaning-w2',
          pos: 'nouns',
        )..shared = shared.shared,
      ],
    ),
  ];
  data.sentences = [
    Sentence(id: 's1', targetText: '가요', translationText: 'Go'),
  ];
  data.aiDiscussions = {
    'w1:none': [
      AiDiscussionMessage(
        role: 'user',
        content: 'Why?',
        createdAt: DateTime.utc(2026, 11, 5, 9),
      ),
    ],
  };
  data.lessonOrder = {'folder:food': 1};
  data.maxReviews24h = 50;
  data.maxNewCards24h = 5;
  data.autoplayAudio = false;
  data.pronunciationOptions = {'vocabulary_ipa'};
  return data;
}

void main() {
  test('a whole snapshot applied to an empty device gives it back', () {
    final source = _filled();
    final records = _snapshot(source);
    final target = _empty('device-b');

    SyncApplier.apply(target, records);

    final copied = _snapshot(target);
    // Activity is per device, so it is not part of the comparison.
    bool notActivity(SyncRecordKey key) => key.kind != SyncKinds.activity;
    expect(
      {
        for (final e in copied.entries)
          if (notActivity(e.key)) e.key: e.value,
      },
      {
        for (final e in records.entries)
          if (notActivity(e.key)) e.key: e.value,
      },
    );
    expect(target.lessons.first.markdownContent, '# Food');
    expect(target.autoplayAudio, isFalse);
    expect(target.pronunciationOptions, {'vocabulary_ipa'});
  });

  test('a word in two lessons shares one set of details and cards', () {
    final target = _empty('device-b');

    SyncApplier.apply(target, _snapshot(_filled()));

    final first = target.lessons[0].vocabularies[1];
    final second = target.lessons[1].vocabularies.single;
    expect(identical(first.shared, second.shared), isTrue);
    expect(second.shared.notes, 'shared note');
    expect(second.cardTargetToNative.interval, 4);
  });

  test('pulled progress changes the card in place', () {
    final data = _filled();
    final card = data.lessons.first.vocabularies.first.cardTargetToNative;
    final json = _snapshot(data)[SyncRecordKey('card', card.id)]!;

    final changed = SyncApplier.apply(data, {
      SyncRecordKey('card', card.id): {...json, 'interval': 9, 'lapses': 1},
    });

    expect(changed, contains(SyncAppPart.lessons));
    expect(
      identical(data.lessons.first.vocabularies.first.cardTargetToNative, card),
      isTrue,
    );
    expect(card.interval, 9);
    expect(card.lapses, 1);
    // Settings come from the vocab record, so they stay.
    expect(card.backNotes, 'back of w1');
  });

  test('pulled details keep the progress already here', () {
    final data = _filled();
    final records = _snapshot(data);
    final vocab = records[const SyncRecordKey('vocab', 'w1')]!;

    SyncApplier.apply(data, {
      const SyncRecordKey('vocab', 'w1'): {...vocab, 'notes': 'New note'},
    });

    final word = data.lessons.first.vocabularies.first;
    expect(word.shared.notes, 'New note');
    expect(word.cardTargetToNative.interval, 2);
  });

  test('a deleted lesson, sentence and discussion are removed', () {
    final data = _filled();

    final changed = SyncApplier.apply(data, {
      const SyncRecordKey('lesson', 'l2'): null,
      const SyncRecordKey('sentence', 's1'): null,
      const SyncRecordKey('discussion', 'w1:none'): null,
    });

    expect(data.lessons.map((lesson) => lesson.id), ['l1']);
    expect(data.sentences, isEmpty);
    expect(data.aiDiscussions, isEmpty);
    expect(
      changed,
      containsAll([
        SyncAppPart.lessons,
        SyncAppPart.sentences,
        SyncAppPart.aiDiscussions,
      ]),
    );
  });

  test('removing Markdown keeps the lesson', () {
    final data = _filled();

    SyncApplier.apply(data, {const SyncRecordKey('lesson_md', 'l1'): null});

    expect(data.lessons.first.markdownContent, isEmpty);
  });

  test("keeps other devices' activity and ignores its own", () {
    final data = _filled();

    final changed = SyncApplier.apply(data, {
      const SyncRecordKey('activity', 'device-b:2026-11-05'): {
        'day': '2026-11-05',
        'count': 3,
        'reviews': [],
      },
      const SyncRecordKey('activity', 'device-a:2026-11-05'): {
        'day': '2026-11-05',
        'count': 99,
        'reviews': [],
      },
    });

    expect(changed, {SyncAppPart.remoteActivity});
    expect(data.remoteActivity.keys, ['device-b:2026-11-05']);
  });

  test('drops details and progress for a word no lesson here uses', () {
    final data = _filled();
    final records = _snapshot(_filled());

    SyncApplier.apply(data, {
      const SyncRecordKey('vocab', 'unknown'):
          records[const SyncRecordKey('vocab', 'w1')]!,
    });

    expect(
      data.lessons
          .expand((lesson) => lesson.vocabularies)
          .any((vocab) => vocab.id == 'unknown'),
      isFalse,
    );
  });
}
