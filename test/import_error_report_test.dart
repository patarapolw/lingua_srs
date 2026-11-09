import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/services/yaml_parser_service.dart';
import 'package:lingua_srs/views/yaml_import_view.dart';

String _lesson(String title, List<(String word, String sentence)> examples) {
  final buffer = StringBuffer('---\nvocabulary:\n  nouns:\n');
  for (final (word, sentence) in examples) {
    buffer
      ..writeln('    - ko: $word')
      ..writeln('      en: meaning of $word')
      ..writeln('      examples:')
      ..writeln('        - ko: "$sentence"')
      ..writeln('          en: "translation"');
  }
  buffer.writeln('---\n# $title');
  return buffer.toString();
}

void main() {
  group('MissingEmphasisException', () {
    test('lists every example without ** in the file, not just the first', () {
      final yaml = _lesson('L', [
        ('배', '저는 배를 먹어요'),
        ('사과', '저는 **사과**를 먹어요'),
        ('귤', '귤이 맛있어요'),
        ('감', '감을 따요'),
      ]);

      try {
        YamlParserService.parseLessonYaml(yaml);
        fail('should have thrown');
      } on MissingEmphasisException catch (error) {
        expect(error.sentences.map((m) => m.word), ['배', '귤', '감']);
        expect(error.message, contains('3 example sentences have'));
        for (final sentence in ['저는 배를 먹어요', '귤이 맛있어요', '감을 따요']) {
          expect(error.message, contains(sentence));
        }
        expect(error.message, isNot(contains('저는 **사과**를')));
      }
    });

    test('a file where every example has ** still imports', () {
      final parsed = YamlParserService.parseLessonYaml(
        _lesson('L', [('배', '저는 **배**를 먹어요')]),
      );
      expect(parsed.sentences, hasLength(1));
    });
  });

  group('describeImportError', () {
    test('names the file, the count and the sentences', () {
      final error = MissingEmphasisException([
        (word: '배', sentence: '저는 배를 먹어요'),
        (word: '귤', sentence: '귤이 맛있어요'),
      ]);

      expect(
        describeImportError('unit1/a.md', error),
        'unit1/a.md: 2 example sentences have no **emphasis**\n'
        '    배: 저는 배를 먹어요\n'
        '    귤: 귤이 맛있어요',
      );
    });

    test('quotes a few sentences of a long file and counts the rest', () {
      final error = MissingEmphasisException([
        for (var i = 0; i < 8; i++) (word: 'w$i', sentence: 's$i'),
      ]);

      final lines = describeImportError('big.md', error).split('\n');
      expect(lines.first, 'big.md: 8 example sentences have no **emphasis**');
      expect(lines, hasLength(1 + 5 + 1));
      expect(lines.last, '    …and 3 more');
    });

    test('other errors keep their plain form', () {
      expect(
        describeImportError('a.md', const FormatException('bad yaml')),
        'a.md: FormatException: bad yaml',
      );
    });

    test('the combined message lists every file and hints once', () {
      final text = describeImportErrors('2 files could not be parsed:', [
        'a.md: 1 example sentence has no **emphasis**\n    배: x',
        'b/c.md: 1 example sentence has no **emphasis**\n    귤: y',
      ]);

      expect(text, contains('a.md'));
      expect(text, contains('b/c.md'));
      expect('Wrap the word being studied'.allMatches(text), hasLength(1));
    });

    test('there is no emphasis hint for other errors', () {
      final text = describeImportErrors('1 file could not be parsed:', [
        'a.md: FormatException: bad yaml',
      ]);
      expect(text, isNot(contains('Wrap the word')));
    });
  });

  group('Importing a folder', () {
    late Directory root;
    setUp(() => root = Directory.systemTemp.createTempSync('lingua_srs_dir_'));
    tearDown(() => root.deleteSync(recursive: true));

    String write(String relative, String contents) {
      final file = File('${root.path}/$relative')
        ..createSync(recursive: true)
        ..writeAsStringSync(contents);
      return file.path;
    }

    test('reports every file with a sentence lacking **, by its path', () {
      final good = write(
        'unit1/good.md',
        _lesson('Good', [('배', '**배**가 커요')]),
      );
      final badOne = write('unit1/a.md', _lesson('A', [('사과', '사과가 커요')]));
      final badTwo = write(
        'unit2/deep/b.md',
        _lesson('B', [('귤', '귤이 커요'), ('감', '감이 커요')]),
      );

      final result = parseMarkdownFiles(
        [good, badOne, badTwo],
        [root.path],
        const {},
      );

      expect(result.imports.map((file) => file.path), ['unit1/good.md']);
      expect(result.errors, hasLength(2));
      expect(
        result.errors[0],
        startsWith('unit1/a.md: 1 example sentence has'),
      );
      expect(result.errors[0], contains('사과가 커요'));
      expect(
        result.errors[1],
        startsWith('unit2/deep/b.md: 2 example sentences'),
      );
      expect(result.errors[1], contains('귤이 커요'));
      expect(result.errors[1], contains('감이 커요'));
    });
  });

  group('Importing a zip', () {
    PickedMarkdownSource zip(String name, Map<String, String> files) {
      final archive = Archive();
      files.forEach((path, contents) {
        archive.add(ArchiveFile.string(path, contents));
      });
      return PickedMarkdownSource(
        name: name,
        sourceKey: 'file:///$name',
        bytes: ZipEncoder().encode(archive),
      );
    }

    test('reports every file inside the zip with a sentence lacking **', () {
      final result = parsePickedMarkdownSources([
        zip('lessons.zip', {
          'unit1/good.md': _lesson('Good', [('배', '**배**가 커요')]),
          'unit1/a.md': _lesson('A', [('사과', '사과가 커요')]),
          'unit2/b.md': _lesson('B', [('귤', '귤이 커요')]),
          'unit2/notes.md': '# no vocabulary here',
        }),
      ], const {});

      expect(result.imports.map((file) => file.path), [
        'lessons.zip/unit1/good.md',
      ]);
      expect(result.errors, hasLength(2));
      expect(
        result.errors.map((line) => line.split(':').first),
        unorderedEquals(['lessons.zip/unit1/a.md', 'lessons.zip/unit2/b.md']),
      );
      expect(result.errors.join('\n'), contains('사과가 커요'));
      expect(result.errors.join('\n'), contains('귤이 커요'));
      expect(result.skipped, 1);
    });

    test('skips unchanged entries when the zip is picked from elsewhere', () {
      PickedMarkdownSource picked(String key, String b) {
        final source = zip('course.zip', {
          'unit1/a.md': _lesson('A', [('배', '**배**가 커요')]),
          'unit1/b.md': b,
        });
        return PickedMarkdownSource(
          name: source.name,
          sourceKey: key,
          bytes: source.bytes,
        );
      }

      final first = parsePickedMarkdownSources([
        picked(
          'file:///cache/file_picker/1/course.zip',
          _lesson('B', [('귤', '**귤**이 커요')]),
        ),
      ], const {});
      final saved = {
        for (final file in first.imports) file.sourceKey: file.sourceHash,
      };

      // Android copies the picked zip to a new cache folder every time.
      final again = parsePickedMarkdownSources([
        picked(
          'file:///cache/file_picker/2/course (1).zip',
          _lesson('B', [('감', '**감**이 커요')]),
        ),
      ], saved);

      expect(again.unchanged, 1);
      expect(again.imports.map((file) => file.path), ['course.zip/unit1/b.md']);
      expect(again.imports.single.sourceKey, zipEntrySourceKey('unit1/b.md'));
    });

    test('lists the lessons of skipped entries, with their paths', () {
      final source = zip('course.zip', {
        'unit-1/a.md': _lesson('Lesson A', [('배', '**배**가 커요')]),
      });
      final first = parsePickedMarkdownSources([source], const {});
      final saved = {
        for (final file in first.imports) file.sourceKey: file.sourceHash,
      };

      final again = parsePickedMarkdownSources([source], saved);

      expect(again.unchanged, 1);
      final lesson = again.unchangedLessons.single;
      expect(lesson.fileName, 'a.md');
      expect(lesson.fileFolder, 'unit-1');
      expect(lesson.folderPath, ['Unit 1']);
      expect(lesson.vocabularies, isEmpty);
    });

    test('still skips entries saved under the zip location', () {
      final source = zip('course.zip', {
        'a.md': _lesson('A', [('배', '**배**가 커요')]),
      });
      final first = parsePickedMarkdownSources([source], const {});
      final hash = first.imports.single.sourceHash;

      final again = parsePickedMarkdownSources(
        [source],
        {'${source.sourceKey}!/a.md': hash},
      );

      expect(again.unchanged, 1);
      expect(again.imports, isEmpty);
    });

    test('files from several zips are all named', () {
      final result = parsePickedMarkdownSources([
        zip('one.zip', {
          'a.md': _lesson('A', [('배', '배가 커요')]),
        }),
        zip('two.zip', {
          'b.md': _lesson('B', [('귤', '귤이 커요')]),
        }),
      ], const {});

      expect(result.errors.map((line) => line.split(':').first), [
        'one.zip/a.md',
        'two.zip/b.md',
      ]);
    });
  });

  test('plain text sources are named by file name', () {
    final result = parsePickedMarkdownSources([
      PickedMarkdownSource(
        name: 'C:\\lessons\\bad.yaml',
        sourceKey: 'file:///bad.yaml',
        bytes: utf8.encode(
          'vocabulary:\n  nouns:\n    - ko: 배\n      en: pear\n'
          '      examples:\n        - ko: "배가 커요"\n          en: "x"\n',
        ),
      ),
    ], const {});

    expect(result.errors.single, startsWith('bad.yaml: 1 example sentence'));
  });
}
