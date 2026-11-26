import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/services/vocabulary_section_move.dart';
import 'package:lingua_srs/services/yaml_parser_service.dart';

/// What the app reads from a lesson, in the plain-text form the example
/// docs show it under "The app reads".
String describeLesson(YamlParseResult result) {
  final lesson = result.lesson;
  final sentences = {for (final s in result.sentences) s.id: s};
  final out = StringBuffer()
    ..writeln('title: ${lesson.title}')
    ..write(lesson.unitTitle == null ? '' : 'unit: ${lesson.unitTitle}\n')
    ..writeln('language: ${lesson.targetLanguage} → ${lesson.nativeLanguage}');
  if (result.wordsFromSection) out.writeln('words read from: ## Vocabulary');
  void block(String indent, String label, String value) {
    if (value.trim().isEmpty) return;
    final lines = value.trim().split('\n');
    out.writeln('$indent$label: ${lines.first}');
    for (final line in lines.skip(1)) {
      out.writeln(line.isEmpty ? '' : '$indent  $line');
    }
  }

  for (final word in lesson.vocabularies) {
    out.writeln(
      '- [${word.sectionPath.join(' › ')}] ${word.targetWord} = '
      '${word.translation}',
    );
    block('    ', 'id', word.idIsExplicit ? word.id : '');
    block('    ', 'reading', word.reading);
    block('    ', 'simplified', word.simplified);
    block('    ', 'traditional', word.traditional);
    block('    ', 'hanja', word.hanja);
    block('    ', 'kanji', word.kanji);
    block('    ', 'variants', word.variants);
    block('    ', 'tts', word.ttsText ?? '');
    block('    ', 'audio', word.audioUrl ?? '');
    block('    ', 'disambiguation', word.disambiguation);
    block('    ', 'notes', word.notes);
    for (final id in word.sentenceIds) {
      final sentence = sentences[id];
      if (sentence == null) continue;
      final marked = word.sentenceEmphasis[id];
      final target = marked?.target ?? sentence.targetText;
      final translation = marked?.translation ?? sentence.translationText;
      out.writeln(
        '    example: $target'
        '${translation.isEmpty ? '' : ' = $translation'}',
      );
      block('      ', 'tts', sentence.ttsText ?? '');
      block('      ', 'audio', sentence.audioUrl ?? '');
      block('      ', 'notes', sentence.notes);
    }
  }
  final headings = RegExp(
    r'^#{1,6} .+$',
    multiLine: true,
  ).allMatches(lesson.markdownContent).map((m) => m[0]!).toList();
  out.write(
    'lesson text: ${lesson.markdownContent.trim().isEmpty
        ? '(none)'
        : headings.isEmpty
        ? '(no headings)'
        : headings.join(' · ')}',
  );
  return out.toString();
}

/// The examples of an example doc: each ```markdown block, with the
/// ```yaml and ```text blocks after it, before the next ```markdown one.
List<({String file, String? yaml, String text})> examplesOf(String doc) {
  final blocks = RegExp(
    r'^```(markdown|yaml|text)\n(.*?)^```',
    multiLine: true,
    dotAll: true,
  ).allMatches(doc).map((m) => (lang: m[1]!, body: m[2]!)).toList();
  final examples = <({String file, String? yaml, String text})>[];
  for (var i = 0; i < blocks.length; i++) {
    if (blocks[i].lang != 'markdown') continue;
    String? yaml;
    String? text;
    for (var j = i + 1; j < blocks.length; j++) {
      if (blocks[j].lang == 'markdown') break;
      if (blocks[j].lang == 'yaml') yaml ??= blocks[j].body;
      if (blocks[j].lang == 'text') text ??= blocks[j].body;
    }
    if (text == null) fail('No ```text block after:\n${blocks[i].body}');
    examples.add((file: blocks[i].body, yaml: yaml, text: text.trimRight()));
  }
  return examples;
}

String _read(String path) =>
    File(path).readAsStringSync().replaceAll('\r\n', '\n');

void main() {
  group('docs/lesson-examples.md', () {
    final examples = examplesOf(_read('docs/lesson-examples.md'));

    test('has examples', () => expect(examples, hasLength(greaterThan(4))));

    for (final (index, example) in examples.indexed) {
      test('example ${index + 1} reads as shown', () {
        final result = YamlParserService.parseLessonYaml(example.file);
        expect(describeLesson(result), example.text);
      });
    }
  });

  group('docs/vocabulary-section-examples.md', () {
    final examples = examplesOf(_read('docs/vocabulary-section-examples.md'));

    test('has examples', () => expect(examples, hasLength(greaterThan(8))));

    for (final (index, example) in examples.indexed) {
      test('example ${index + 1} moves and reads as shown', () {
        final before = YamlParserService.parseLessonYaml(example.file);
        final reading = YamlParserService.parseVocabularySection(
          before.vocabularySection!,
          targetLanguage: before.lesson.targetLanguage,
        );
        final move = VocabularySectionMove.apply(example.file, reading);
        final span = YamlParserService.frontmatterSpan(move.text)!;
        expect(
          move.text.substring(span.$1, span.$2).trimRight(),
          example.yaml?.trimRight(),
        );
        final after = YamlParserService.parseLessonYaml(move.text);
        expect(describeLesson(after), example.text);
        if (before.wordsFromSection) {
          // A lesson without frontmatter reads the same before the move,
          // apart from where its words come from, and its lesson text: a
          // title alone with the section has none, while the moved file,
          // which no longer has the section, shows the title.
          String words(String described) =>
              described.replaceFirst(RegExp(r'\nlesson text: .*$'), '');
          expect(
            words(describeLesson(before)),
            words(example.text).replaceFirstMapped(
              RegExp(r'language: .*\n'),
              (m) => '${m[0]}words read from: ## Vocabulary\n',
            ),
          );
        }
      });
    }
  });
}
