import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/services/ai_question_suggestions.dart';

List<String> fixedQuestions(int count) => [
  for (var i = 1; i <= count; i++) 'Fixed question $i?',
];

List<String> aiQuestions(int count) => [
  for (var i = 1; i <= count; i++) 'AI question $i?',
];

void main() {
  List<String> first({
    required bool hasSentence,
    required bool verbOrAdjective,
  }) => AiQuestionSuggestions.wordFirstQuestions(
    language: 'ko',
    word: verbOrAdjective ? '먹다' : '사과',
    hasSentence: hasSentence,
    verbOrAdjective: verbOrAdjective,
  );

  List<String> followUps({
    required bool hasSentence,
    required bool verbOrAdjective,
  }) => AiQuestionSuggestions.wordFollowUps(
    language: 'ko',
    word: verbOrAdjective ? '먹다' : '사과',
    hasSentence: hasSentence,
    verbOrAdjective: verbOrAdjective,
  );

  const sentenceGrammar = "Break down this sentence's grammar and particles.";
  const sentenceSpeechLevel =
      'What speech level is this sentence in? Show the other levels.';

  group('AiQuestionSuggestions.wordFirstQuestions', () {
    test('a noun with a sentence is asked its register and the sentence', () {
      expect(first(hasSentence: true, verbOrAdjective: false), [
        'Is "사과" Sino-Korean (Hanja) or native Korean?',
        sentenceGrammar,
        'What register is "사과"? Is there a more polite word for it?',
        sentenceSpeechLevel,
      ]);
    });

    test('a noun without a sentence is asked its register and an example', () {
      expect(first(hasSentence: false, verbOrAdjective: false), [
        'Is "사과" Sino-Korean (Hanja) or native Korean?',
        'What register is "사과"? Is there a more polite word for it?',
        'Give me another example sentence with "사과".',
      ]);
    });

    test('a verb with a sentence is asked if it is irregular, and forms', () {
      expect(first(hasSentence: true, verbOrAdjective: true), [
        'Is "먹다" Sino-Korean (Hanja) or native Korean?',
        sentenceGrammar,
        'Is "먹다" irregular? If so, how does it change?',
        'Show me sentences with how "먹다" commonly conjugates.',
      ]);
    });

    test('a verb without a sentence is also asked its speech levels', () {
      expect(first(hasSentence: false, verbOrAdjective: true), [
        'Is "먹다" Sino-Korean (Hanja) or native Korean?',
        'Is "먹다" irregular? If so, how does it change?',
        'Show me sentences with how "먹다" commonly conjugates.',
        'Show "먹다" in the different speech levels.',
      ]);
    });

    test('only a verb or adjective is asked about forms and endings', () {
      final noun = first(hasSentence: true, verbOrAdjective: false).join('\n');

      expect(noun, isNot(contains('irregular')));
      expect(noun, isNot(contains('conjugates')));
      expect(noun, isNot(contains('speech levels')));
    });

    test('only a noun and other words are asked their register', () {
      for (final hasSentence in [true, false]) {
        final verb = first(
          hasSentence: hasSentence,
          verbOrAdjective: true,
        ).join('\n');

        expect(verb, isNot(contains('register')));
      }
    });

    test('a word without a sentence is not asked about the sentence', () {
      for (final verb in [true, false]) {
        final questions = first(hasSentence: false, verbOrAdjective: verb);

        expect(questions.join('\n'), isNot(contains('this sentence')));
      }
    });

    test('is never longer than the most that is shown at once', () {
      for (final hasSentence in [true, false]) {
        for (final verb in [true, false]) {
          final questions = first(
            hasSentence: hasSentence,
            verbOrAdjective: verb,
          );

          expect(
            questions.length <= AiQuestionSuggestions.maxQuestions,
            isTrue,
          );
        }
      }
    });
  });

  group('AiQuestionSuggestions.wordFollowUps', () {
    test('a noun with a sentence starts with the sentence speech level', () {
      expect(followUps(hasSentence: true, verbOrAdjective: false), [
        sentenceSpeechLevel,
        'How is "사과" pronounced? Which sound rules apply?',
        'What register is "사과"? Is there a more polite word for it?',
        'Quiz me on "사과" with 3 short questions.',
        'Other useful expressions in this sentence?',
        'How is "사과" different from similar words?',
        'Give me another example sentence with "사과".',
      ]);
    });

    test('a noun without a sentence has nothing about a sentence', () {
      expect(followUps(hasSentence: false, verbOrAdjective: false), [
        'How is "사과" pronounced? Which sound rules apply?',
        'What register is "사과"? Is there a more polite word for it?',
        'Quiz me on "사과" with 3 short questions.',
        'How is "사과" different from similar words?',
        'Give me another example sentence with "사과".',
      ]);
    });

    test('a verb with a sentence is asked about its forms and sounds', () {
      expect(followUps(hasSentence: true, verbOrAdjective: true), [
        sentenceSpeechLevel,
        'Is "먹다" irregular? If so, how does it change?',
        'Show me sentences with how "먹다" commonly conjugates.',
        'Which sound rules affect "먹다" when it conjugates?',
        'Show "먹다" in the different speech levels.',
        'Quiz me on "먹다" in sentences, 3 questions.',
        'Other useful expressions in this sentence?',
        'How is "먹다" different from similar words?',
        'Give me another example sentence with "먹다".',
      ]);
    });

    test('a verb without a sentence has nothing about a sentence', () {
      final questions = followUps(hasSentence: false, verbOrAdjective: true);

      expect(questions.first, startsWith('Is "먹다" irregular?'));
      expect(questions.join('\n'), isNot(contains('this sentence')));
    });

    test('a sentence has a speech level whatever the word is', () {
      for (final verb in [true, false]) {
        expect(
          followUps(hasSentence: true, verbOrAdjective: verb).first,
          sentenceSpeechLevel,
        );
        expect(
          followUps(hasSentence: false, verbOrAdjective: verb),
          isNot(contains(sentenceSpeechLevel)),
        );
      }
    });

    test('a conjugated verb has sound rules, a noun is just pronounced', () {
      final verb = followUps(hasSentence: false, verbOrAdjective: true);
      final noun = followUps(hasSentence: false, verbOrAdjective: false);

      expect(
        verb,
        contains('Which sound rules affect "먹다" when it conjugates?'),
      );
      expect(verb.join('\n'), isNot(contains('pronounced')));
      expect(
        noun,
        contains('How is "사과" pronounced? Which sound rules apply?'),
      );
    });

    test('leaves the sound rules to the AI to name', () {
      for (final hasSentence in [true, false]) {
        for (final verb in [true, false]) {
          final questions = followUps(
            hasSentence: hasSentence,
            verbOrAdjective: verb,
          ).join('\n');

          expect(questions, isNot(contains('linking')));
          expect(questions, isNot(contains('nasalization')));
        }
      }
    });

    test('has no repeated question', () {
      for (final hasSentence in [true, false]) {
        for (final verb in [true, false]) {
          final questions = followUps(
            hasSentence: hasSentence,
            verbOrAdjective: verb,
          );

          expect(questions.toSet(), hasLength(questions.length));
        }
      }
    });

    test('offers a first question again if it was skipped', () {
      for (final hasSentence in [true, false]) {
        for (final verb in [true, false]) {
          final later = followUps(
            hasSentence: hasSentence,
            verbOrAdjective: verb,
          );
          final firsts = first(hasSentence: hasSentence, verbOrAdjective: verb);

          // The origin and the grammar of the sentence are asked once, at the
          // start. All the others can be asked again if they were skipped.
          for (final question in firsts.skip(1)) {
            if (question == sentenceGrammar) continue;
            expect(later, contains(question), reason: question);
          }
        }
      }
    });
  });

  group('AiQuestionSuggestions.isVerbOrAdjective', () {
    bool check(
      String word,
      List<String> categories, {
      String language = 'ko',
    }) => AiQuestionSuggestions.isVerbOrAdjective(
      language: language,
      word: word,
      categories: categories,
    );

    test('a category that says verb or adjective settles it', () {
      for (final category in [
        'verbs',
        'Verbs',
        'adjectives',
        'passive verbs',
        'irregular verbs',
      ]) {
        // Whatever the word looks like.
        expect(check('사과', [category]), isTrue, reason: category);
        expect(check('먹다', [category]), isTrue, reason: category);
      }
    });

    test('any of the labels can say it, such as a section', () {
      expect(check('먹히다', ['general', 'verbs', 'passive verbs']), isTrue);
      expect(check('사과', ['food', 'Verbs']), isTrue);
    });

    test('a part of speech that is not a verb settles that too', () {
      for (final category in [
        'nouns',
        'Nouns',
        'adverbs',
        'verbal nouns',
        'numbers',
        'pronouns',
        'particles',
      ]) {
        expect(check('사과', [category]), isFalse, reason: category);
        // Not even a word that ends like a verb.
        expect(check('바다', [category]), isFalse, reason: category);
        expect(check('먹다', [category]), isFalse, reason: category);
      }
    });

    test('verbs win over another label when they disagree', () {
      expect(check('먹다', ['nouns', 'verbs']), isTrue);
    });

    test('a category that is no part of speech leaves it to the word', () {
      for (final category in [
        'food',
        'daily life',
        'general',
        'announcements',
      ]) {
        expect(check('먹다', [category]), isTrue, reason: category);
        expect(check('예쁘다', [category]), isTrue, reason: category);
        expect(check('열심히 하다', [category]), isTrue, reason: category);
        expect(check('사과', [category]), isFalse, reason: category);
      }
    });

    test('a word without any label is told by the word', () {
      expect(check('먹다', const []), isTrue);
      expect(check(' 먹다 ', ['', '  ']), isTrue);
      expect(check('사과', const []), isFalse);
      expect(check('', const []), isFalse);
    });

    test('a noun that ends in 다 is taken for a verb under a category', () {
      // A known mistake of going by the word, which a part of speech avoids.
      expect(check('바다', ['nature']), isTrue);
      expect(check('바다', ['nouns']), isFalse);
    });

    test('is false in a language there are no questions for', () {
      expect(check('먹다', ['verbs'], language: 'ja'), isFalse);
      expect(check('먹다', const [], language: 'ja'), isFalse);
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

    test('tells the AI a verb or adjective is in its dictionary form', () {
      expect(
        AiQuestionSuggestions.wordSubject(
          language: 'ko',
          word: '먹다',
          translation: 'to eat',
          verbOrAdjective: true,
        ),
        'the Korean verb or adjective "먹다" (to eat), '
        'given in its dictionary form',
      );
      expect(
        AiQuestionSuggestions.wordSubject(
          language: 'ko',
          word: '먹다',
          translation: '',
          verbOrAdjective: true,
        ),
        'the Korean verb or adjective "먹다", given in its dictionary form',
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

    test('asks for questions of a few words', () {
      final system = AiQuestionSuggestions.aiRequest(
        language: 'ko',
        subject: 's',
        nativeLanguage: 'en',
        question: 'q',
        answer: 'a',
        asked: const [],
      )[0].content;

      expect(system, contains('at most 8 words'));
      expect(system, contains('(about 50 characters)'));
    });

    test('tells the AI what a noun, a verb and a sentence have', () {
      final system = AiQuestionSuggestions.aiRequest(
        language: 'ko',
        subject: 's',
        nativeLanguage: 'en',
        question: 'q',
        answer: 'a',
        asked: const [],
      )[0].content;

      expect(system, contains('A noun has a register'));
      expect(system, contains('not speech levels'));
      expect(system, contains('dictionary form has none'));
      expect(system, contains('Say "this sentence" only if an example'));
    });

    test('shows the AI the style of question that is wanted', () {
      final system = AiQuestionSuggestions.aiRequest(
        language: 'ko',
        subject: 's',
        nativeLanguage: 'en',
        question: 'q',
        answer: 'a',
        asked: const [],
      )[0].content;

      expect(system, contains('not to be copied'));
      expect(system, contains('"How do I say this politely?"'));
    });

    test('lists the questions on screen after the ones asked', () {
      final messages = AiQuestionSuggestions.aiRequest(
        language: 'ko',
        subject: 's',
        nativeLanguage: 'en',
        question: 'q',
        answer: 'a',
        asked: const ['Asked?'],
        shown: const ['On screen 1?', 'On screen 2?'],
      );

      expect(userLines(messages).skip(3), [
        'Already asked:',
        '- Asked?',
        'Already on screen:',
        '- On screen 1?',
        '- On screen 2?',
      ]);
      expect(messages[0].content, contains('or is already on screen'));
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
      expect(messages[1].content, isNot(contains('Already on screen')));
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

    test('keeps a question of 80 characters and drops one of 81', () {
      expect(
        AiQuestionSuggestions.parseAiQuestions(
          '{"questions": ["${'a' * 81}", "${'b' * 80}"]}',
        ),
        ['b' * 80],
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
