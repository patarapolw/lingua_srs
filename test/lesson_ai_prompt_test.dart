import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/lesson.dart';
import 'package:lingua_srs/models/vocab_item.dart';
import 'package:lingua_srs/services/lesson_ai_prompt.dart';
import 'package:lingua_srs/services/yaml_parser_service.dart';

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

    test('both question lists offer vocabulary as YAML', () {
      expect(
        LessonAiPrompt.suggestedQuestions(false),
        contains(LessonAiPrompt.vocabularyQuestion),
      );
      expect(
        LessonAiPrompt.suggestedQuestions(true),
        contains(LessonAiPrompt.vocabularyQuestion),
      );
    });

    test('prompt says how to write vocabulary YAML in its languages', () {
      final prompt = LessonAiPrompt.systemPrompt(buildLesson());

      expect(prompt, contains('```yaml'));
      expect(prompt, contains('vocabulary:\n  nouns:\n    - ko: "..."'));
      expect(prompt, contains('      en: "..."'));
      expect(prompt, contains('not in its vocabulary yet'));
      // The translation is asked to emphasize the word too, where it can.
      expect(prompt, contains('          en: "... **...** ..."'));
      expect(prompt, contains('In the en translation, also wrap in **bold**'));
      expect(prompt, contains('leave the translation without bold'));
    });

    test('finds the vocabulary YAML in an answer', () {
      const answer = '''Here are some words:

```yaml
vocabulary:
  nouns:
    - ko: "배"
      en: "pear"
      examples:
        - ko: "**배**가 달아요."
          en: "The **pear** is sweet."
  verbs:
    - ko: "사다"
      en: "to buy"
```

Edit them as you like.''';
      final yaml = LessonAiPrompt.vocabularyYaml(answer)!;

      expect(yaml, startsWith('vocabulary:\n  nouns:'));
      expect(yaml, endsWith('en: "to buy"\n'));
      expect(yaml, isNot(contains('```')));
      final parsed = YamlParserService.parseLessonYaml(yaml);
      expect(parsed.lesson.vocabularies.map((v) => v.targetWord), ['배', '사다']);
      // The translation's emphasis is kept as the word's own.
      expect(
        parsed
            .lesson
            .vocabularies
            .first
            .sentenceEmphasis
            .values
            .single
            .translation,
        'The **pear** is sweet.',
      );
    });

    test('takes an unlabelled block too, and skips other blocks', () {
      const answer = '''```json
{"vocabulary": []}
```

```
vocabulary:
  nouns:
    - ko: "배"
      en: "pear"
```''';

      expect(
        LessonAiPrompt.vocabularyYaml(answer),
        'vocabulary:\n  nouns:\n    - ko: "배"\n      en: "pear"\n',
      );
    });

    test('an answer without vocabulary YAML has none', () {
      expect(LessonAiPrompt.vocabularyYaml('배 means pear.'), isNull);
      expect(
        LessonAiPrompt.vocabularyYaml('```yaml\nwords:\n  - 배\n```'),
        isNull,
      );
      expect(
        LessonAiPrompt.vocabularyYaml('```dart\nvocabulary: 1\n```'),
        isNull,
      );
    });

    test('suggested questions differ before and after the first message', () {
      expect(
        LessonAiPrompt.suggestedQuestions(false),
        isNot(equals(LessonAiPrompt.suggestedQuestions(true))),
      );
    });
  });
}
