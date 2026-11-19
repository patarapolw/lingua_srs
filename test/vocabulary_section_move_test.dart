import 'dart:io';

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
- 你好：hello
''');
      expect(parsed.words.map((w) => '${w.section}|${w.word}|${w.meaning}'), [
        'words|학교|school',
        'words|선생님|teacher',
        'words|가다|to go',
        'words|책|book',
        'words|친구|friend',
        'words|你好|hello',
      ]);
      expect(parsed.unread, isEmpty);
      expect(parsed.notes, isEmpty);
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

    test('reads nested notes and examples', () {
      final parsed = YamlParserService.parseVocabularySection('''
- 먹다 — to eat
  - Note: Irregular in honorific speech.
  - 밥을 **먹어요**. — I eat rice.
  - Example: 빵을 먹었어요.
    - I ate bread.
    - Note: Past tense.
  - 사과를 먹어요. (I eat an apple.)
  - Often used with 밥.
''', targetLanguage: 'ko');
      final word = parsed.words.single;
      expect(word.notes, [
        'Irregular in honorific speech.',
        'Often used with 밥.',
      ]);
      expect(
        word.examples.map((e) => '${e.sentence}|${e.translation}|${e.notes}'),
        [
          '밥을 **먹어요**.|I eat rice.|[]',
          '빵을 **먹**었어요.|I ate bread.|[Past tense.]',
          '사과를 **먹**어요.|I eat an apple.|[]',
        ],
      );
    });

    test('reads pinyin and Traditional forms of a Chinese word', () {
      final parsed = YamlParserService.parseVocabularySection('''
### 名词
- 学生 (xuésheng) [學生] — student
  - 注：Also used for pupils.
  - 我是学生。 — I am a student.
  - 例句：他们都是学生
- 老师（lǎoshī）（繁：老師）（formal）：teacher
''', targetLanguage: 'zh-CN');
      final student = parsed.words.first;
      expect(student.section, '名词');
      expect(student.word, '学生');
      expect(student.reading, 'xuésheng');
      expect(student.forms, {'traditional': '學生'});
      expect(student.notes, ['Also used for pupils.']);
      expect(student.examples.map((e) => '${e.sentence}|${e.translation}'), [
        '我是**学生**。|I am a student.',
        '他们都是**学生**|',
      ]);
      final teacher = parsed.words.last;
      expect(teacher.word, '老师');
      expect(teacher.reading, 'lǎoshī');
      expect(teacher.forms, {'traditional': '老師'});
      expect(teacher.notes, ['formal']);
    });

    test('takes Han characters as Simplified in a Traditional lesson', () {
      final parsed = YamlParserService.parseVocabularySection(
        '- 學生 (学生) — student',
        targetLanguage: 'zh-TW',
      );
      expect(parsed.words.single.forms, {'simplified': '学生'});
    });

    test('takes Han characters as Hanja in a Korean lesson', () {
      final parsed = YamlParserService.parseVocabularySection(
        '- 학생 (學生) — student',
        targetLanguage: 'ko',
      );
      expect(parsed.words.single.forms, {'hanja': '學生'});
    });

    test('reads tables by their header names', () {
      final parsed = YamlParserService.parseVocabularySection('''
| 汉字 | 拼音 | 繁體 | English | 例句 | Example translation | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| 学生 | xuésheng | 學生 | student | 我是学生。 | I am a student. | Common. |
| 老师 | lǎoshī | 老師 | teacher | | | |
''', targetLanguage: 'zh');
      expect(parsed.words, hasLength(2));
      final student = parsed.words.first;
      expect(student.reading, 'xuésheng');
      expect(student.forms, {'traditional': '學生'});
      expect(student.meaning, 'student');
      expect(student.notes, ['Common.']);
      expect(student.examples.single.sentence, '我是**学生**。');
      expect(student.examples.single.translation, 'I am a student.');
      expect(parsed.words.last.examples, isEmpty);
    });

    test('reads a table without a header row as word and meaning', () {
      final parsed = YamlParserService.parseVocabularySection('''
| 학교 | school |
| **가다** | to go |
''');
      expect(parsed.words.map((w) => '${w.word}|${w.meaning}'), [
        '학교|school',
        '가다|to go',
      ]);
    });

    test('keeps text that is not about one word, with its heading', () {
      final parsed = YamlParserService.parseVocabularySection('''
These words are about school.

### Verbs

Verbs end in 다.

- 공부하다 — to study
  - 매일 공부해요. — I study every day.
- 가다
''', targetLanguage: 'ko');
      expect(parsed.words.single.examples.single.sentence, '매일 **공부**해요.');
      expect(parsed.unread, ['- 가다']);
      expect(
        parsed.notes,
        'These words are about school.\n\n### Verbs\n\nVerbs end in 다.\n\n'
        '- 가다',
      );
    });
  });

  group('Markdown without frontmatter', () {
    const chinese = '''# Lesson 3

Intro.

## Vocabulary

Words for the classroom.

### Nouns
- 学生 (xuésheng) [學生] — student
  - 我是学生。 — I am a student.
    - Note: 是 links two nouns.

## Practice

Practice text.
''';

    test('is a lesson only with a ## Vocabulary section', () {
      expect(YamlParserService.isLessonMarkdown(chinese), isTrue);
      expect(
        YamlParserService.isLessonMarkdown('# README\n\nHow to build.\n'),
        isFalse,
      );
      expect(
        YamlParserService.isLessonMarkdown(
          '---\ntitle: index\n---\n# Index\n\n## Vocabulary\n\n- a — b\n',
        ),
        isFalse,
      );
      expect(
        YamlParserService.isLessonMarkdown('---\nvocabulary:\n---\n# L\n'),
        isTrue,
      );
      // `## Vocabulary` in plain YAML is a comment.
      expect(
        YamlParserService.isLessonMarkdown(
          '## Vocabulary\nvocabulary:\n  nouns:\n    - ko: 책\n      en: book\n',
        ),
        isFalse,
      );
    });

    test('reads its words from the section', () {
      final result = YamlParserService.parseLessonYaml(chinese);
      expect(result.wordsFromSection, isTrue);
      expect(result.lesson.title, 'Lesson 3');
      expect(result.lesson.targetLanguage, 'zh');
      final word = result.lesson.vocabularies.single;
      expect(word.pos, 'nouns');
      expect(word.targetWord, '学生');
      expect(word.translation, 'student');
      final sentence = result.sentences.single;
      expect(sentence.targetText, '我是学生。');
      expect(sentence.translationText, 'I am a student.');
      expect(sentence.notes, '是 links two nouns.');
      expect(
        result.lesson.markdownContent,
        '# Lesson 3\n\nIntro.\n\n## Vocabulary notes\n\n'
        'Words for the classroom.\n\n## Practice\n\nPractice text.',
      );
    });

    test('gives it a frontmatter when its words are moved', () {
      final result = YamlParserService.parseLessonYaml(chinese);
      final move = VocabularySectionMove.apply(
        chinese,
        YamlParserService.parseVocabularySection(
          result.vocabularySection!,
          targetLanguage: result.lesson.targetLanguage,
        ),
      );
      expect(move.added, 1);
      expect(move.text, startsWith('---\ntarget: zh\nvocabulary:\n  nouns:\n'));
      expect(move.text, contains('notes: 是 links two nouns.'));
      final after = YamlParserService.parseLessonYaml(move.text);
      expect(after.wordsFromSection, isFalse);
      expect(after.lesson.vocabularies.single.targetWord, '学生');
      expect(after.sentences.single.notes, '是 links two nouns.');
    });

    test('lessonFileInfo takes its title from the heading', () {
      final lesson = YamlParserService.lessonFileInfo(
        chinese,
        sourcePath: 'unit/lesson-3.md',
      );
      expect(lesson?.title, 'Lesson 3');
    });

    test('guesses the language from the script', () {
      expect(YamlParserService.guessSectionLanguage('- 학교 — school'), 'ko');
      expect(YamlParserService.guessSectionLanguage('- 学校 — school'), 'zh');
      expect(YamlParserService.guessSectionLanguage('- がっこう — school'), 'ja');
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

Words for the classroom.

### Nouns
- 학교 — school
- 선생님 (先生님) — teacher
  - Note: Polite.
  - **선생님**, 안녕하세요. — Hello, teacher.
### Verbs
- 가다 — to go

## Practice

Practice text.
''';

    test('adds new words with their details and keeps the other text', () {
      final result = YamlParserService.parseLessonYaml(markdown);
      final reading = YamlParserService.parseVocabularySection(
        result.vocabularySection!,
        targetLanguage: result.lesson.targetLanguage,
      );
      final move = VocabularySectionMove.apply(markdown, reading);

      expect(move.added, 2);
      expect(move.skipped, 1);
      expect(move.text, contains('title: School   # page title'));
      expect(move.text, isNot(contains('## Vocabulary\n')));
      expect(
        move.text,
        contains('## Vocabulary notes\n\nWords for the classroom.\n\n## '),
      );
      expect(move.text, contains('## Practice\n\nPractice text.\n'));

      final after = YamlParserService.parseLessonYaml(move.text);
      expect(after.vocabularySection, isNull);
      expect(
        after.lesson.vocabularies.map(
          (v) => '${v.pos}|${v.targetWord}|${v.translation}',
        ),
        unorderedEquals([
          'nouns|학교|school',
          'nouns|선생님|teacher',
          'verbs|가다|to go',
        ]),
      );
      final teacher = after.lesson.vocabularies.firstWhere(
        (v) => v.targetWord == '선생님',
      );
      expect(teacher.notes, 'Polite.');
      expect(move.text, contains('hanja: 先生님'));
      expect(after.sentences.map((s) => s.targetText), contains('선생님, 안녕하세요.'));
    });

    test('writes a Chinese entry with pinyin, forms and examples', () {
      const chinese = '''---
target: zh-CN
vocabulary:
---

# Lesson

## Vocabulary

- 学生 (xuésheng) [學生] — student
  - 我是学生。 — I am a student.
''';
      final reading = YamlParserService.parseVocabularySection(
        YamlParserService.parseLessonYaml(chinese).vocabularySection!,
        targetLanguage: 'zh-CN',
      );
      final move = VocabularySectionMove.apply(chinese, reading);
      expect(move.text, contains('zh: 学生'));
      expect(move.text, contains('pinyin: xuésheng'));
      expect(move.text, contains('traditional: 學生'));
      expect(move.text, endsWith('# Lesson\n'));
      final after = YamlParserService.parseLessonYaml(move.text);
      expect(after.lesson.vocabularies.single.targetWord, '学生');
      expect(after.sentences.single.targetText, '我是学生。');
      expect(after.sentences.single.translationText, 'I am a student.');
    });

    test('turns an example without the word into a note', () {
      const lesson = '''---
vocabulary:
---

# Lesson

## Vocabulary

- 학교 — school
''';
      final move = VocabularySectionMove.apply(
        lesson,
        VocabularySectionReading(
          words: [
            SectionWord(
              section: 'nouns',
              word: '학교',
              meaning: 'school',
              examples: [
                SectionExample(sentence: '집에 가요.', translation: 'I go home.'),
              ],
            ),
          ],
        ),
      );
      final word = YamlParserService.parseLessonYaml(move.text)
          .lesson
          .vocabularies
          .single;
      expect(word.notes, 'Example: 집에 가요. — I go home.');
    });
  });

  test('docs/lesson-format.md example moves as it says', () {
    final doc = File('docs/lesson-format.md')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');
    final from = doc.indexOf('### Reading a Vocabulary section');
    final blocks = RegExp(
      r'```(markdown|yaml)\n(.*?)```',
      dotAll: true,
    ).allMatches(doc.substring(from)).toList();
    final section = blocks[0][2]!;
    final expected = blocks[1][2]!;
    final markdown =
        '---\ntarget: zh-CN\nvocabulary:\n---\n\n# Lesson\n\n$section';

    final result = YamlParserService.parseLessonYaml(markdown);
    final move = VocabularySectionMove.apply(
      markdown,
      YamlParserService.parseVocabularySection(
        result.vocabularySection!,
        targetLanguage: 'zh-CN',
      ),
    );
    expect(move.text, contains(expected));
    expect(
      move.text,
      endsWith('## Vocabulary notes\n\nWords for the classroom.\n'),
    );
  });

  test('nearMissVocabularyHeading finds headings that start no section', () {
    expect(
      YamlParserService.nearMissVocabularyHeading('# L\n\n## Vocabularies\n'),
      '## Vocabularies',
    );
    expect(
      YamlParserService.nearMissVocabularyHeading('## vocabulary:\n- a - b'),
      '## vocabulary:',
    );
    expect(
      YamlParserService.nearMissVocabularyHeading('## Vocabulary\n- a - b'),
      isNull,
    );
    // Other headings are left alone, as the docs say.
    expect(
      YamlParserService.nearMissVocabularyHeading(
        '## Vocabulary list\n### Vocabularies\n',
      ),
      isNull,
    );
  });

  group('Markdown with no source of words', () {
    // Markdown pasted from a web page: `---` rules read as YAML documents.
    const pasted = '''# 인사

Hello in Korean is **안녕하세요**.

---

Goodbye is 안녕히 가세요.
''';

    test('needsVocabulary tells it from lessons and from YAML', () {
      expect(YamlParserService.needsVocabulary(pasted), isTrue);
      expect(YamlParserService.needsVocabulary('# Title\n\nText.'), isTrue);
      expect(
        YamlParserService.needsVocabulary('---\ntitle: T\n---\n# T\n'),
        isTrue,
      );
      expect(
        YamlParserService.needsVocabulary('---\nvocabulary:\n---\n# T\n'),
        isFalse,
      );
      expect(
        YamlParserService.needsVocabulary('# T\n\n## Vocabulary\n- 책 - book\n'),
        isFalse,
      );
      // Plain YAML keeps its own errors.
      expect(YamlParserService.needsVocabulary('lesson: Greetings\n'), isFalse);
      expect(YamlParserService.needsVocabulary('  '), isFalse);
    });

    test('addVocabularyKey gives Markdown a frontmatter', () {
      final text = VocabularySectionMove.addVocabularyKey(pasted);
      expect(text, startsWith('---\ntarget: ko\nvocabulary:\n---\n\n# 인사\n'));
      final lesson = YamlParserService.parseLessonYaml(text).lesson;
      expect(lesson.title, '인사');
      expect(lesson.vocabularies, isEmpty);
      expect(lesson.markdownContent, contains('Goodbye is 안녕히 가세요.'));
    });

    test('addVocabularyKey keeps the frontmatter it has', () {
      final text = VocabularySectionMove.addVocabularyKey(
        '---\ntitle: Lesson 9   # page title\n---\n# 第九课\n',
      );
      expect(
        text,
        '---\ntarget: zh\ntitle: Lesson 9   # page title\nvocabulary:\n'
        '---\n# 第九课\n',
      );
      expect(
        VocabularySectionMove.addVocabularyKey(
          '---\ntarget: zh-TW\n---\n# 第九課\n',
        ),
        '---\ntarget: zh-TW\nvocabulary:\n---\n# 第九課\n',
      );
    });

    test('lessonPrompt asks for the lesson\'s own sentences only', () {
      final messages = VocabularySectionMove.lessonPrompt(
        pasted,
        Lesson(title: 'L', targetLanguage: 'ko', nativeLanguage: 'en'),
      );
      expect(messages.first.content, contains('"ko"'));
      expect(messages.first.content, contains('Do not write new sentences'));
      expect(messages.last.content, pasted);
    });

    test('words from the AI move into the new frontmatter', () {
      final withKey = VocabularySectionMove.addVocabularyKey(pasted);
      final move = VocabularySectionMove.apply(
        withKey,
        VocabularySectionMove.parseReply(
          '{"words": [{"section": "expressions", "word": "안녕하세요", '
          '"meaning": "hello", "examples": [{"sentence": '
          '"Hello in Korean is **안녕하세요**."}]}], "notes": ""}',
        ),
      );
      expect(move.added, 1);
      final lesson = YamlParserService.parseLessonYaml(move.text).lesson;
      expect(lesson.vocabularies.single.targetWord, '안녕하세요');
      expect(move.text, isNot(contains('## Vocabulary notes')));
    });
  });

  group('emphasizeWord', () {
    test('marks the word, an alternative form or a Korean stem', () {
      expect(YamlParserService.emphasizeWord('我是学生。', '学生'), '我是**学生**。');
      expect(
        YamlParserService.emphasizeWord('我是學生。', '学生', alternatives: ['學生']),
        '我是**學生**。',
      );
      expect(
        YamlParserService.emphasizeWord('밥을 먹어요.', '먹다', language: 'ko'),
        '밥을 **먹**어요.',
      );
      expect(YamlParserService.emphasizeWord('집에 가요.', '학교'), isNull);
    });
  });

  group('VocabularySectionMove AI reply', () {
    test('reads the words of the JSON answer', () {
      final reading = VocabularySectionMove.parseReply('''
{"words": [
  {"section": "Nouns", "word": "学生", "meaning": "student",
   "reading": "xuésheng", "traditional": "學生", "notes": ["Common."],
   "examples": [{"sentence": "我是**学生**。", "translation": "I am a student.",
                 "notes": "Simple."}]},
  {"word": "가다", "meaning": "to go", "notes": "Irregular."},
  {"word": "", "meaning": "nothing"}
], "notes": "### Nouns\\n\\nPeople at school."}
''');
      final student = reading.words.first;
      expect(student.section, 'nouns');
      expect(student.reading, 'xuésheng');
      expect(student.forms, {'traditional': '學生'});
      expect(student.notes, ['Common.']);
      expect(student.examples.single.notes, ['Simple.']);
      expect(reading.words.last.section, 'words');
      expect(reading.words.last.notes, ['Irregular.']);
      expect(reading.words, hasLength(2));
      expect(reading.notes, '### Nouns\n\nPeople at school.');
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

    test('prompt asks a Chinese lesson for pinyin and both forms', () {
      final messages = VocabularySectionMove.prompt(
        '- 学生 — student',
        Lesson(title: 'L', targetLanguage: 'zh-CN', nativeLanguage: 'en'),
      );
      expect(messages.first.content, contains('"zh-CN"'));
      expect(messages.first.content, contains('pinyin'));
      expect(messages.first.content, contains('"traditional"'));
      expect(messages.last.content, '- 学生 — student');
    });
  });
}
