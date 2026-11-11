import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/lesson.dart';
import 'package:lingua_srs/models/sentence.dart';
import 'package:lingua_srs/models/vocab_item.dart';
import 'package:lingua_srs/services/lesson_file_update.dart';
import 'package:lingua_srs/services/lesson_word_match.dart';
import 'package:lingua_srs/services/yaml_parser_service.dart';

void main() {
  const file = '''---
title: My page   # shown by VitePress
outline: deep
vocabulary:
  verbs:
    # movement
    - ko: 가다
      en: to go
      examples:
        - ko: 학교에 **가요**
          en: I **go** to school
          audio: https://example.com/school.mp3
        - ko: 집에 **가요**
          en: I go home
      audio: https://example.com/go.mp3
    - ko: 오다
      en: to come
  nouns:
    - ko: 학교
      en: school
---
# Lesson 1

Text with a rule.

---

<TTS>가다</TTS>
''';

  /// The lesson as imported from [text], and its sentences by id.
  (Lesson, Map<String, Sentence>) imported(String text) {
    final parsed = YamlParserService.parseLessonYaml(text);
    return (
      parsed.lesson,
      {for (final sentence in parsed.sentences) sentence.id: sentence},
    );
  }

  String body(String text) => text.substring(text.indexOf('\n---\n# '));

  group('LessonFileUpdate', () {
    test('needs nothing for a file the app agrees with', () {
      final (lesson, sentences) = imported(file);
      expect(LessonFileUpdate.plan(file, lesson, sentences), isNull);
    });

    test('is nothing for text without frontmatter', () {
      final (lesson, sentences) = imported(file);
      expect(LessonFileUpdate.plan('# Lesson 1\n', lesson, sentences), isNull);
    });

    test('writes a word and a translation in place, and nothing else', () {
      final (lesson, sentences) = imported(file);
      lesson.vocabularies[0].translation = 'go';
      lesson.vocabularies[1].targetWord = '오다 (오)';

      final update = LessonFileUpdate.plan(file, lesson, sentences)!;

      expect(update.changed, 2);
      expect(update.added, 0);
      expect(
        update.text,
        file
            .replaceFirst('en: to go', 'en: go')
            .replaceFirst('ko: 오다', 'ko: 오다 (오)'),
      );
      expect(update.sources[lesson.vocabularies[0]]!.translation, 'go');
    });

    test('writes notes typed in the app, not ones another file gave', () {
      final (lesson, sentences) = imported(file);
      lesson.vocabularies[0].notes = 'First.\n\nSecond: with a colon.';
      // As an import from another lesson's file would set it.
      lesson.vocabularies[1].shared.mergeImport(
        'notes',
        'From another file.',
        lessonId: 'other',
      );

      final update = LessonFileUpdate.plan(file, lesson, sentences)!;

      expect(update.changed, 1);
      final written = YamlParserService.parseLessonYaml(update.text);
      expect(
        written.lesson.vocabularies[0].notes,
        'First.\n\nSecond: with a colon.',
      );
      expect(written.lesson.vocabularies[1].notes, isEmpty);
      expect(update.text, contains('# movement'));
      expect(update.text, contains('title: My page   # shown by VitePress'));
      expect(body(update.text), body(file));
    });

    test('adds, removes and re-marks examples, keeping the others as '
        'written', () {
      final (lesson, sentences) = imported(file);
      final word = lesson.vocabularies[0];
      final home = sentences.values.firstWhere(
        (sentence) => sentence.targetText == '집에 가요',
      );
      word.sentenceIds.remove(home.id);
      final added = Sentence(targetText: '같이 가요', translationText: "Let's go");
      sentences[added.id] = added;
      word.sentenceIds.add(added.id);
      word.sentenceEmphasis[added.id] = const SentenceEmphasis(
        target: '같이 **가요**',
        translation: "Let's **go**",
      );
      final school = sentences[word.sentenceIds.first]!;
      word.sentenceEmphasis[school.id] = const SentenceEmphasis(
        target: '**학교에** 가요',
        translation: 'I **go** to school',
      );

      final update = LessonFileUpdate.plan(file, lesson, sentences)!;

      expect(update.changed, 1);
      final written = YamlParserService.parseLessonYaml(update.text);
      final entry = written.lesson.vocabularies[0];
      final examples = {
        for (final sentence in written.sentences) sentence.id: sentence,
      };
      expect(
        [
          for (final id in entry.sentenceIds)
            entry.targetTextFor(examples[id]!),
        ],
        ['**학교에** 가요', '같이 **가요**'],
      );
      // What the entry and its kept example had besides is still there.
      expect(entry.audioUrl, 'https://example.com/go.mp3');
      expect(
        examples[entry.sentenceIds.first]!.audioUrl,
        'https://example.com/school.mp3',
      );
      expect(body(update.text), body(file));
    });

    test('adds a word made in the app to its section, or a new one', () {
      final (lesson, sentences) = imported(file);
      final example = Sentence(targetText: '물을 마셔요', translationText: '');
      sentences[example.id] = example;
      lesson.vocabularies.addAll([
        VocabItem(
          targetWord: '마시다',
          translation: 'to drink',
          pos: 'verbs',
          sentenceIds: [example.id],
        ),
        VocabItem(targetWord: '빨리', translation: 'quickly', pos: 'adverbs'),
      ]);

      final update = LessonFileUpdate.plan(file, lesson, sentences)!;

      expect(update.changed, 0);
      expect(update.added, 2);
      final written = YamlParserService.parseLessonYaml(update.text);
      expect(
        {
          for (final vocab in written.lesson.vocabularies)
            vocab.targetWord: vocab.pos,
        },
        {
          '가다': 'verbs',
          '오다': 'verbs',
          '마시다': 'verbs',
          '학교': 'nouns',
          '빨리': 'adverbs',
        },
      );
      // Import needs every example marked.
      expect(
        update.text,
        contains(
          '    - ko: 오다\n'
          '      en: to come\n'
          '    - ko: "마시다"\n'
          '      en: "to drink"\n'
          '      examples:\n'
          '        - ko: "**물을 마셔요**"\n'
          '  nouns:\n',
        ),
      );
      expect(update.text, contains('# movement'));
      expect(body(update.text), body(file));
    });

    test('leaves alone an entry the app has no word for, and does not put '
        'back a word the file dropped', () {
      final (lesson, sentences) = imported(file);
      // Deleted in the app.
      lesson.vocabularies.removeAt(1);
      // Taken out of the file since it was imported.
      final dropped = file.replaceFirst(
        '  nouns:\n    - ko: 학교\n      en: school\n',
        '',
      );

      expect(LessonFileUpdate.plan(dropped, lesson, sentences), isNull);
    });

    test('fills an empty vocabulary', () {
      const empty = '---\nvocabulary:\n---\n# Lesson 2\n\nText.\n';
      final (lesson, sentences) = imported(empty);
      lesson.vocabularies.add(
        VocabItem(targetWord: '물', translation: 'water', pos: 'nouns'),
      );

      final update = LessonFileUpdate.plan(empty, lesson, sentences)!;

      expect(
        update.text,
        '---\nvocabulary:\n  nouns:\n    - ko: 물\n      en: water\n'
        '---\n# Lesson 2\n\nText.\n',
      );
    });

    test('updates the frontmatter an export writes', () {
      const exported =
          '---\n{"title":"Lesson 3","target":"ko","native":"en",'
          '"vocabulary":{"nouns":[{"id":"w1","target":"물","meaning":"water"}]}}'
          '\n---\n# Lesson 3\n';
      final (lesson, sentences) = imported(exported);
      lesson.vocabularies.single.translation = 'water (to drink)';

      final update = LessonFileUpdate.plan(exported, lesson, sentences)!;

      final written = YamlParserService.parseLessonYaml(update.text);
      expect(written.lesson.vocabularies.single.id, 'w1');
      expect(
        written.lesson.vocabularies.single.translation,
        'water (to drink)',
      );
      expect(update.text, endsWith('\n---\n# Lesson 3\n'));
    });
  });

  group('LessonWordMatch', () {
    VocabItem word(
      String target,
      String translation, {
      String? id,
      VocabSource? source,
    }) => VocabItem(
      id: id,
      idIsExplicit: id != null && !id.startsWith('auto-'),
      targetWord: target,
      translation: translation,
      pos: 'verbs',
      source: source,
    );

    test('finds a word edited in the app by what its file said', () {
      final saved = word(
        '가다',
        'go',
        id: 'mine',
        source: const VocabSource(targetWord: '가다', translation: 'to go'),
      );
      final entry = word('가다', 'to go', id: 'auto-1');

      final match = LessonWordMatch.match([entry], [saved])[entry]!;

      expect(match.word, same(saved));
      expect(match.kind, WordMatchKind.source);
    });

    test('pairs an edited entry only when asked, and only with a word that '
        'came from a file', () {
      final saved = word(
        '가다',
        'to go',
        id: 'auto-1',
        source: const VocabSource(targetWord: '가다', translation: 'to go'),
      );
      final own = word('배', 'pear');
      final entries = [
        word('가다', 'go', id: 'auto-2'),
        word('배', 'boat', id: 'auto-3'),
      ];

      expect(LessonWordMatch.match(entries, [saved, own]), isEmpty);
      final matches = LessonWordMatch.match(entries, [saved, own], edits: true);

      expect(matches[entries[0]]!.word, same(saved));
      expect(matches[entries[0]]!.kind, WordMatchKind.edited);
      expect(matches[entries[1]], isNull);
    });

    test('gives a saved word to the entry with its id, whatever the order', () {
      final first = word(
        '가다',
        'to go',
        id: 'a',
        source: const VocabSource(targetWord: '가다', translation: 'to go'),
      );
      final entries = [
        word('가다', 'to go', id: 'b'),
        word('가다', 'to go', id: 'a'),
      ];

      final matches = LessonWordMatch.match(entries, [first], edits: true);

      expect(matches[entries[1]]!.word, same(first));
      expect(matches[entries[0]], isNull);
    });
  });

  test('frontmatterSpan is the YAML between the --- lines', () {
    expect(YamlParserService.frontmatterSpan('# No frontmatter\n'), isNull);
    expect(YamlParserService.frontmatterSpan('---\nnever closed\n'), isNull);
    const text = '\n---\r\nvocabulary:\r\n---\r\n# Title\r\n';
    final (start, end) = YamlParserService.frontmatterSpan(text)!;
    expect(text.substring(start, end), 'vocabulary:\r\n');
    final (emptyStart, emptyEnd) = YamlParserService.frontmatterSpan(
      '---\n---\n# Title\n',
    )!;
    expect(emptyEnd, emptyStart);
  });
}
