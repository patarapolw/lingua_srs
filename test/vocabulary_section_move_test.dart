import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/lesson.dart';
import 'package:lingua_srs/services/vocabulary_section_move.dart';
import 'package:lingua_srs/services/yaml_parser_service.dart';

void main() {
  group('YamlParseResult.vocabularySection', () {
    test('holds the section import leaves out', () {
      final result = YamlParserService.parseLessonYaml('''---
vocabulary:
---

# Lesson

Intro.

## Vocabulary

- 학교 — school
<!-- /Vocabulary -->

Footer.
''');
      expect(result.vocabularySection, '- 학교 — school');
      expect(result.lesson.markdownContent, isNot(contains('학교')));
    });

    test('is null without a section', () {
      final result = YamlParserService.parseLessonYaml('''---
vocabulary:
---

# Lesson

## Vocabulary list

- 학교 — school
''');
      expect(result.vocabularySection, isNull);
    });
  });

  group('parseVocabularySection', () {
    test('reads list items with their separators', () {
      final parsed = YamlParserService.parseVocabularySection('''
- 학교 — school
* **선생님**: teacher
+ 가다 - to go
1. 책 = book
- 친구\tfriend
''');
      expect(parsed.words.map((w) => '${w.section}|${w.word}|${w.meaning}'), [
        'words|학교|school',
        'words|선생님|teacher',
        'words|가다|to go',
        'words|책|book',
        'words|친구|friend',
      ]);
      expect(parsed.unread, isEmpty);
    });

    test('takes parts of speech from ### headings', () {
      final parsed = YamlParserService.parseVocabularySection('''
### Nouns
- 학교 — school
### Verbs
- 가다 — to go
''');
      expect(parsed.words.map((w) => w.section), ['nouns', 'verbs']);
    });

    test('reads table rows and skips the header row', () {
      final parsed = YamlParserService.parseVocabularySection('''
| Korean | English |
| --- | :---: |
| 학교 | school |
| **가다** | to go |
''');
      expect(parsed.words.map((w) => '${w.word}|${w.meaning}'), [
        '학교|school',
        '가다|to go',
      ]);
      expect(parsed.unread, isEmpty);
    });

    test('keeps lines it cannot read as words', () {
      final parsed = YamlParserService.parseVocabularySection('''
These words are about school.
- 학교 — school
- 공부하다
''');
      expect(parsed.words.single.word, '학교');
      expect(parsed.unread, ['These words are about school.', '- 공부하다']);
    });
  });

  group('VocabularySectionMove.apply', () {
    const markdown = '''---
title: School   # page title
vocabulary:
  nouns:
    - ko: 학교
      en: school
---

# School

Intro.

## Vocabulary

### Nouns
- 학교 — school
- 선생님 — teacher
### Verbs
- 가다 — to go

## Practice

Practice text.
''';

    test('adds new words to the frontmatter and removes the section', () {
      final words = YamlParserService.parseVocabularySection(
        YamlParserService.parseLessonYaml(markdown).vocabularySection!,
      ).words;
      final move = VocabularySectionMove.apply(markdown, words);

      expect(move.added, 2);
      expect(move.skipped, 1);
      expect(move.text, contains('title: School   # page title'));
      expect(move.text, isNot(contains('## Vocabulary')));
      expect(move.text, contains('## Practice\n\nPractice text.\n'));

      final result = YamlParserService.parseLessonYaml(move.text);
      expect(result.vocabularySection, isNull);
      expect(
        result.lesson.vocabularies.map(
          (v) => '${v.pos}|${v.targetWord}|${v.translation}',
        ),
        unorderedEquals([
          'nouns|학교|school',
          'nouns|선생님|teacher',
          'verbs|가다|to go',
        ]),
      );
    });

    test('fills an empty vocabulary key', () {
      const empty = '''---
vocabulary:
---

# Lesson

## Vocabulary

- 학교 — school
''';
      final move = VocabularySectionMove.apply(empty, [
        (section: 'words', word: '학교', meaning: 'school', notes: 'A place.'),
      ]);
      final result = YamlParserService.parseLessonYaml(move.text);
      expect(result.lesson.vocabularies.single.targetWord, '학교');
      expect(result.lesson.vocabularies.single.notes, 'A place.');
      expect(move.text, endsWith('# Lesson\n'));
    });

    test('writes entries under the lesson\'s language key', () {
      const chinese = '''---
target: zh-TW
vocabulary:
---

# Lesson

## Vocabulary

- 學生 — student
''';
      final move = VocabularySectionMove.apply(chinese, [
        (section: 'nouns', word: '學生', meaning: 'student', notes: ''),
      ]);
      expect(move.text, contains('zh: 學生'));
    });
  });

  group('VocabularySectionMove AI reply', () {
    test('reads the words of the JSON answer', () {
      final words = VocabularySectionMove.parseReply(
        '{"words": [{"section": "Nouns", "word": "학교", "meaning": "school"},'
        ' {"word": "가다", "meaning": "to go", "notes": "Irregular."},'
        ' {"word": "", "meaning": "nothing"}]}',
      );
      expect(words.map((w) => '${w.section}|${w.word}|${w.notes}'), [
        'nouns|학교|',
        'words|가다|Irregular.',
      ]);
    });

    test('rejects an answer that is not the JSON asked for', () {
      expect(
        () => VocabularySectionMove.parseReply('Sure! Here are the words.'),
        throwsFormatException,
      );
      expect(
        () => VocabularySectionMove.parseReply('{"vocabulary": []}'),
        throwsFormatException,
      );
    });

    test('prompt names the lesson\'s languages and holds the section', () {
      final messages = VocabularySectionMove.prompt(
        '- 학교 — school',
        Lesson(title: 'L', targetLanguage: 'ko', nativeLanguage: 'en'),
      );
      expect(messages.first.content, contains('"ko"'));
      expect(messages.last.content, '- 학교 — school');
    });
  });
}
