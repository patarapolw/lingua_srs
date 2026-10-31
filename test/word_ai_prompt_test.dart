import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/ai_discussion_message.dart';
import 'package:lingua_srs/services/word_ai_prompt.dart';

String buildPrompt({String? sentence, String? translation}) =>
    WordAiPrompt.systemPrompt(
      targetLanguage: 'ko',
      nativeLanguage: 'en',
      targetWord: '사과',
      translation: 'apple',
      sentenceTarget: sentence,
      sentenceTranslation: translation,
    );

void main() {
  group('WordAiPrompt.systemPrompt', () {
    test('names the word, its meaning and the example sentence', () {
      final prompt = buildPrompt(
        sentence: '사과를 먹어요.',
        translation: 'I eat an apple.',
      );

      expect(prompt, contains('studying ko with en support'));
      expect(prompt, contains('"사과" means "apple"'));
      expect(
        prompt,
        contains(
          'Example sentence: "사과를 먹어요." (translation: "I eat an apple.")',
        ),
      );
    });

    test('tells the AI the newest question carries the current sentence', () {
      final prompt = buildPrompt(sentence: '사과를 먹어요.');

      expect(prompt, contains('"${WordAiPrompt.contextLabel}" note'));
      expect(prompt, contains('answer about it, not about an earlier one'));
    });

    test('leaves out every sentence line when there is no sentence', () {
      for (final sentence in [null, '', '   ']) {
        final prompt = buildPrompt(sentence: sentence);

        expect(prompt, isNot(contains('Example sentence')));
        expect(prompt, isNot(contains(WordAiPrompt.contextLabel)));
        expect(prompt, isNot(contains('This sentence')));
        expect(prompt, contains('"사과" means "apple"'));
      }
    });

    test('leaves out a blank sentence translation', () {
      final prompt = buildPrompt(sentence: '사과를 먹어요.', translation: '  ');

      expect(prompt, contains('Example sentence: "사과를 먹어요."'));
      expect(prompt, isNot(contains('translation:')));
    });
  });

  group('WordAiPrompt.withCurrentSentence', () {
    final createdAt = DateTime.utc(2026, 10, 31, 9);
    final history = [
      AiDiscussionMessage(
        role: 'user',
        content: 'How does this sentence work?',
      ),
      AiDiscussionMessage(role: 'assistant', content: 'It uses the object -를.'),
      AiDiscussionMessage(
        role: 'user',
        content: 'And this sentence?',
        createdAt: createdAt,
      ),
    ];

    test('puts the current sentence in front of the newest question', () {
      final result = WordAiPrompt.withCurrentSentence(
        history,
        sentenceTarget: '사과가 맛있어요.',
        sentenceTranslation: 'The apple is tasty.',
      );

      expect(
        result.last.content,
        '[Current example sentence: "사과가 맛있어요." '
        '(translation: "The apple is tasty.")]\n\nAnd this sentence?',
      );
      expect(result.last.role, 'user');
      expect(result.last.createdAt, createdAt);
    });

    test('keeps earlier messages as they were asked', () {
      final result = WordAiPrompt.withCurrentSentence(
        history,
        sentenceTarget: '사과가 맛있어요.',
      );

      expect(result, hasLength(history.length));
      expect(result[0].content, 'How does this sentence work?');
      expect(result[1].content, 'It uses the object -를.');
      expect(result.map((m) => m.role), ['user', 'assistant', 'user']);
    });

    test('does not change the saved conversation', () {
      WordAiPrompt.withCurrentSentence(history, sentenceTarget: '사과가 맛있어요.');

      expect(history.last.content, 'And this sentence?');
    });

    test('a new sentence replaces the old one on the newest question', () {
      final first = WordAiPrompt.withCurrentSentence([
        history.first,
      ], sentenceTarget: '사과를 먹어요.');
      expect(first.single.content, contains('사과를 먹어요.'));

      // The saved question carries no note, so a later sentence is not mixed
      // up with the one the first question was asked about.
      final second = WordAiPrompt.withCurrentSentence(
        history,
        sentenceTarget: '사과가 맛있어요.',
      );
      expect(second.last.content, contains('사과가 맛있어요.'));
      expect(second.last.content, isNot(contains('사과를 먹어요.')));
      expect(second.first.content, isNot(contains('Current example sentence')));
    });

    test('a note goes on the last user message, not a trailing answer', () {
      final result = WordAiPrompt.withCurrentSentence([
        ...history,
        AiDiscussionMessage(role: 'assistant', content: 'It is tasty.'),
      ], sentenceTarget: '사과가 맛있어요.');

      expect(result.last.content, 'It is tasty.');
      expect(result[2].content, startsWith('[Current example sentence:'));
    });

    test('leaves the conversation alone without a sentence', () {
      for (final sentence in [null, '', '   ']) {
        final result = WordAiPrompt.withCurrentSentence(
          history,
          sentenceTarget: sentence,
        );

        expect(result.map((m) => m.content), history.map((m) => m.content));
      }
    });

    test('leaves a conversation without a question alone', () {
      final answers = [AiDiscussionMessage(role: 'assistant', content: 'Hi')];

      expect(
        WordAiPrompt.withCurrentSentence(answers, sentenceTarget: '사과'),
        answers,
      );
      expect(
        WordAiPrompt.withCurrentSentence(const [], sentenceTarget: '사과'),
        isEmpty,
      );
    });
  });
}
