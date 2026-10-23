import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/services/yaml_parser_service.dart';

/// Returns the first fenced code block tagged [lang] in [markdown].
String _fencedBlock(String markdown, String lang) {
  final match = RegExp(
    '```$lang\\n(.*?)```',
    dotAll: true,
  ).firstMatch(markdown);
  if (match == null) fail('No ```$lang block found');
  return match.group(1)!;
}

String _readDoc(String path) =>
    File(path).readAsStringSync().replaceAll('\r\n', '\n');

void main() {
  group('docs/lesson-format.md examples', () {
    final doc = _readDoc('docs/lesson-format.md');

    test('vocabulary YAML example parses', () {
      final parsed = YamlParserService.parseLessonYaml(
        _fencedBlock(doc, 'yaml'),
        defaultTitle: 'Docs example',
      );

      expect(parsed.lesson.title, 'Docs example');
      expect(parsed.lesson.vocabularies.length, 3);

      final noun = parsed.lesson.vocabularies[0];
      expect(noun.pos, 'nouns');
      expect(noun.targetWord, '예시 단어');
      expect(noun.translation, 'example word');
      expect(noun.sentenceIds.length, 2);

      final verb = parsed.lesson.vocabularies[1];
      expect(verb.pos, 'verbs');
      expect(verb.targetWord, '만들다');
      expect(verb.notes, 'First paragraph of **Markdown** notes.\n\nSecond paragraph.');

      final number = parsed.lesson.vocabularies[2];
      expect(number.targetWord, '3개');
      expect(number.ttsText, '세 개');
      expect(number.speechText, '세 개');

      expect(parsed.sentences.length, 2);
    });

    test('Markdown frontmatter example parses', () {
      final markdown = _fencedBlock(doc, 'markdown');

      expect(YamlParserService.hasVocabularyFrontmatter(markdown), isTrue);

      final parsed = YamlParserService.parseLessonYaml(markdown);
      expect(parsed.lesson.title, 'Lesson 1: Example title');
      expect(parsed.lesson.vocabularies, isEmpty);
      expect(parsed.lesson.markdownContent, contains('Lesson notes go here.'));
    });

    test('adding-to-an-existing-lesson example parses', () {
      final block = RegExp(
        '```yaml\\n(.*?)```',
        dotAll: true,
      ).allMatches(doc).last.group(1)!;

      final parsed = YamlParserService.parseLessonYaml(
        block,
        defaultTitle: 'Existing lesson',
      );

      expect(parsed.lesson.title, 'Existing lesson');
      expect(parsed.lesson.vocabularies, hasLength(1));
      expect(parsed.lesson.vocabularies.single.targetWord, '새 단어');
    });
  });

  group('documentation links', () {
    final files = <File>[
      File('README.md'),
      File('AGENTS.md'),
      File('CLAUDE.md'),
      // File('TODO.md'),
      ...Directory('docs')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.md')),
    ];

    /// Relative link targets in [source], ignoring HTML comments, fenced
    /// code and inline code.
    List<String> relativeTargets(String source) {
      final text = source
          .replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '')
          .replaceAll(RegExp(r'```.*?```', dotAll: true), '')
          .replaceAll(RegExp(r'`[^`\n]*`'), '');
      final targets = <String>[
        for (final m in RegExp(r'\]\(([^)\s]+)\)').allMatches(text)) m[1]!,
        for (final m in RegExp(r'<img[^>]*\ssrc="([^"]+)"').allMatches(text))
          m[1]!,
      ];
      return targets
          .where((t) => !RegExp(r'^([a-z][a-z0-9+.-]*:|#)').hasMatch(t))
          .map((t) => t.split('#').first)
          .where((t) => t.isNotEmpty)
          .toList();
    }

    for (final file in files) {
      test('${file.path} has no broken relative links', () {
        expect(file.existsSync(), isTrue, reason: '${file.path} is missing');

        final missing = <String>[];
        for (final target in relativeTargets(
          file.readAsStringSync().replaceAll('\r\n', '\n'),
        )) {
          final resolved = file.absolute.parent.uri.resolve(
            Uri.decodeFull(target),
          );
          final path = resolved.toFilePath();
          if (!File(path).existsSync() && !Directory(path).existsSync()) {
            missing.add(target);
          }
        }
        expect(missing, isEmpty, reason: 'Broken links: $missing');
      });
    }
  });
}
