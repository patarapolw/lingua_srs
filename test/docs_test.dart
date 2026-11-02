import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/services/srs_service.dart';
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
      expect(
        verb.notes,
        'First paragraph of **Markdown** notes.\n\nSecond paragraph.',
      );

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

  group('docs/features.md', () {
    test('numbers its sections consecutively', () {
      final doc = _readDoc('docs/features.md');
      final matches = RegExp(r'^(\d+)\. \*\*', multiLine: true).allMatches(doc);
      final numbers = [for (final m in matches) int.parse(m[1]!)];

      expect(numbers, isNotEmpty);
      expect(numbers, [for (var i = 1; i <= numbers.length; i++) i]);
    });
  });

  group('docs/architecture.md', () {
    final architecture = _readDoc('docs/architecture.md');
    final libFiles = [
      for (final entity in Directory('lib').listSync(recursive: true))
        if (entity is File && entity.path.endsWith('.dart'))
          entity.uri.pathSegments.last,
    ];

    test('lists every Dart file under lib/', () {
      final missing = [
        for (final name in libFiles)
          if (!architecture.contains(name)) name,
      ];
      expect(missing, isEmpty, reason: 'Not in architecture.md: $missing');
    });

    test('does not list Dart files that no longer exist', () {
      final listed = RegExp(r'[a-z0-9_]+\.dart').allMatches(architecture);
      final stale = [
        for (final match in listed)
          if (!libFiles.contains(match[0])) match[0]!,
      ];
      expect(stale, isEmpty, reason: 'Not in lib/: $stale');
    });
  });

  group('README.md', () {
    final readme = _readDoc('README.md');

    test('links every document in docs/', () {
      final names = <String>[];
      for (final entity in Directory('docs').listSync()) {
        if (entity is File && entity.path.endsWith('.md')) {
          names.add(entity.uri.pathSegments.last);
        }
      }
      expect(names, isNotEmpty);

      final missing = [
        for (final name in names)
          if (!readme.contains('](docs/$name)')) name,
      ];
      expect(missing, isEmpty, reason: 'README.md does not link: $missing');
    });

    test('gives every screenshot alt text', () {
      final tags = RegExp(r'<img\b[^>]*>').allMatches(readme);
      expect(tags, isNotEmpty);

      for (final tag in tags) {
        expect(
          RegExp(r'\salt="[^"]+"').hasMatch(tag[0]!),
          isTrue,
          reason: 'Missing alt text: ${tag[0]}',
        );
      }
    });

    test('names every platform that has a project folder', () {
      const platforms = {
        'android': 'Android',
        'ios': 'iOS',
        'linux': 'Linux',
        'macos': 'macOS',
        'windows': 'Windows',
      };
      final intro = readme.substring(0, readme.indexOf('\n## '));

      for (final entry in platforms.entries) {
        if (!Directory(entry.key).existsSync()) continue;
        expect(
          intro,
          contains(entry.value),
          reason: '${entry.key}/ exists but the intro omits ${entry.value}',
        );
      }
    });

    test('states the Again and Hard delays used by SrsService', () {
      final again = SrsService.againDelay.inHours;
      final hard = SrsService.hardDelay.inHours;

      expect(readme, contains('*Again* is due again after $again hour'));
      expect(readme, contains('*Hard* after $hard hours'));
    });

    test('stays a short overview', () {
      // AGENTS.md: keep README.md short and put detail in docs/.
      final lines = readme.trimRight().split('\n');
      expect(lines.length, lessThanOrEqualTo(80), reason: 'Use docs/ instead');

      final start = readme.indexOf('## Highlights');
      final end = readme.indexOf('\n## ', start);
      final section = readme.substring(start, end).split('\n');
      final bullets = section.where((l) => l.startsWith('- ')).toList();
      expect(bullets, isNotEmpty);

      for (final bullet in bullets) {
        expect(
          bullet.length,
          lessThanOrEqualTo(200),
          reason: 'Move detail to docs/features.md: $bullet',
        );
      }
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
