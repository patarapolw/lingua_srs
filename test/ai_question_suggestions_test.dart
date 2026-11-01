import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/services/ai_question_suggestions.dart';

List<String> fixedQuestions(int count) => [
  for (var i = 1; i <= count; i++) 'Fixed question $i?',
];

List<String> aiQuestions(int count) => [
  for (var i = 1; i <= count; i++) 'AI question $i?',
];

void main() {
  group('AiQuestionSuggestions.wordFirstQuestions', () {
    test('a noun with a sentence gets origin, grammar, usage, example', () {
      final questions = AiQuestionSuggestions.wordFirstQuestions(
        language: 'ko',
        word: '사과',
        hasSentence: true,
        verbOrAdjective: false,
      );

      expect(questions, [
        'Is "사과" Sino-Korean (Hanja) or native Korean? '
            'Explain where it comes from.',
        'How does this sentence work? Break down the grammar and particles.',
        'How is "사과" used in everyday speech? '
            'What formality and politeness (speech levels) does it suit?',
        'Give me another example sentence with "사과".',
      ]);
    });

    test('a verb with a sentence swaps the extra example for conjugation', () {
      final questions = AiQuestionSuggestions.wordFirstQuestions(
        language: 'ko',
        word: '먹다',
        hasSentence: true,
        verbOrAdjective: true,
      );

      expect(questions, hasLength(AiQuestionSuggestions.maxQuestions));
      expect(
        questions[3],
        'Show me sentences with how "먹다" commonly conjugates.',
      );
      expect(questions.join('\n'), isNot(contains('another example')));
    });

    test('a word without a sentence gets no question about the sentence', () {
      final noun = AiQuestionSuggestions.wordFirstQuestions(
        language: 'ko',
        word: '사과',
        hasSentence: false,
        verbOrAdjective: false,
      );
      final verb = AiQuestionSuggestions.wordFirstQuestions(
        language: 'ko',
        word: '먹다',
        hasSentence: false,
        verbOrAdjective: true,
      );

      expect(noun, hasLength(3));
      expect(noun.join('\n'), isNot(contains('this sentence')));
      expect(verb, hasLength(4));
      expect(verb.join('\n'), isNot(contains('this sentence')));
      expect(verb.join('\n'), contains('commonly conjugates'));
    });

    test('asks about speech levels as formality and politeness', () {
      final questions = AiQuestionSuggestions.wordFirstQuestions(
        language: 'ko',
        word: '사과',
        hasSentence: false,
        verbOrAdjective: false,
      );

      expect(questions.join('\n'), contains('formality and politeness'));
    });
  });

  group('AiQuestionSuggestions.wordFollowUps', () {
    test('with a sentence, starts with its speech level', () {
      final questions = AiQuestionSuggestions.wordFollowUps(
        language: 'ko',
        word: '사과',
        hasSentence: true,
        verbOrAdjective: false,
      );

      expect(questions[0], startsWith('What speech level is this sentence in'));
      expect(questions[0], contains('formality and politeness'));
      expect(questions.join('\n'), contains('other useful expressions'));
    });

    test('asks how the word is pronounced, with or without a sentence', () {
      for (final hasSentence in [true, false]) {
        final questions = AiQuestionSuggestions.wordFollowUps(
          language: 'ko',
          word: '사과',
          hasSentence: hasSentence,
          verbOrAdjective: false,
        );

        expect(
          questions,
          contains(
            'How is "사과" pronounced? Which sound rules affect it in speech?',
          ),
        );
        // The AI works out which sound rules are meant.
        expect(questions.join('\n'), isNot(contains('linking')));
        expect(questions.join('\n'), isNot(contains('nasalization')));
      }
    });

    test('pronunciation comes after the speech level, before the quiz', () {
      final withSentence = AiQuestionSuggestions.wordFollowUps(
        language: 'ko',
        word: '사과',
        hasSentence: true,
        verbOrAdjective: false,
      );
      final withoutSentence = AiQuestionSuggestions.wordFollowUps(
        language: 'ko',
        word: '사과',
        hasSentence: false,
        verbOrAdjective: false,
      );

      expect(withSentence[0], startsWith('What speech level'));
      expect(withSentence[1], startsWith('How is "사과" pronounced?'));
      expect(withSentence[2], startsWith('Quiz me on "사과"'));
      expect(withoutSentence[0], startsWith('How is "사과" pronounced?'));
      expect(withoutSentence[1], startsWith('Quiz me on "사과"'));
    });

    test('never asks how the sentence is pronounced', () {
      final questions = AiQuestionSuggestions.wordFollowUps(
        language: 'ko',
        word: '사과',
        hasSentence: true,
        verbOrAdjective: true,
      );

      expect(
        questions.join('\n'),
        isNot(contains('How is this sentence pronounced')),
      );
    });

    test('without a sentence, asks nothing about the sentence', () {
      final questions = AiQuestionSuggestions.wordFollowUps(
        language: 'ko',
        word: '사과',
        hasSentence: false,
        verbOrAdjective: true,
      );

      expect(questions.join('\n'), isNot(contains('this sentence')));
    });

    test('offers conjugation for a verb or adjective only', () {
      final verb = AiQuestionSuggestions.wordFollowUps(
        language: 'ko',
        word: '먹다',
        hasSentence: false,
        verbOrAdjective: true,
      );
      final noun = AiQuestionSuggestions.wordFollowUps(
        language: 'ko',
        word: '사과',
        hasSentence: false,
        verbOrAdjective: false,
      );

      expect(
        verb,
        contains('Show me sentences with how "먹다" commonly conjugates.'),
      );
      expect(noun.join('\n'), isNot(contains('conjugates')));
    });

    test('has no repeated question', () {
      for (final hasSentence in [true, false]) {
        for (final verb in [true, false]) {
          final questions = AiQuestionSuggestions.wordFollowUps(
            language: 'ko',
            word: '먹다',
            hasSentence: hasSentence,
            verbOrAdjective: verb,
          );

          expect(questions.toSet(), hasLength(questions.length));
        }
      }
    });
  });

  group('AiQuestionSuggestions language check', () {
    List<String> first(String language) =>
        AiQuestionSuggestions.wordFirstQuestions(
          language: language,
          word: '사과',
          hasSentence: true,
          verbOrAdjective: true,
        );

    test('supports Korean by code, region and name', () {
      for (final language in ['ko', 'KO', ' ko ', 'ko-KR', 'ko_KR', 'Korean']) {
        expect(
          AiQuestionSuggestions.supports(language),
          isTrue,
          reason: language,
        );
        expect(first(language), isNotEmpty, reason: language);
      }
    });

    test('does not support another language yet', () {
      for (final language in ['ja', 'es', 'fr', 'zh-CN', '', 'kor']) {
        expect(
          AiQuestionSuggestions.supports(language),
          isFalse,
          reason: language,
        );
        expect(first(language), isEmpty, reason: language);
        expect(
          AiQuestionSuggestions.wordFollowUps(
            language: language,
            word: '사과',
            hasSentence: true,
            verbOrAdjective: true,
          ),
          isEmpty,
          reason: language,
        );
      }
    });

    test('names the subject in the language', () {
      expect(
        AiQuestionSuggestions.wordSubject(
          language: 'ko',
          word: '사과',
          translation: 'apple',
        ),
        'the Korean word "사과" (apple)',
      );
      expect(
        AiQuestionSuggestions.wordSubject(
          language: 'ko',
          word: '사과',
          translation: ' ',
        ),
        'the Korean word "사과"',
      );
      expect(
        AiQuestionSuggestions.lessonSubject(language: 'ko-KR', title: 'Food'),
        'the Korean lesson "Food"',
      );
    });

    test('will not build a request or a subject for another language', () {
      expect(
        () => AiQuestionSuggestions.aiRequest(
          language: 'ja',
          subject: 's',
          nativeLanguage: 'en',
          question: 'q',
          answer: 'a',
          asked: const [],
        ),
        throwsArgumentError,
      );
      expect(
        () => AiQuestionSuggestions.wordSubject(
          language: 'ja',
          word: 'りんご',
          translation: 'apple',
        ),
        throwsArgumentError,
      );
      expect(
        () => AiQuestionSuggestions.lessonSubject(language: 'ja', title: 'x'),
        throwsArgumentError,
      );
    });
  });

  group('AiQuestionSuggestions.followUps', () {
    test('shows 3 fixed questions when the AI has none', () {
      final questions = AiQuestionSuggestions.followUps(
        hardcoded: fixedQuestions(6),
        asked: const [],
      );

      expect(questions, fixedQuestions(3));
    });

    test('one AI question goes after 3 fixed ones', () {
      final questions = AiQuestionSuggestions.followUps(
        hardcoded: fixedQuestions(6),
        asked: const [],
        ai: aiQuestions(1),
      );

      expect(questions, [...fixedQuestions(3), ...aiQuestions(1)]);
    });

    test('two AI questions go after 2 fixed ones', () {
      final questions = AiQuestionSuggestions.followUps(
        hardcoded: fixedQuestions(6),
        asked: const [],
        ai: aiQuestions(2),
      );

      expect(questions, [...fixedQuestions(2), ...aiQuestions(2)]);
    });

    test('uses at most 2 of the AI questions', () {
      final questions = AiQuestionSuggestions.followUps(
        hardcoded: fixedQuestions(6),
        asked: const [],
        ai: aiQuestions(5),
      );

      expect(questions, [...fixedQuestions(2), ...aiQuestions(2)]);
    });

    test('never shows more than 4 whatever it is given', () {
      for (var fixed = 0; fixed <= 8; fixed++) {
        for (var ai = 0; ai <= 6; ai++) {
          final questions = AiQuestionSuggestions.followUps(
            hardcoded: fixedQuestions(fixed),
            asked: const [],
            ai: aiQuestions(ai),
          );

          expect(
            questions.length <= AiQuestionSuggestions.maxQuestions,
            isTrue,
            reason: '$fixed fixed, $ai AI gave ${questions.length}',
          );
        }
      }
    });

    test('shows what there is when there is less than the room', () {
      expect(
        AiQuestionSuggestions.followUps(
          hardcoded: fixedQuestions(1),
          asked: const [],
          ai: aiQuestions(2),
        ),
        [...fixedQuestions(1), ...aiQuestions(2)],
      );
      expect(
        AiQuestionSuggestions.followUps(
          hardcoded: const [],
          asked: const [],
          ai: aiQuestions(1),
        ),
        aiQuestions(1),
      );
      expect(
        AiQuestionSuggestions.followUps(hardcoded: const [], asked: const []),
        isEmpty,
      );
    });

    test('skips fixed questions already asked and fills up with the next', () {
      final questions = AiQuestionSuggestions.followUps(
        hardcoded: fixedQuestions(5),
        asked: ['Fixed question 1?', 'Fixed question 3?'],
      );

      expect(questions, [
        'Fixed question 2?',
        'Fixed question 4?',
        'Fixed question 5?',
      ]);
    });

    test(
      'a question asked in other letters or punctuation counts as asked',
      () {
        final questions = AiQuestionSuggestions.followUps(
          hardcoded: fixedQuestions(4),
          asked: ['  fixed QUESTION 1 ', 'Fixed question 2!!'],
        );

        expect(questions, ['Fixed question 3?', 'Fixed question 4?']);
      },
    );

    test('drops AI questions that were asked or are already fixed', () {
      final questions = AiQuestionSuggestions.followUps(
        hardcoded: fixedQuestions(3),
        asked: ['AI question 1?'],
        ai: ['AI question 1?', 'fixed question 2', 'AI question 3?'],
      );

      expect(questions, [...fixedQuestions(3), 'AI question 3?']);
    });

    test('drops repeated and blank AI questions', () {
      final questions = AiQuestionSuggestions.followUps(
        hardcoded: fixedQuestions(3),
        asked: const [],
        ai: ['  ', 'AI question 1?', 'ai question 1', '?!', 'AI question 2?'],
      );

      expect(questions, [...fixedQuestions(2), ...aiQuestions(2)]);
    });

    test('shows a fixed question once even if it is listed twice', () {
      final questions = AiQuestionSuggestions.followUps(
        hardcoded: ['Same?', 'same', 'Other?'],
        asked: const [],
      );

      expect(questions, ['Same?', 'Other?']);
    });

    test('a Korean question is told apart by its letters', () {
      final questions = AiQuestionSuggestions.followUps(
        hardcoded: ['사과는 뭐예요?', '배는 뭐예요?'],
        asked: ['사과는 뭐예요?'],
      );

      expect(questions, ['배는 뭐예요?']);
    });
  });

  group('AiQuestionSuggestions.aiRequest', () {
    List<String> userLines(List<dynamic> messages) =>
        (messages[1].content as String).split('\n');

    test('is a system message and a user message', () {
      final messages = AiQuestionSuggestions.aiRequest(
        language: 'ko',
        subject: 'the Korean word "사과" (apple)',
        nativeLanguage: 'en',
        question: 'How is it used?',
        answer: 'It is a noun.',
        asked: const ['How is it used?'],
      );

      expect(messages.map((m) => m.role), ['system', 'user']);
      expect(messages[0].content, contains('JSON only'));
      expect(messages[0].content, contains('"questions"'));
      expect(messages[0].content, contains('(en)'));
      expect(messages[0].content, contains('learner of Korean'));
      expect(messages[0].content, contains('practical'));
    });

    test('tells the AI the subject, the last exchange and what was asked', () {
      final messages = AiQuestionSuggestions.aiRequest(
        language: 'ko',
        subject: 'the Korean word "사과" (apple)',
        nativeLanguage: 'en',
        question: 'How is it used?',
        answer: 'It is a noun.',
        asked: const ['Where is it from?', 'How is it used?'],
      );

      expect(userLines(messages), [
        'Subject: the Korean word "사과" (apple)',
        'Last question: How is it used?',
        'Last answer (may be cut off): It is a noun.',
        'Already asked:',
        '- Where is it from?',
        '- How is it used?',
      ]);
    });

    test('includes the example sentence on the card', () {
      final messages = AiQuestionSuggestions.aiRequest(
        language: 'ko',
        subject: 's',
        nativeLanguage: 'en',
        question: 'q',
        answer: 'a',
        asked: const [],
        sentenceTarget: ' 사과를 먹어요. ',
        sentenceTranslation: 'I eat an apple.',
      );

      expect(
        userLines(messages),
        contains(
          'Example sentence on the card: "사과를 먹어요." '
          '(translation: "I eat an apple.")',
        ),
      );
    });

    test('leaves out a blank sentence and an empty asked list', () {
      final messages = AiQuestionSuggestions.aiRequest(
        language: 'ko',
        subject: 's',
        nativeLanguage: 'en',
        question: 'q',
        answer: 'a',
        asked: const [],
        sentenceTarget: '  ',
        sentenceTranslation: 'ignored',
      );

      expect(messages[1].content, isNot(contains('Example sentence')));
      expect(messages[1].content, isNot(contains('Already asked')));
    });

    test('cuts a long answer short', () {
      final messages = AiQuestionSuggestions.aiRequest(
        language: 'ko',
        subject: 's',
        nativeLanguage: 'en',
        question: 'q',
        answer: 'a' * 2000,
        asked: const [],
      );

      expect(messages[1].content, contains('${'a' * 1500}…'));
      expect(messages[1].content, isNot(contains('a' * 1501)));
    });

    test('lists only the 12 latest questions asked', () {
      final messages = AiQuestionSuggestions.aiRequest(
        language: 'ko',
        subject: 's',
        nativeLanguage: 'en',
        question: 'q',
        answer: 'a',
        asked: [for (var i = 0; i < 20; i++) 'question $i'],
      );

      final lines = userLines(messages);
      expect(lines, contains('- question 8'));
      expect(lines, contains('- question 19'));
      expect(lines, isNot(contains('- question 7')));
    });
  });

  group('AiQuestionSuggestions.parseAiQuestions', () {
    test('reads the questions of a JSON object', () {
      expect(
        AiQuestionSuggestions.parseAiQuestions(
          '{"questions": ["What is 사과?", " Is it polite? "]}',
        ),
        ['What is 사과?', 'Is it polite?'],
      );
    });

    test('reads a bare list and a fenced reply', () {
      expect(AiQuestionSuggestions.parseAiQuestions('["One?", "Two?"]'), [
        'One?',
        'Two?',
      ]);
      expect(
        AiQuestionSuggestions.parseAiQuestions(
          '```json\n{"questions": ["One?"]}\n```',
        ),
        ['One?'],
      );
    });

    test('drops blanks, non-text, repeats and questions that are too long', () {
      final tooLong = 'x' * (AiQuestionSuggestions.maxAiQuestionLength + 1);
      final justRight = 'y' * AiQuestionSuggestions.maxAiQuestionLength;

      expect(
        AiQuestionSuggestions.parseAiQuestions(
          '{"questions": ["", "  ", 3, null, "One?", "one", "$tooLong", '
          '"$justRight"]}',
        ),
        ['One?', justRight],
      );
    });

    test('gives none for a reply that is not what was asked for', () {
      for (final reply in [
        null,
        '',
        'Sure! Here are some questions.',
        '{"questions": ["unfinished"',
        '{"questions": "One?"}',
        '{"other": ["One?"]}',
        '42',
        'null',
      ]) {
        expect(
          AiQuestionSuggestions.parseAiQuestions(reply),
          isEmpty,
          reason: 'reply: $reply',
        );
      }
    });
  });
}
