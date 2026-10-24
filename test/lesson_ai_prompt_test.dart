import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/lesson.dart';
import 'package:lingua_srs/models/vocab_item.dart';
import 'package:lingua_srs/services/lesson_ai_prompt.dart';

Lesson buildLesson({String markdown = '## Grammar\n\n-아요 endings'}) => Lesson(
  title: 'Unit 1::Lesson 2',
  markdownContent: markdown,
  vocabularies: [
    VocabItem(id: 'v1', targetWord: '사과', translation: 'apple', pos: 'nouns'),
  ],
);

void main() {
  group('LessonAiPrompt', () {
    test('discussion ids round-trip and do not clash with vocab ids', () {
      final id = LessonAiPrompt.discussionId('abc:1');

      expect(LessonAiPrompt.isLessonDiscussion(id), isTrue);
      expect(LessonAiPrompt.lessonIdFrom(id), 'abc:1');
      expect(LessonAiPrompt.isLessonDiscussion('vocabId:sentenceId'), isFalse);
    });

    test('prompt includes title, markdown and vocabulary', () {
      final prompt = LessonAiPrompt.systemPrompt(buildLesson());

      expect(prompt, contains('"Lesson 2"'));
      expect(prompt, contains('-아요 endings'));
      expect(prompt, contains('- 사과 — apple'));
      expect(prompt, contains('studying ko with en support'));
    });

    test('prompt works for lessons without Markdown', () {
      final prompt = LessonAiPrompt.systemPrompt(buildLesson(markdown: ''));

      expect(prompt, isNot(contains('Lesson content:')));
      expect(prompt, contains('- 사과 — apple'));
    });

    test('lessons under the limit are sent whole', () {
      final markdown = '## A\n\n${'가나다 ' * 4000}\n\n## B\n\nend';
      final prompt = LessonAiPrompt.systemPrompt(
        buildLesson(markdown: markdown),
      );

      expect(markdown.length, greaterThan(12000));
      expect(prompt, contains(markdown));
      expect(prompt, isNot(contains('omitted')));
    });

    test('long lessons are cut at a line break and list omitted headings', () {
      final markdown =
          '## Intro\n\n${'a\n' * 100}## Late pattern\n\nlast words';
      final clipped = LessonAiPrompt.clipMarkdown(markdown, maxChars: 150);

      expect(clipped, startsWith('## Intro'));
      expect(clipped, contains('is omitted here because it is too long'));
      expect(clipped, contains('Omitted sections: Late pattern'));
      expect(clipped, isNot(contains('last words')));
    });

    test('a long lesson without line breaks is still clipped', () {
      final clipped = LessonAiPrompt.clipMarkdown('a' * 500, maxChars: 100);

      expect(clipped, contains('a' * 100));
      expect(clipped, isNot(contains('a' * 101)));
      expect(clipped, contains('400 characters'));
    });

    test('suggested questions differ before and after the first message', () {
      expect(
        LessonAiPrompt.suggestedQuestions(false),
        isNot(equals(LessonAiPrompt.suggestedQuestions(true))),
      );
    });
  });
}
