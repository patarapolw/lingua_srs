import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/typed_question.dart';
import 'package:lingua_srs/services/ai_question_suggestions.dart';
import 'package:lingua_srs/services/sync_apply.dart';
import 'package:lingua_srs/services/sync_records.dart';
import 'package:lingua_srs/services/typed_questions.dart';

const _word = TypedQuestionScope.word;
const _lesson = TypedQuestionScope.lesson;

String? _template(
  String question, {
  String subject = '먹다',
  String language = 'ko',
  TypedQuestionScope scope = _word,
}) => TypedQuestions.template(
  question: question,
  subject: subject,
  language: language,
  scope: scope,
);

Map<String, TypedQuestion> _record(
  Map<String, TypedQuestion> kept,
  String question, {
  String subject = '먹다',
  String language = 'ko',
  TypedQuestionScope scope = _word,
  required DateTime now,
}) => TypedQuestions.recordUse(
  kept,
  question: question,
  subject: subject,
  language: language,
  scope: scope,
  now: now,
);

TypedQuestion _question(
  String template, {
  int uses = 1,
  required DateTime lastUsed,
  String language = 'ko',
  TypedQuestionScope scope = _word,
}) => TypedQuestion(
  language: language,
  scope: scope,
  template: template,
  uses: uses,
  lastUsed: lastUsed,
);

Map<String, TypedQuestion> _keep(Iterable<TypedQuestion> questions) => {
  for (final question in questions) TypedQuestions.id(question): question,
};

void main() {
  group('TypedQuestions.template', () {
    test('puts a placeholder where the word was', () {
      expect(
        _template('How is 먹다 used in polite speech?'),
        'How is {word} used in polite speech?',
      );
      expect(_template('Is "먹다" irregular?'), 'Is "{word}" irregular?');
    });

    test('keeps a question that does not name the word', () {
      expect(
        _template('Is this formal or casual?'),
        'Is this formal or casual?',
      );
    });

    test('puts a placeholder where the lesson title was, in any case', () {
      expect(
        _template(
          'summarize lesson 3 again',
          subject: 'Lesson 3',
          scope: _lesson,
        ),
        'summarize {lesson} again',
      );
    });

    test('keeps out a question that names other Korean text', () {
      expect(_template('What does 맛있게 mean here?'), isNull);
      expect(_template('How is 먹다 different from 드시다?'), isNull);
    });

    test('keeps out a question that quotes something', () {
      expect(_template('What does "eat well" mean here?'), isNull);
      expect(_template('Is “to eat” the only meaning?'), isNull);
    });

    test('keeps out a question that is only the word', () {
      expect(_template('먹다'), isNull);
      expect(_template('"먹다"?'), isNull);
      expect(_template('   '), isNull);
    });

    test('keeps out long questions and ones on several lines', () {
      expect(_template('Why ${'so ' * 60}?'), isNull);
      expect(_template('Is it formal?\nOr casual?'), isNull);
    });

    test('names no other text for a language without questions', () {
      expect(
        _template('Is it 丁寧?', subject: '食べる', language: 'ja'),
        'Is it 丁寧?',
      );
    });
  });

  group('TypedQuestions.recordUse', () {
    final first = DateTime.utc(2026, 11, 1);
    final second = DateTime.utc(2026, 11, 2);

    test('counts the same question about another word once more', () {
      var kept = _record(const {}, 'How is 먹다 used?', now: first);
      kept = _record(kept, 'how is 가다 used', subject: '가다', now: second);

      final question = kept.values.single;
      expect(question.uses, 2);
      expect(question.template, 'how is {word} used');
      expect(question.lastUsed, second);
      expect(question.forSubject('자다'), 'how is 자다 used');
    });

    test('keeps the language as a code', () {
      final kept = _record(
        const {},
        'Is this formal?',
        language: 'Korean',
        now: first,
      );
      expect(kept.values.single.language, 'ko');
    });

    test('keeps word and lesson questions apart', () {
      var kept = _record(const {}, 'Is this formal?', now: first);
      kept = _record(
        kept,
        'Is this formal?',
        subject: 'Lesson 1',
        scope: _lesson,
        now: second,
      );
      expect(kept, hasLength(2));
    });

    test('returns the same map for a question that is not kept', () {
      final kept = _record(const {}, 'Is this formal?', now: first);
      expect(
        identical(_record(kept, 'What does 맛있게 mean?', now: second), kept),
        isTrue,
      );
    });

    test('drops the questions used longest ago past the most kept', () {
      var kept = <String, TypedQuestion>{};
      for (var i = 0; i <= TypedQuestions.maxKept; i++) {
        kept = _record(
          kept,
          'Question number $i?',
          now: first.add(Duration(minutes: i)),
        );
      }
      expect(kept, hasLength(TypedQuestions.maxKept));
      expect(
        kept.values.map((question) => question.template),
        isNot(contains('Question number 0?')),
      );
    });
  });

  group('TypedQuestions.offer', () {
    final old = DateTime.utc(2026, 10, 1);
    final middle = DateTime.utc(2026, 10, 15);
    final latest = DateTime.utc(2026, 11, 1);
    final kept = _keep([
      _question('Is {word} formal?', uses: 5, lastUsed: old),
      _question('Show {word} in a dialogue.', lastUsed: latest),
      _question('Quiz me on {word}.', uses: 3, lastUsed: middle),
      _question('Is {word} formal?', lastUsed: latest, language: 'ja'),
      _question('Summarize {word}.', lastUsed: latest, scope: _lesson),
    ]);

    List<String> offer({
      Iterable<String> leaveOut = const [],
      int max = AiQuestionSuggestions.maxTypedQuestions,
    }) => [
      for (final offer in TypedQuestions.offer(
        kept,
        language: 'ko-KR',
        scope: _word,
        subject: '먹다',
        leaveOut: leaveOut,
        max: max,
      ))
        offer.question,
    ];

    test('offers the most used, then the most recent', () {
      expect(offer(), ['Is 먹다 formal?', 'Show 먹다 in a dialogue.']);
      expect(offer(max: 5), [
        'Is 먹다 formal?',
        'Show 먹다 in a dialogue.',
        'Quiz me on 먹다.',
      ]);
    });

    test('leaves out questions asked already', () {
      expect(offer(leaveOut: ['is 먹다 formal']), [
        'Quiz me on 먹다.',
        'Show 먹다 in a dialogue.',
      ]);
    });

    test('gives the id each question is kept under', () {
      final offered = TypedQuestions.offer(
        kept,
        language: 'ko',
        scope: _word,
        subject: '먹다',
      );
      for (final offer in offered) {
        expect(kept, contains(offer.id));
      }
    });
  });

  group('TypedQuestion', () {
    test('reads back what it writes', () {
      final question = _question(
        'Is {word} formal?',
        uses: 3,
        lastUsed: DateTime.utc(2026, 11, 1, 12),
      );
      final read = TypedQuestion.fromJson(question.toJson());
      expect(read.toJson(), question.toJson());
    });

    test('rejects a question it cannot read', () {
      expect(
        () => TypedQuestion.fromJson({'template': 'Is it formal?'}),
        throwsFormatException,
      );
      expect(
        () => TypedQuestion.fromJson({
          ..._question('Is it formal?', lastUsed: DateTime.utc(2026)).toJson(),
          'scope': 'sentence',
        }),
        throwsFormatException,
      );
    });
  });

  group('AiQuestionSuggestions with typed questions', () {
    const fixed = ['Fixed 1?', 'Fixed 2?', 'Fixed 3?', 'Fixed 4?'];

    test('shows typed questions first in a new chat', () {
      expect(
        AiQuestionSuggestions.firstQuestions(
          fixed: fixed,
          typed: ['Mine 1?', 'Mine 2?', 'Mine 3?'],
        ),
        ['Mine 1?', 'Mine 2?', 'Fixed 1?', 'Fixed 2?'],
      );
      expect(AiQuestionSuggestions.firstQuestions(fixed: fixed), fixed);
    });

    test('shows typed questions first after an answer', () {
      expect(
        AiQuestionSuggestions.followUps(
          hardcoded: fixed,
          asked: const [],
          typed: ['Mine 1?', 'Mine 2?', 'Mine 3?'],
        ),
        ['Mine 1?', 'Mine 2?', 'Fixed 1?', 'Fixed 2?'],
      );
    });

    test('keeps the AI questions last, in place of fixed ones', () {
      expect(
        AiQuestionSuggestions.followUps(
          hardcoded: fixed,
          asked: const [],
          typed: ['Mine 1?'],
          ai: ['AI 1?', 'AI 2?'],
        ),
        ['Mine 1?', 'Fixed 1?', 'AI 1?', 'AI 2?'],
      );
    });

    test('shows a question once, and none that was asked', () {
      expect(
        AiQuestionSuggestions.followUps(
          hardcoded: fixed,
          asked: ['mine 1'],
          typed: ['Mine 1?', 'fixed 2'],
          ai: ['Fixed 2?'],
        ),
        ['fixed 2', 'Fixed 1?', 'Fixed 3?', 'Fixed 4?'],
      );
    });
  });

  group('typed questions in sync', () {
    final question = _question(
      'Is {word} formal?',
      uses: 2,
      lastUsed: DateTime.utc(2026, 11, 1),
    );
    final id = TypedQuestions.id(question);
    final key = SyncRecordKey(SyncKinds.question, id);

    test('are one record each', () {
      final records = SyncSnapshot.build(
        lessons: const [],
        sentences: const [],
        mergeHistory: const [],
        aiDiscussions: const {},
        typedQuestions: {id: question},
        lessonOrder: const {},
        settings: const SyncSettings(
          maxReviews24h: 100,
          maxNewCards24h: 10,
          autoplayAudio: true,
          pronunciationOptions: {},
        ),
        dailyReviewCounts: const {},
        reviewTimestamps: const [],
        deviceId: 'device-a',
      );
      expect(records[key], question.toJson());
      expect(
        SyncSnapshot.knownChangeTime(key, question.toJson()),
        DateTime.utc(2026, 11, 1).millisecondsSinceEpoch,
      );
    });

    SyncAppData data(Map<String, TypedQuestion> typedQuestions) => SyncAppData(
      deviceId: 'device-a',
      lessons: [],
      sentences: [],
      mergeHistory: [],
      aiDiscussions: {},
      typedQuestions: typedQuestions,
      lessonOrder: {},
      maxReviews24h: 100,
      maxNewCards24h: 10,
      autoplayAudio: true,
      pronunciationOptions: {},
      remoteActivity: {},
    );

    test('are added and removed when pulled', () {
      final app = data({});
      expect(SyncApplier.apply(app, {key: question.toJson()}), {
        SyncAppPart.typedQuestions,
      });
      expect(app.typedQuestions[id]?.toJson(), question.toJson());

      expect(SyncApplier.apply(app, {key: null}), {SyncAppPart.typedQuestions});
      expect(app.typedQuestions, isEmpty);
    });
  });
}
