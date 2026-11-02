import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/lesson.dart';
import 'package:lingua_srs/models/sentence.dart';
import 'package:lingua_srs/models/vocab_item.dart';
import 'package:lingua_srs/services/lesson_export_service.dart';
import 'package:lingua_srs/services/markdown_archive_service.dart';
import 'package:lingua_srs/services/yaml_parser_service.dart';

void main() {
  test(
    'exports lessons as importer-compatible Markdown in hierarchy paths',
    () {
      final sentence = Sentence(
        id: 'sentence-id',
        targetText: 'I eat an apple.',
        translationText: 'I eat fruit.',
      );
      final vocab = VocabItem(
        id: 'vocab-id',
        targetWord: 'apple',
        translation: 'fruit',
        pos: 'food',
        sectionPath: ['nouns', 'food'],
        notes: 'A note',
        sentenceIds: [sentence.id],
        sentenceEmphasis: {
          sentence.id: const SentenceEmphasis(
            target: 'I eat an **apple**.',
            translation: 'I eat **fruit**.',
          ),
        },
      );
      final lesson = Lesson(
        id: 'lesson-id',
        title: 'Lesson / 1',
        unitTitle: 'Unit 2::Grammar',
        targetLanguage: 'en',
        nativeLanguage: 'fr',
        vocabularies: [vocab],
        markdownContent: '# Old title\n\nLesson notes.',
      );

      final files = MarkdownArchiveService.readMarkdownFiles(
        LessonExportService.createZip([lesson], [sentence]),
      );

      expect(files, hasLength(1));
      expect(files.single.path, 'Unit 2/Grammar/Lesson _ 1.md');
      final parsed = YamlParserService.parseLessonYaml(files.single.contents);
      expect(parsed.lesson.displayTitle, 'Lesson / 1');
      expect(parsed.lesson.targetLanguage, 'en');
      expect(parsed.lesson.nativeLanguage, 'fr');
      expect(parsed.lesson.markdownContent, '# Lesson / 1\n\nLesson notes.');
      expect(parsed.lesson.vocabularies.single.id, 'vocab-id');
      expect(parsed.lesson.vocabularies.single.effectiveSectionPath, [
        'nouns',
        'food',
      ]);
      expect(parsed.lesson.vocabularies.single.notes, 'A note');
      expect(parsed.lesson.vocabularies.single.sentenceIds, hasLength(1));
      expect(
        parsed.lesson.vocabularies.single.sentenceEmphasis.values.single.target,
        'I eat an **apple**.',
      );
      expect(parsed.sentences.single.translationText, 'I eat fruit.');
    },
  );

  test('sanitizes archive paths and disambiguates duplicate lesson names', () {
    final lessons = [
      Lesson(id: 'first', title: '../Same'),
      Lesson(id: 'second', title: '../Same'),
    ];

    final archive = ZipDecoder().decodeBytes(
      LessonExportService.createZip(lessons, const []),
    );

    expect(
      archive.files.map((file) => file.name).toSet(),
      {'.._Same.md', '.._Same (second).md'},
    );
    expect(LessonExportService.fileName('../Unit'), '.._Unit.zip');
  });
}
