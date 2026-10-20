import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/lesson.dart';
import 'package:lingua_srs/models/srs_card.dart';
import 'package:lingua_srs/models/sentence.dart';
import 'package:lingua_srs/models/vocab_item.dart';
import 'package:lingua_srs/providers/app_provider.dart';
import 'package:lingua_srs/services/deepseek_service.dart';
import 'package:lingua_srs/services/korean_text_search.dart';
import 'package:lingua_srs/services/yaml_parser_service.dart';
import 'package:lingua_srs/services/srs_service.dart';
import 'package:lingua_srs/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final markdownStorageDirectory = Directory.systemTemp.createTempSync(
    'lingua_srs_markdown_test_',
  );
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(pathProviderChannel, (call) async {
        if (call.method == 'getApplicationSupportDirectory') {
          return markdownStorageDirectory.path;
        }
        throw MissingPluginException('Unexpected method: ${call.method}');
      });
  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    await markdownStorageDirectory.delete(recursive: true);
  });

  group('YAML Parser & Vocabulary Models', () {
    const sampleYaml = '''
Lesson: Unit 2::Lesson 26

nouns:
  - ko: 아줌마
    audio: https://example.com/audio1.mp3
    en: middle aged/older woman
    notes: |
      <p>The word "아주머니" is commonly used as well</p>
    examples:
      - ko: 저는 **아줌마**를 위해 문을 열었어요
        en: I opened the door for **an older lady**

verbs:
  - ko: 도착하다
    en: to arrive
    notes: Regular verb
''';

    test('Parses lesson title, categories and cards', () {
      final res = YamlParserService.parseLessonYaml(sampleYaml);
      expect(res.lesson.title, 'Unit 2::Lesson 26');
      expect(res.lesson.vocabularies.length, 2);

      final noun = res.lesson.vocabularies[0];
      expect(noun.targetWord, '아줌마');
      expect(noun.translation, 'middle aged/older woman');
      expect(noun.pos, 'nouns');
      expect(noun.effectiveSectionPath, ['nouns']);
      // For nouns: KO -> EN is enabled, EN -> KO is hidden by default
      expect(noun.cardTargetToNative.isEnabled, isTrue);
      expect(noun.cardNativeToTarget.isEnabled, isFalse);

      final verb = res.lesson.vocabularies[1];
      expect(verb.targetWord, '도착하다');
      expect(verb.pos, 'verbs');
      // For verbs: KO -> EN is hidden by default, EN -> KO is enabled
      expect(verb.cardTargetToNative.isEnabled, isFalse);
      expect(verb.cardNativeToTarget.isEnabled, isTrue);
    });

    test('Parses and serializes disambiguation and sentence/card notes', () {
      final parsed = YamlParserService.parseLessonYaml('''
---
vocabulary:
  nouns:
    - ko: 배
      en: pear
      disambiguation: fruit
      examples:
        - ko: 저는 **배**를 먹었어요
          en: I ate a **pear**
          notes: Note about this example.
---
# Lesson 1: Notes
''');
      final vocab = parsed.lesson.vocabularies.single;
      final sentence = parsed.sentences.single;
      vocab.cardTargetToNative.backNotes = 'Back note';

      final restoredVocab = VocabItem.fromJson(
        Map<String, dynamic>.from(vocab.toJson()),
      );
      final restoredSentence = Sentence.fromJson(
        Map<String, dynamic>.from(sentence.toJson()),
      );

      expect(restoredVocab.disambiguation, 'fruit');
      expect(restoredVocab.cardTargetToNative.backNotes, 'Back note');
      expect(restoredSentence.notes, 'Note about this example.');
    });

    test(
      'Stores Markdown body while parsing vocabulary and sentence notes',
      () {
        const markdown = '''
---
vocabulary:
  nouns:
    - ko: 배
      en: pear
      examples:
        - ko: 저는 **배**를 먹었어요
          en: I ate a **pear**
          notes: This sentence note is imported.
---
# Lesson 1: Pears

## Introduction

The full lesson text remains available to render.
''';
        final parsed = YamlParserService.parseLessonYaml(markdown);

        expect(parsed.lesson.markdownContent, contains('## Introduction'));
        expect(
          parsed.lesson.markdownContent,
          contains('The full lesson text remains available to render.'),
        );
        expect(parsed.lesson.markdownContent, isNot(contains('vocabulary:')));
        expect(
          parsed.sentences.single.notes,
          'This sentence note is imported.',
        );
      },
    );

    test('Accepts empty Markdown vocabulary frontmatter without a body', () {
      const markdown = '---\nvocabulary:\n---';

      final parsed = YamlParserService.parseLessonYaml(markdown);

      expect(parsed.lesson.vocabularies, isEmpty);
      expect(parsed.sentences, isEmpty);
      expect(parsed.lesson.markdownContent, isEmpty);
      expect(YamlParserService.hasVocabularyFrontmatter(markdown), isTrue);
    });

    test('Fresh install starts empty', () async {
      SharedPreferences.setMockInitialValues({
        'lingua_srs_windows_legacy_migration_complete': true,
      });
      final provider = AppProvider();
      while (provider.isLoading) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(provider.lessons, isEmpty);
      expect(provider.sentences, isEmpty);
    });

    test('Persists full Markdown separately from lesson JSON', () async {
      SharedPreferences.setMockInitialValues({
        'lingua_srs_windows_legacy_migration_complete': true,
        'lingua_srs_lessons': '[]',
        'lingua_srs_sentences': '[]',
      });
      final provider = AppProvider();
      while (provider.isLoading) {
        await Future<void>.delayed(Duration.zero);
      }

      final imported = await provider.importYaml('''
---
vocabulary:
  nouns:
    - ko: 배
      en: pear
---
# Lesson 1: Pears

The complete lesson body.
''');
      final storedJson = jsonDecode(
        (await SharedPreferences.getInstance()).getString(
          'lingua_srs_lessons',
        )!,
      ) as List<dynamic>;
      expect(storedJson.single, isNot(contains('markdownContent')));

      final reloadedProvider = AppProvider();
      while (reloadedProvider.isLoading) {
        await Future<void>.delayed(Duration.zero);
      }
      final reloadedLesson = reloadedProvider.lessons.single;
      expect(reloadedLesson.id, imported.id);
      expect(
        reloadedLesson.markdownContent,
        contains('The complete lesson body.'),
      );
      provider.dispose();
      reloadedProvider.dispose();
    });

    test('Edits and persists imported lesson Markdown', () async {
      SharedPreferences.setMockInitialValues({
        'lingua_srs_windows_legacy_migration_complete': true,
        'lingua_srs_lessons': '[]',
        'lingua_srs_sentences': '[]',
      });
      final provider = AppProvider();
      while (provider.isLoading) {
        await Future<void>.delayed(Duration.zero);
      }

      final lesson = await provider.importYaml('''
---
vocabulary:
---
# Lesson 26
Original text.
''');
      await provider.updateLessonMarkdown(lesson.id, '# Lesson 26\nEdited.');

      expect(lesson.markdownContent, '# Lesson 26\nEdited.');
      final reloadedProvider = AppProvider();
      while (reloadedProvider.isLoading) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(
        reloadedProvider.lessons.single.markdownContent,
        '# Lesson 26\nEdited.',
      );
      provider.dispose();
      reloadedProvider.dispose();
    });

    test('Persists lesson hierarchy reorder ranks', () async {
      SharedPreferences.setMockInitialValues({
        'lingua_srs_windows_legacy_migration_complete': true,
        'lingua_srs_lessons': '[]',
        'lingua_srs_sentences': '[]',
      });
      final provider = AppProvider();
      while (provider.isLoading) {
        await Future<void>.delayed(Duration.zero);
      }

      await provider.saveLessonHierarchyOrder([
        'folder:unit 2',
        'folder:unit 1',
        'lesson:second',
      ]);
      expect(provider.lessonHierarchyOrder['folder:unit 2'], 0);
      expect(provider.lessonHierarchyOrder['folder:unit 1'], 1);

      final reloadedProvider = AppProvider();
      while (reloadedProvider.isLoading) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(reloadedProvider.lessonHierarchyOrder['folder:unit 2'], 0);
      expect(reloadedProvider.lessonHierarchyOrder['folder:unit 1'], 1);
      provider.dispose();
      reloadedProvider.dispose();
    });

    test('Persists lesson folder expansion state', () async {
      SharedPreferences.setMockInitialValues({
        'lingua_srs_windows_legacy_migration_complete': true,
        'lingua_srs_lessons': '[]',
        'lingua_srs_sentences': '[]',
      });
      final provider = AppProvider();
      while (provider.isLoading) {
        await Future<void>.delayed(Duration.zero);
      }

      await provider.setLessonFolderExpanded('folder:unit 2', false);
      await provider.setLessonFolderExpanded('folder:unit 1', true);
      expect(provider.lessonFolderExpansion['folder:unit 2'], isFalse);
      expect(provider.lessonFolderExpansion['folder:unit 1'], isTrue);

      final reloadedProvider = AppProvider();
      while (reloadedProvider.isLoading) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(reloadedProvider.lessonFolderExpansion['folder:unit 2'], isFalse);
      expect(reloadedProvider.lessonFolderExpansion['folder:unit 1'], isTrue);
      provider.dispose();
      reloadedProvider.dispose();
    });

    test(
      'Detects duplicate card prompts independently of context sentences',
      () async {
        SharedPreferences.setMockInitialValues({
          'lingua_srs_windows_legacy_migration_complete': true,
          'lingua_srs_lessons': '[]',
          'lingua_srs_sentences': '[]',
        });
        final provider = AppProvider();
        while (provider.isLoading) {
          await Future<void>.delayed(Duration.zero);
        }

        final lesson = await provider.importYaml('''
---
vocabulary:
  nouns:
    - ko: 배
      en: pear
      examples:
        - ko: 저는 **배**를 먹었어요
          en: I ate a **pear**
    - ko: 배
      en: boat
      examples:
        - ko: 저는 **배**를 탔어요
          en: I took a **boat**
    - ko: 사과
      en: fruit
    - ko: 과일
      en: fruit
---
# Lesson 1: Duplicate prompts
''');
        final pear = lesson.vocabularies.firstWhere(
          (vocab) => vocab.translation == 'pear',
        );
        final boat = lesson.vocabularies.firstWhere(
          (vocab) => vocab.translation == 'boat',
        );
        final apple = lesson.vocabularies.firstWhere(
          (vocab) => vocab.targetWord == '사과',
        );
        final fruit = lesson.vocabularies.firstWhere(
          (vocab) => vocab.targetWord == '과일',
        );
        apple.cardNativeToTarget.isEnabled = true;
        fruit.cardNativeToTarget.isEnabled = true;

        expect(
          provider.getDuplicateFrontVocabularies(
            pear,
            CardDirection.targetToNative,
          ),
          [boat],
        );
        expect(
          provider.getDuplicateFrontVocabularies(
            apple,
            CardDirection.nativeToTarget,
          ),
          [fruit],
        );
        expect(
          provider.getDuplicateFrontVocabularies(
            pear,
            CardDirection.nativeToTarget,
          ),
          isEmpty,
        );
        provider.dispose();
      },
    );

    test('Parses Markdown vocabulary frontmatter and lesson hierarchy', () {
      const markdown = r'''
---
lesson: "Lesson 99: This root-level label should not override the heading"
extra:
  - ko: must-not-import
    en: not vocabulary
vocabulary:
  nouns:
    - ko: 목적지
      audio: https://example.com/Lesson26v6.mp3
      en: destination
      examples:
        - ko: 우리가 **목적지**에 거의 도착했어요
          en: We have almost arrived at our **destination**
---
# Lesson 26: \~는 것 Describing Nouns with Verbs

Lesson content is not part of the vocabulary data.
''';

      final result = YamlParserService.parseLessonYaml(
        markdown,
        defaultUnitTitle: 'Unit 2',
      );

      expect(result.lesson.unitTitle, 'Unit 2');
      expect(
        result.lesson.title,
        'Lesson 26: ~는 것 Describing Nouns with Verbs',
      );
      expect(result.lesson.displayTitle, result.lesson.title);
      expect(result.lesson.vocabularies, hasLength(1));
      expect(result.lesson.vocabularies.single.targetWord, '목적지');
      expect(
        result.lesson.vocabularies.any(
          (vocab) => vocab.targetWord == 'must-not-import',
        ),
        isFalse,
      );
      expect(
        result.lesson.vocabularies.single.audioUrl,
        'https://example.com/Lesson26v6.mp3',
      );
      expect(result.sentences, hasLength(1));
      expect(result.lesson.vocabularies.single.sentenceIds, [
        result.sentences.single.id,
      ]);
    });

    test('frontmatter-only Markdown is equivalent to plain YAML', () {
      const yaml = '''
vocabulary:
  nouns:
    - ko: 배
      en: pear
      examples:
        - ko: 배를 먹었어요.
          en: I ate a pear.
''';
      final plainYaml = YamlParserService.parseLessonYaml(yaml);
      final markdownFrontmatter = YamlParserService.parseLessonYaml(
        '---\n$yaml---\n',
      );

      expect(markdownFrontmatter.lesson.title, plainYaml.lesson.title);
      expect(
        markdownFrontmatter.lesson.vocabularies.map(
          (vocab) => (vocab.targetWord, vocab.translation, vocab.pos),
        ),
        plainYaml.lesson.vocabularies.map(
          (vocab) => (vocab.targetWord, vocab.translation, vocab.pos),
        ),
      );
      expect(markdownFrontmatter.sentences.length, plainYaml.sentences.length);
      expect(markdownFrontmatter.lesson.markdownContent, isEmpty);
    });

    test('Parses nested sections and creates sense-aware vocabulary IDs', () {
      const frontmatter = '''
---
vocabulary:
  nouns:
    Local:
      - ko: 배
        en: pear
      - ko: 배
        en: boat
    Global:
      - ko: 배
        en: pear
  verbs:
    - id: custom-shared-sense
      ko: 보다
      en: to see
  wildlife:
    animals:
      marine:
        - ko: 고래
          en: whale
---
# Lesson 1: Senses
''';
      final parsed = YamlParserService.parseLessonYaml(frontmatter);
      final pears = parsed.lesson.vocabularies
          .where((vocab) => vocab.translation == 'pear')
          .toList();
      final boat = parsed.lesson.vocabularies.singleWhere(
        (vocab) => vocab.translation == 'boat',
      );
      final explicitlyIdentified = parsed.lesson.vocabularies.singleWhere(
        (vocab) => vocab.targetWord == '보다',
      );
      final deeplyNested = parsed.lesson.vocabularies.singleWhere(
        (vocab) => vocab.targetWord == '고래',
      );

      expect(pears, hasLength(2));
      expect(pears[0].id, pears[1].id);
      expect(pears[0].effectiveSectionPath, ['nouns', 'Local']);
      expect(pears[1].effectiveSectionPath, ['nouns', 'Global']);
      expect(boat.id, isNot(pears[0].id));
      expect(explicitlyIdentified.id, 'custom-shared-sense');
      expect(explicitlyIdentified.idIsExplicit, isTrue);
      expect(deeplyNested.effectiveSectionPath, [
        'wildlife',
        'animals',
        'marine',
      ]);
    });

    test('Splits Unit::Lesson title into hierarchy display fields', () {
      final lesson = YamlParserService.parseLessonYaml(sampleYaml).lesson;

      expect(lesson.title, 'Unit 2::Lesson 26');
      expect(lesson.folderPath, ['Unit 2']);
      expect(lesson.displayTitle, 'Lesson 26');
    });

    test('Uses :: separated lesson paths and keeps slashes literal', () {
      final lesson = Lesson(title: 'Topic::Subtopic::Lesson A');
      final lessonWithParent = Lesson(
        title: 'Subtopic::Lesson B',
        unitTitle: 'Topic',
      );
      final slashed = Lesson(title: 'Verbs / Adjectives::Lesson C');

      expect(lesson.folderPath, ['Topic', 'Subtopic']);
      expect(lesson.displayTitle, 'Lesson A');
      expect(lessonWithParent.folderPath, ['Topic', 'Subtopic']);
      expect(lessonWithParent.displayTitle, 'Lesson B');
      expect(slashed.folderPath, ['Verbs / Adjectives']);
      expect(slashed.displayTitle, 'Lesson C');
    });

    test(
      'Startup merges duplicate sentences in one pass and keeps audio',
      () async {
        final lesson = Lesson(
          id: 'lesson-with-duplicates',
          title: 'Duplicate sentences',
          vocabularies: [
            VocabItem(
              targetWord: '배',
              translation: 'pear',
              pos: 'nouns',
              sentenceIds: ['sentence-without-audio'],
            ),
            VocabItem(
              targetWord: '배',
              translation: 'boat',
              pos: 'nouns',
              sentenceIds: ['sentence-with-audio', 'sentence-without-audio'],
            ),
          ],
        );
        SharedPreferences.setMockInitialValues({
          'lingua_srs_windows_legacy_migration_complete': true,
          'lingua_srs_lessons': jsonEncode([lesson.toJson()]),
          'lingua_srs_sentences': jsonEncode([
            Sentence(
              id: 'sentence-without-audio',
              targetText: '저는 배를 탔어요',
              translationText: 'I took the boat.',
              lessonId: lesson.id,
            ).toJson(),
            Sentence(
              id: 'sentence-with-audio',
              targetText: '저는 **배**를 탔어요',
              translationText: 'I took the **boat**.',
              audioUrl: 'https://example.com/sentence.mp3',
              lessonId: lesson.id,
            ).toJson(),
          ]),
        });

        final provider = AppProvider();
        while (provider.isLoading) {
          await Future<void>.delayed(Duration.zero);
        }

        expect(provider.sentences, hasLength(1));
        expect(provider.sentences.single.id, 'sentence-with-audio');
        expect(
          provider.sentences.single.audioUrl,
          'https://example.com/sentence.mp3',
        );
        expect(provider.lessons.single.vocabularies[0].sentenceIds, [
          'sentence-with-audio',
        ]);
        expect(provider.lessons.single.vocabularies[1].sentenceIds, [
          'sentence-with-audio',
        ]);

        provider.dispose();
      },
    );

    test(
      'Reimport updates matching vocabulary and preserves SRS progress',
      () async {
        SharedPreferences.setMockInitialValues({
          'lingua_srs_windows_legacy_migration_complete': true,
          'lingua_srs_lessons': jsonEncode([
            Lesson(
              id: 'existing-lesson',
              title: 'Unit 2::Lesson 26',
              vocabularies: [
                VocabItem(
                  targetWord: '목적지',
                  translation: 'destination',
                  pos: 'nouns',
                  sentenceIds: ['old-sentence'],
                  cardTargetToNative: SrsCard(
                    id: 'reviewed-card',
                    direction: CardDirection.targetToNative,
                    repetitions: 3,
                    interval: 6,
                    status: SrsStatus.review,
                  ),
                ),
                VocabItem(
                  targetWord: '사용자 단어',
                  translation: 'custom word',
                  pos: 'nouns',
                  cardTargetToNative: SrsCard(
                    id: 'custom-card',
                    direction: CardDirection.targetToNative,
                    repetitions: 2,
                    interval: 4,
                    status: SrsStatus.review,
                  ),
                ),
              ],
            ).toJson(),
          ]),
          'lingua_srs_sentences': jsonEncode([
            Sentence(
              id: 'old-sentence',
              targetText: 'old example',
              translationText: 'old translation',
              lessonId: 'existing-lesson',
            ).toJson(),
          ]),
        });

        final provider = AppProvider();
        while (provider.isLoading) {
          await Future<void>.delayed(Duration.zero);
        }

        const frontmatter = r'''
---
vocabulary:
  nouns:
    - ko: 목적지
      audio: https://example.com/Lesson26v6.mp3
      en: destination
      examples:
        - ko: 우리가 **목적지**에 거의 도착했어요
          en: We have almost arrived at our **destination**
---
# Lesson 26: Describing Nouns with Verbs
''';
        final imported = await provider.importYaml(
          frontmatter,
          defaultUnitTitle: 'Unit 2',
        );

        expect(provider.lessons, hasLength(1));
        expect(imported.id, 'existing-lesson');
        expect(imported.unitTitle, 'Unit 2');
        expect(imported.displayTitle, 'Lesson 26: Describing Nouns with Verbs');
        expect(imported.vocabularies, hasLength(2));
        final refreshedVocab = imported.vocabularies.firstWhere(
          (vocab) => vocab.targetWord == '목적지',
        );
        final customVocab = imported.vocabularies.firstWhere(
          (vocab) => vocab.targetWord == '사용자 단어',
        );
        expect(refreshedVocab.audioUrl, 'https://example.com/Lesson26v6.mp3');
        expect(refreshedVocab.cardTargetToNative.id, 'reviewed-card');
        expect(refreshedVocab.cardTargetToNative.repetitions, 3);
        expect(refreshedVocab.cardTargetToNative.status, SrsStatus.review);
        expect(refreshedVocab.cardTargetToNative.isEnabled, isTrue);
        expect(customVocab.cardTargetToNative.repetitions, 2);
        expect(customVocab.cardTargetToNative.id, 'custom-card');
        expect(provider.sentences, hasLength(2));
        expect(
          provider.sentences.any((sentence) => sentence.id == 'old-sentence'),
          isTrue,
        );
        expect(provider.getSentencesForVocab(refreshedVocab), hasLength(1));

        final refreshedAgain = await provider.importYaml(
          frontmatter,
          defaultUnitTitle: 'Unit 2',
        );
        expect(provider.lessons, hasLength(1));
        expect(refreshedAgain.vocabularies, hasLength(2));
        expect(provider.sentences, hasLength(2));
        expect(refreshedVocab.cardTargetToNative.repetitions, 3);

        provider.dispose();
      },
    );

    test('Shared vocabulary IDs reuse SRS cards across lessons', () async {
      SharedPreferences.setMockInitialValues({
        'lingua_srs_windows_legacy_migration_complete': true,
        'lingua_srs_lessons': '[]',
        'lingua_srs_sentences': '[]',
      });
      final provider = AppProvider();
      while (provider.isLoading) {
        await Future<void>.delayed(Duration.zero);
      }

      const first = '''
---
vocabulary:
  nouns:
    - ko: 배
      en: pear
---
# Lesson 1: Local
''';
      const second = '''
---
vocabulary:
  fruit:
    - ko: 배
      en: pear
  transport:
    - ko: 배
      en: boat
---
# Lesson 2: Shared Word
''';
      final firstLesson = await provider.importYaml(first);
      final firstVocab = firstLesson.vocabularies.single;
      firstVocab.cardTargetToNative.repetitions = 5;
      firstVocab.cardTargetToNative.status = SrsStatus.review;
      final secondLesson = await provider.importYaml(second);

      final shared = secondLesson.vocabularies
          .where((vocab) => vocab.translation == 'pear')
          .toList();
      final distinctMeaning = secondLesson.vocabularies.singleWhere(
        (vocab) => vocab.translation == 'boat',
      );
      expect(shared, hasLength(1));
      expect(
        identical(
          firstVocab.cardTargetToNative,
          shared.single.cardTargetToNative,
        ),
        isTrue,
      );
      expect(shared.single.cardTargetToNative.repetitions, 5);
      expect(distinctMeaning.id, isNot(shared.single.id));
      expect(provider.getStudyQueue(dueOnly: false), hasLength(2));
      provider.dispose();
    });

    test(
      'Batch import persists lessons and preserves shared SRS progress',
      () async {
        SharedPreferences.setMockInitialValues({
          'lingua_srs_windows_legacy_migration_complete': true,
          'lingua_srs_lessons': '[]',
          'lingua_srs_sentences': '[]',
        });
        final provider = AppProvider();
        while (provider.isLoading) {
          await Future<void>.delayed(Duration.zero);
        }
        var notificationCount = 0;
        provider.addListener(() => notificationCount++);

        final first = YamlParserService.parseLessonYaml('''
---
vocabulary:
  fruit:
    - ko: 배
      en: pear
---
# Lesson 1: Fruit
''');
        first.lesson.vocabularies.single.cardTargetToNative
          ..repetitions = 4
          ..status = SrsStatus.review;
        final second = YamlParserService.parseLessonYaml('''
---
vocabulary:
  food:
    - ko: 배
      en: pear
---
# Lesson 2: Food
''');

        final imported = await provider.importParsedLessons([first, second]);

        expect(imported, hasLength(2));
        expect(provider.lessons, hasLength(2));
        expect(
          identical(
            imported.first.vocabularies.single.cardTargetToNative,
            imported.last.vocabularies.single.cardTargetToNative,
          ),
          isTrue,
        );
        expect(
          imported.last.vocabularies.single.cardTargetToNative.repetitions,
          4,
        );
        expect(notificationCount, 1);
        provider.dispose();
      },
    );

    test(
      'App Markdown edits do not change imported source fingerprints',
      () async {
        SharedPreferences.setMockInitialValues({
          'lingua_srs_windows_legacy_migration_complete': true,
          'lingua_srs_lessons': '[]',
          'lingua_srs_sentences': '[]',
        });
        final provider = AppProvider();
        while (provider.isLoading) {
          await Future<void>.delayed(Duration.zero);
        }
        final importedSource = YamlParserService.parseLessonYaml('''
---
vocabulary:
  fruit:
    - ko: 배
      en: pear
---
# Lesson 1: Fruit
''');
        final lesson = (await provider.importParsedLessons([importedSource]))
            .single;
        await StorageService.saveImportedMarkdownSources({
          r'c:\lessons\fruit.md': 'source-fingerprint',
        });

        await provider.updateLessonMarkdown(lesson.id, '# Edited in the app');

        expect(await StorageService.loadImportedMarkdownSources(), {
          r'c:\lessons\fruit.md': 'source-fingerprint',
        });
        expect(provider.lessons.single.markdownContent, '# Edited in the app');
        provider.dispose();
      },
    );

    test(
      'Deleting a section removes descendants and resets shared progress',
      () async {
        SharedPreferences.setMockInitialValues({
          'lingua_srs_windows_legacy_migration_complete': true,
          'lingua_srs_lessons': '[]',
          'lingua_srs_sentences': '[]',
        });
        final provider = AppProvider();
        while (provider.isLoading) {
          await Future<void>.delayed(Duration.zero);
        }

        const frontmatter = '''
---
vocabulary:
  fruit:
    Local:
      Berries:
        Fresh:
          - ko: 배
            en: pear
          - ko: 딸기
            en: strawberry
  examples:
    - ko: 배
      en: pear
---
# Lesson 3: Deletion
''';
        final lesson = await provider.importYaml(frontmatter);
        final sharedVocab = lesson.vocabularies;
        expect(sharedVocab, hasLength(3));
        final sibling = sharedVocab.last;
        sibling.cardTargetToNative.repetitions = 4;
        sibling.cardTargetToNative.status = SrsStatus.review;

        await provider.deleteSection(lesson.id, ['FRUIT']);
        expect(lesson.vocabularies, hasLength(1));
        expect(lesson.vocabularies.single, same(sibling));
        expect(sibling.cardTargetToNative.repetitions, 0);
        expect(sibling.cardTargetToNative.status, SrsStatus.isNew);
        provider.dispose();
      },
    );

    test('Deleting a lesson group removes all lessons in that group', () async {
      SharedPreferences.setMockInitialValues({
        'lingua_srs_windows_legacy_migration_complete': true,
        'lingua_srs_lessons': '[]',
        'lingua_srs_sentences': '[]',
      });
      final provider = AppProvider();
      while (provider.isLoading) {
        await Future<void>.delayed(Duration.zero);
      }
      final first = await provider.importYaml(
        'Lesson: Lesson 1\nnouns:\n  - ko: 하나\n    en: one',
        defaultUnitTitle: 'Unit 1',
      );
      await provider.importYaml(
        'Lesson: Lesson 2\nnouns:\n  - ko: 둘\n    en: two',
        defaultUnitTitle: 'UNIT 1',
      );
      final remaining = await provider.importYaml(
        'Lesson: Theme 1\nnouns:\n  - ko: 셋\n    en: three',
        defaultUnitTitle: 'Theme',
      );
      expect(provider.lessons, hasLength(3));

      await provider.deleteLessonGroup(['unit 1']);

      expect(provider.lessons, hasLength(1));
      expect(provider.lessons.single, same(remaining));
      expect(provider.lessons.any((lesson) => lesson.id == first.id), isFalse);
      provider.dispose();
    });

    test('Resetting a lesson group resets nested lessons only', () async {
      SharedPreferences.setMockInitialValues({
        'lingua_srs_windows_legacy_migration_complete': true,
        'lingua_srs_lessons': '[]',
        'lingua_srs_sentences': '[]',
      });
      final provider = AppProvider();
      while (provider.isLoading) {
        await Future<void>.delayed(Duration.zero);
      }
      final directLesson = await provider.importYaml(
        'Lesson: Direct\nnouns:\n  - ko: 하나\n    en: one',
        defaultUnitTitle: 'Unit 1',
      );
      final nestedLesson = await provider.importYaml(
        'Lesson: Nested\nnouns:\n  - ko: 둘\n    en: two',
        defaultUnitTitle: 'Unit 1::Nested',
      );
      final otherLesson = await provider.importYaml(
        'Lesson: Other\nnouns:\n  - ko: 셋\n    en: three',
        defaultUnitTitle: 'Unit 10',
      );

      for (final lesson in provider.lessons) {
        for (final vocab in lesson.vocabularies) {
          for (final card in [
            vocab.cardTargetToNative,
            vocab.cardNativeToTarget,
          ]) {
            card
              ..repetitions = 4
              ..interval = 6
              ..status = SrsStatus.review;
          }
        }
      }

      await provider.resetLessonGroupSrs(['unit 1']);

      for (final lesson in [directLesson, nestedLesson]) {
        final cards = [
          lesson.vocabularies.single.cardTargetToNative,
          lesson.vocabularies.single.cardNativeToTarget,
        ];
        for (final card in cards) {
          expect(card.repetitions, 0);
          expect(card.interval, 0);
          expect(card.status, SrsStatus.isNew);
        }
      }
      expect(otherLesson.vocabularies.single.cardTargetToNative.repetitions, 4);
      expect(otherLesson.vocabularies.single.cardNativeToTarget.repetitions, 4);

      final reloadedProvider = AppProvider();
      while (reloadedProvider.isLoading) {
        await Future<void>.delayed(Duration.zero);
      }
      final reloadedNested = reloadedProvider.lessons.singleWhere(
        (lesson) => lesson.id == nestedLesson.id,
      );
      expect(
        reloadedNested.vocabularies.single.cardTargetToNative.status,
        SrsStatus.isNew,
      );
      provider.dispose();
      reloadedProvider.dispose();
    });

    test(
      'Moving lessons and nested folders preserves their hierarchy',
      () async {
        SharedPreferences.setMockInitialValues({
          'lingua_srs_windows_legacy_migration_complete': true,
          'lingua_srs_lessons': '[]',
          'lingua_srs_sentences': '[]',
        });
        final provider = AppProvider();
        while (provider.isLoading) {
          await Future<void>.delayed(Duration.zero);
        }

        final movedLesson = await provider.importYaml(
          'Lesson: Lesson A\nnouns: []',
          defaultUnitTitle: 'Topic::Subtopic',
        );
        final nestedLesson = await provider.importYaml(
          'Lesson: Lesson B\nnouns: []',
          defaultUnitTitle: 'Topic::Subtopic::Inner',
        );
        await provider.setLessonFolderExpanded('folder:topic::subtopic', false);
        await provider.setLessonFolderExpanded(
          'folder:topic::subtopic::inner',
          true,
        );

        await provider.moveLessonToFolder(movedLesson.id, ['Other']);
        expect(movedLesson.folderPath, ['Other']);

        await provider.moveLessonGroup(['Topic', 'Subtopic'], ['Destination']);

        expect(movedLesson.folderPath, ['Other']);
        expect(nestedLesson.folderPath, ['Destination', 'Subtopic', 'Inner']);
        expect(
          provider.lessonFolderExpansion['folder:destination::subtopic'],
          isFalse,
        );
        expect(
          provider.lessonFolderExpansion['folder:destination::subtopic::inner'],
          isTrue,
        );
        await expectLater(
          provider.moveLessonGroup(
            ['Destination', 'Subtopic'],
            ['Destination', 'Subtopic', 'Inner'],
          ),
          throwsArgumentError,
        );

        final reloadedProvider = AppProvider();
        while (reloadedProvider.isLoading) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(
          reloadedProvider.lessons
              .singleWhere((lesson) => lesson.id == nestedLesson.id)
              .folderPath,
          ['Destination', 'Subtopic', 'Inner'],
        );
        expect(
          reloadedProvider
              .lessonFolderExpansion['folder:destination::subtopic'],
          isFalse,
        );
        provider.dispose();
        reloadedProvider.dispose();
      },
    );

    test('Markdown imports require and read only vocabulary frontmatter', () {
      expect(
        YamlParserService.hasVocabularyFrontmatter(
          '---\ntitle: index\n---\n# Index',
        ),
        isFalse,
      );
      expect(
        () => YamlParserService.parseLessonYaml(
          '---\ntitle: index\n---\n# Index',
        ),
        throwsFormatException,
      );
    });

    test('Sentence search tokenizes Korean words and common inflections', () {
      expect(
        KoreanTextSearch.matches(
          query: '목적지',
          targetText: '우리가 **목적지**에 거의 도착했어요',
          translationText: 'We have almost arrived at our destination',
        ),
        isTrue,
      );
      expect(
        KoreanTextSearch.matches(
          query: '도착하다',
          targetText: '기차가 곧 도착했어요',
          translationText: 'The train arrived soon',
        ),
        isTrue,
      );
      expect(
        KoreanTextSearch.matches(
          query: '보다',
          targetText: '이 영화를 봤어요',
          translationText: 'I watched this movie',
        ),
        isTrue,
      );
      expect(
        KoreanTextSearch.matches(
          query: '이용하다',
          targetText: '이 서비스를 이용합니다',
          translationText: 'Use this service',
        ),
        isTrue,
      );
      expect(
        KoreanTextSearch.matches(
          query: 'destination',
          targetText: '최종 목적지가 어디예요?',
          translationText: 'Where is your final destination?',
        ),
        isTrue,
      );
      expect(
        KoreanTextSearch.matches(
          query: '학교 복잡하다',
          targetText: '학교에서 공부해요',
          translationText: 'I study at school',
        ),
        isFalse,
      );
    });

    test('Cloze deletion with bold tags', () {
      final sentence = Sentence(
        targetText: '저는 **아줌마**를 위해 문을 열었어요',
        translationText: 'I opened the door for an older lady',
      );

      final cloze = sentence.toCloze(targetWord: '아줌마');
      expect(cloze, '저는 (___)를 위해 문을 열었어요');
    });

    test('Cloze deletion with conjugated verb stems', () {
      final sentence = Sentence(
        targetText: '우리는 공항에 정각에 도착했어요',
        translationText: 'We arrived at the airport on time',
      );

      final cloze = sentence.toCloze(targetWord: '도착하다');
      expect(cloze, '우리는 공항에 정각에 (___)');
    });

    test('Clean text for speech removes markdown', () {
      final raw = '저는 **아줌마**를 위해 [___] 문을 열었어요';
      final clean = Sentence.cleanForSpeech(raw);
      expect(clean, '저는 아줌마를 위해  문을 열었어요');
    });

    test('SRS SM-2 calculations work properly', () {
      final card = SrsCard(direction: CardDirection.targetToNative);
      expect(card.status, SrsStatus.isNew);
      expect(card.repetitions, 0);

      // 1. Good review
      SrsService.processReview(card, SrsRating.good);
      expect(card.repetitions, 1);
      expect(card.interval, 1);
      expect(card.status, SrsStatus.review);

      // 2. Good review again
      SrsService.processReview(card, SrsRating.good);
      expect(card.repetitions, 2);
      expect(card.interval, 6);

      // 3. Again (reset with 1-hour minimum repetition)
      SrsService.processReview(card, SrsRating.again);
      expect(card.repetitions, 0);
      expect(card.interval, 0);
      expect(card.status, SrsStatus.learning);
      expect(card.dueDate.difference(DateTime.now()).inMinutes >= 55, isTrue);
      expect(card.dueDate.difference(DateTime.now()).inMinutes <= 65, isTrue);
    });

    test('Resetting SRS progress keeps card visibility and identity', () {
      final card = SrsCard(
        id: 'card-id',
        direction: CardDirection.nativeToTarget,
        isEnabled: false,
        interval: 10,
        repetitions: 4,
        easeFactor: 2.8,
        dueDate: DateTime(2030),
        lastReviewed: DateTime(2025),
        status: SrsStatus.review,
      );

      card.resetProgress();

      expect(card.id, 'card-id');
      expect(card.direction, CardDirection.nativeToTarget);
      expect(card.isEnabled, isFalse);
      expect(card.interval, 0);
      expect(card.repetitions, 0);
      expect(card.easeFactor, 2.5);
      expect(card.status, SrsStatus.isNew);
      expect(card.lastReviewed, isNull);
      expect(
        card.dueDate.isBefore(DateTime.now().add(const Duration(seconds: 1))),
        isTrue,
      );
    });

    test('Tracks mistakes, lapses, and recent mistakes queue', () {
      final card = SrsCard(direction: CardDirection.targetToNative);
      expect(card.lapses, 0);
      expect(card.lastMistakeDate, isNull);
      expect(card.hasRecentMistake, isFalse);

      SrsService.processReview(card, SrsRating.again);
      expect(card.lapses, 1);
      expect(card.lastMistakeDate, isNotNull);
      expect(card.lastRating, SrsRating.again);
      expect(card.hasRecentMistake, isTrue);

      // Reviewing with Good clears active recent mistake state
      SrsService.processReview(card, SrsRating.good);
      expect(card.lastRating, SrsRating.good);
      expect(card.hasRecentMistake, isFalse);
      expect(card.lapses, 1); // retains total lapse count
    });

    test(
      'AppProvider prioritizes oldest inserted lessons while shuffling by POS',
      () async {
        SharedPreferences.setMockInitialValues({
          'lingua_srs_windows_legacy_migration_complete': true,
          'lingua_srs_lessons': '[]',
        });
        final provider = AppProvider();
        while (provider.isLoading) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        provider.lessons.clear();

        // Create Lesson 1 (older) with nouns and verbs
        final lesson1 = Lesson(title: 'Lesson 1');
        lesson1.vocabularies.addAll([
          VocabItem(targetWord: '사과', translation: 'apple', pos: 'nouns'),
          VocabItem(targetWord: '바나나', translation: 'banana', pos: 'nouns'),
          VocabItem(targetWord: '먹다', translation: 'to eat', pos: 'verbs'),
          VocabItem(targetWord: '마시다', translation: 'to drink', pos: 'verbs'),
        ]);

        // Create Lesson 2 (newer) with adjectives
        final lesson2 = Lesson(title: 'Lesson 2');
        lesson2.vocabularies.addAll([
          VocabItem(targetWord: '크다', translation: 'big', pos: 'adjectives'),
          VocabItem(targetWord: '작다', translation: 'small', pos: 'adjectives'),
        ]);

        provider.lessons.addAll([lesson1, lesson2]);

        final queue = provider.getStudyQueue(dueOnly: false);
        expect(queue, hasLength(6));

        // All cards from Lesson 1 must come before all cards from Lesson 2
        final lesson1Indices = <int>[];
        final lesson2Indices = <int>[];
        for (var i = 0; i < queue.length; i++) {
          if (queue[i].lesson.id == lesson1.id) {
            lesson1Indices.add(i);
          } else if (queue[i].lesson.id == lesson2.id) {
            lesson2Indices.add(i);
          }
        }

        expect(lesson1Indices.length, 4);
        expect(lesson2Indices.length, 2);
        expect(
          lesson1Indices.last < lesson2Indices.first,
          isTrue,
          reason: 'Oldest inserted lessons must be prioritized first',
        );

        // Test Recent Mistakes queue filter
        expect(provider.totalRecentMistakes, 0);
        SrsService.processReview(
          lesson1.vocabularies[0].cardTargetToNative,
          SrsRating.again,
        );
        expect(provider.totalRecentMistakes, 1);

        final mistakesQueue = provider.getRecentMistakesQueue();
        expect(mistakesQueue, hasLength(1));
        expect(mistakesQueue.first.vocab.targetWord, '사과');
      },
    );

    test('Again and Hard repeat in less than 24 hours, and 24h review limit is enforced', () async {
      final now = DateTime.now();

      // 1. Again scheduling
      final againCard = SrsCard(direction: CardDirection.targetToNative);
      SrsService.processReview(againCard, SrsRating.again);
      expect(againCard.interval, 0);
      expect(againCard.status, SrsStatus.learning);
      // Repeating in ~1 hour (less than 24 hours)
      expect(againCard.dueDate.isAfter(now), isTrue);
      expect(againCard.dueDate.difference(now).inHours, 1); // 1 hour difference
      expect(againCard.dueDate.difference(now).inMinutes >= 55, isTrue);
      // Currently scheduled in the future, so not due yet
      expect(againCard.isDue, isFalse);

      // 2. Hard scheduling for learning card
      final hardCard = SrsCard(direction: CardDirection.targetToNative);
      SrsService.processReview(hardCard, SrsRating.hard);
      expect(hardCard.interval, 0);
      expect(
        hardCard.dueDate.difference(now).inHours,
        12,
      ); // 12 hours (less than 24h)
      expect(hardCard.isDue, isFalse);

      // 3. 24-hour review limit in AppProvider
      SharedPreferences.setMockInitialValues({
        'lingua_srs_windows_legacy_migration_complete': true,
        'lingua_srs_lessons': '[]',
        'lingua_srs_max_reviews_24h': 2,
      });

      final provider = AppProvider();
      while (provider.isLoading) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      provider.lessons.clear();

      final lesson = Lesson(title: 'Review Limit Lesson');
      lesson.vocabularies.addAll([
        VocabItem(targetWord: '단어1', translation: 'word 1', pos: 'nouns'),
        VocabItem(targetWord: '단어2', translation: 'word 2', pos: 'nouns'),
        VocabItem(targetWord: '단어3', translation: 'word 3', pos: 'nouns'),
      ]);
      provider.lessons.add(lesson);

      expect(provider.maxReviews24h, 2);
      expect(provider.remainingReviews24h, 2);

      // Only 2 cards should be returned due to the 24h review limit
      final queue = provider.getStudyQueue(dueOnly: true);
      expect(queue, hasLength(2));

      // After 2 reviews, remaining reviews is 0
      await provider.recordCardReview(queue[0].card, SrsRating.good);
      await provider.recordCardReview(queue[1].card, SrsRating.good);
      expect(provider.reviewsInLast24Hours, 2);
      expect(provider.remainingReviews24h, 0);

      // Queue is now empty for due cards
      final emptyDueQueue = provider.getStudyQueue(dueOnly: true);
      expect(emptyDueQueue, isEmpty);

      // But cram mode (dueOnly: false) still allows studying all cards
      final cramQueue = provider.getStudyQueue(dueOnly: false);
      expect(cramQueue, hasLength(3));
    });
  });

  group('Shared vocabulary details across lessons', () {
    Future<AppProvider> newProvider() async {
      SharedPreferences.setMockInitialValues({
        'lingua_srs_windows_legacy_migration_complete': true,
        'lingua_srs_lessons': '[]',
        'lingua_srs_sentences': '[]',
      });
      final provider = AppProvider();
      while (provider.isLoading) {
        await Future<void>.delayed(Duration.zero);
      }
      return provider;
    }

    String lessonYaml(String title, {String? audio, String? notes,
        String? disambiguation}) => '''
---
vocabulary:
  nouns:
    - ko: 배
      en: pear
${audio != null ? '      audio: $audio\n' : ''}${notes != null ? '      notes: $notes\n' : ''}${disambiguation != null ? '      disambiguation: $disambiguation\n' : ''}---
# $title
''';

    VocabItem pear(Lesson lesson) =>
        lesson.vocabularies.firstWhere((v) => v.translation == 'pear');

    Future<AppProvider> reload() async {
      final p = AppProvider();
      while (p.isLoading) {
        await Future<void>.delayed(Duration.zero);
      }
      return p;
    }

    test('Duplicates share one SharedVocab, also after reload', () async {
      final provider = await newProvider();
      final first = await provider.importYaml(lessonYaml('Lesson 1'));
      final second = await provider.importYaml(lessonYaml('Lesson 2'));
      expect(identical(pear(first).shared, pear(second).shared), isTrue);

      final reloaded = await reload();
      expect(
        identical(pear(reloaded.lessons[0]).shared,
            pear(reloaded.lessons[1]).shared),
        isTrue,
      );
      provider.dispose();
      reloaded.dispose();
    });

    test('Owning lesson can still update its audio after reload', () async {
      final provider = await newProvider();
      await provider.importYaml(lessonYaml('Lesson 1', audio: 'https://a/1.mp3'));
      final reloaded = await reload();
      final again = await reloaded.importYaml(
          lessonYaml('Lesson 1', audio: 'https://a/1b.mp3'));
      expect(pear(again).audioUrl, 'https://a/1b.mp3');
      provider.dispose();
      reloaded.dispose();
    });

    test('Manual edit beats later imports', () async {
      final provider = await newProvider();
      final first = await provider.importYaml(
          lessonYaml('Lesson 1', audio: 'https://a/1.mp3'));
      pear(first).audioUrl = 'https://a/manual.mp3';
      await provider.updateVocab(pear(first));
      final again = await provider.importYaml(
          lessonYaml('Lesson 1', audio: 'https://a/1b.mp3'));
      expect(pear(again).audioUrl, 'https://a/manual.mp3');
      expect(pear(again).shared.alternates['audioUrl'], contains('https://a/1b.mp3'));
      provider.dispose();
    });

    test('Manually cleared audio is not refilled by import', () async {
      final provider = await newProvider();
      final first = await provider.importYaml(
          lessonYaml('Lesson 1', audio: 'https://a/1.mp3'));
      pear(first).audioUrl = null;
      await provider.updateVocab(pear(first));
      final second = await provider.importYaml(
          lessonYaml('Lesson 2', audio: 'https://a/2.mp3'));
      expect(pear(second).audioUrl, isNull);
      provider.dispose();
    });

    test('Folder import fills old lessons that were not imported', () async {
      final provider = await newProvider();
      final old = await provider.importYaml(lessonYaml('Old lesson'));
      await provider.importParsedLessons([
        YamlParserService.parseLessonYaml(
            lessonYaml('New 1', audio: 'https://a/new.mp3')),
        YamlParserService.parseLessonYaml(lessonYaml('New 2')),
      ]);
      expect(pear(old).audioUrl, 'https://a/new.mp3');

      final reloaded = await reload();
      expect(pear(reloaded.lessons.first).audioUrl, 'https://a/new.mp3');
      provider.dispose();
      reloaded.dispose();
    });

    test('Folder import never overwrites non-empty audio in old lessons',
        () async {
      final provider = await newProvider();
      final old = await provider.importYaml(
          lessonYaml('Old lesson', audio: 'https://a/old.mp3'));
      await provider.importParsedLessons([
        YamlParserService.parseLessonYaml(
            lessonYaml('New 1', audio: 'https://a/new.mp3')),
      ]);
      expect(pear(old).audioUrl, 'https://a/old.mp3');
      provider.dispose();
    });

    test('Legacy data migrates by recency, not list order', () async {
      final a = Lesson(id: 'a', title: 'Lesson A', vocabularies: [
        VocabItem(id: 'v1', targetWord: '배', translation: 'pear', pos: 'nouns'),
      ]);
      final b = Lesson(id: 'b', title: 'Lesson B', vocabularies: [
        VocabItem(
            id: 'v1',
            targetWord: '배',
            translation: 'pear',
            pos: 'nouns',
            audioUrl: 'https://a/b.mp3'),
      ]);
      b.vocabularies.single.cardTargetToNative
        ..repetitions = 3
        ..status = SrsStatus.review
        ..lastReviewed = DateTime(2026, 10, 1);
      SharedPreferences.setMockInitialValues({
        'lingua_srs_windows_legacy_migration_complete': true,
        'lingua_srs_lessons': jsonEncode([a.toJson(), b.toJson()]),
        'lingua_srs_sentences': '[]',
      });
      final provider = await reload();
      final la = provider.lessons[0].vocabularies.single;
      final lb = provider.lessons[1].vocabularies.single;
      expect(identical(la.shared, lb.shared), isTrue);
      expect(la.audioUrl, 'https://a/b.mp3');
      expect(la.cardTargetToNative.repetitions, 3);
      provider.dispose();
    });

    test('Changing a vocab id splits it off without touching siblings',
        () async {
      final provider = await newProvider();
      final first = await provider.importYaml(
          lessonYaml('Lesson 1', audio: 'https://a/1.mp3'));
      final second = await provider.importYaml(lessonYaml('Lesson 2'));
      final original = pear(first);
      final previousId = original.id;
      original
        ..id = 'custom-pear'
        ..idIsExplicit = true;
      provider.rebindVocabId(original, previousId);
      original.audioUrl = 'https://a/split.mp3';
      await provider.updateVocab(original, previousId: previousId);

      expect(pear(second).audioUrl, 'https://a/1.mp3');
      expect(
        identical(pear(first).cardTargetToNative, pear(second).cardTargetToNative),
        isFalse,
      );
      provider.dispose();
    });

    String adjYaml(String title, String ko, String en, {String? audio}) => '''
---
vocabulary:
  adjectives:
    - ko: $ko
      en: $en
${audio != null ? '      audio: $audio\n' : ''}---
# $title
''';

    VocabItem only(Lesson lesson) => lesson.vocabularies.single;

    group('Vocabulary merging', () {
      late AppProvider provider;
      late Lesson l1;
      late Lesson l2;

      setUp(() async {
        provider = await newProvider();
        l1 = await provider.importYaml(adjYaml('Lesson 1', '아름답다', 'beautiful'));
        l2 = await provider.importYaml(
            adjYaml('Lesson 2', '아름답다', 'to be beautiful', audio: 'https://a/2.mp3'));
      });
      tearDown(() => provider.dispose());

      test('different ids before the merge', () {
        expect(only(l1).id, isNot(only(l2).id));
      });

      test('merge shares progress and details, survivor progress wins', () async {
        only(l1).cardTargetToNative.repetitions = 3;
        final record = await provider.mergeVocab(
          survivorId: only(l1).id,
          absorbedIds: [only(l2).id],
        );
        expect(record, isNotNull);
        expect(only(l2).id, only(l1).id);
        expect(only(l2).idIsExplicit, isTrue);
        expect(identical(only(l1).shared, only(l2).shared), isTrue);
        expect(only(l2).cardTargetToNative.repetitions, 3);
        expect(only(l1).audioUrl, 'https://a/2.mp3'); // blank survivor filled
        expect(only(l2).translation, 'to be beautiful'); // wording kept
      });

      test('merging nothing or an unknown survivor', () async {
        expect(await provider.mergeVocab(survivorId: only(l1).id, absorbedIds: [only(l1).id]), isNull);
        expect(await provider.mergeVocab(survivorId: only(l1).id, absorbedIds: ['zzz']), isNull);
        expect(() => provider.mergeVocab(survivorId: 'zzz', absorbedIds: [only(l1).id]),
            throwsArgumentError);
      });

      test('merge survives reload and re-import', () async {
        await provider.mergeVocab(survivorId: only(l1).id, absorbedIds: [only(l2).id]);
        final reloaded = await reload();
        expect(identical(only(reloaded.lessons[0]).shared, only(reloaded.lessons[1]).shared), isTrue);

        final again = await reloaded.importYaml(adjYaml('Lesson 2', '아름답다', 'to be beautiful'));
        expect(only(again).id, only(reloaded.lessons[0]).id);
        reloaded.dispose();
      });

      test('a new lesson with the merged-away wording joins the group', () async {
        await provider.mergeVocab(survivorId: only(l1).id, absorbedIds: [only(l2).id]);
        final l3 = await provider.importYaml(adjYaml('Lesson 3', '아름답다', 'to be beautiful'));
        expect(only(l3).id, only(l1).id);
        expect(identical(only(l3).shared, only(l1).shared), isTrue);
      });

      test('undo restores ids, separate progress and survivor details', () async {
        final survivorId = only(l1).id;
        final absorbedId = only(l2).id;
        only(l2).cardTargetToNative.repetitions = 2;
        final record = (await provider.mergeVocab(
          survivorId: survivorId,
          absorbedIds: [absorbedId],
        ))!;
        final result = await provider.undoMerge(record.id);

        expect(result.restored, 1);
        expect(result.missing, 0);
        expect(only(l2).id, absorbedId);
        expect(only(l2).idIsExplicit, isFalse);
        expect(identical(only(l1).shared, only(l2).shared), isFalse);
        expect(only(l2).cardTargetToNative.repetitions, 2);
        expect(only(l1).audioUrl, isNull);
        expect(provider.mergeHistory, isEmpty);
      });

      test('undo keeps details edited after the merge', () async {
        final record = (await provider.mergeVocab(
          survivorId: only(l1).id,
          absorbedIds: [only(l2).id],
        ))!;
        only(l1).audioUrl = 'https://a/manual.mp3';
        await provider.undoMerge(record.id);
        expect(only(l1).audioUrl, 'https://a/manual.mp3');
      });

      test('undo is last-in-first-out', () async {
        final l3 = await provider.importYaml(adjYaml('Lesson 3', '아름답다', 'lovely'));
        final first = (await provider.mergeVocab(
          survivorId: only(l1).id, absorbedIds: [only(l2).id]))!;
        await provider.mergeVocab(survivorId: only(l1).id, absorbedIds: [only(l3).id]);
        await expectLater(provider.undoMerge(first.id), throwsStateError);
      });

      test('undo reports entries that no longer exist', () async {
        final record = (await provider.mergeVocab(
          survivorId: only(l1).id, absorbedIds: [only(l2).id]))!;
        await provider.deleteVocab(l2.id, only(l2));
        final result = await provider.undoMerge(record.id);
        expect(result.restored, 0);
        expect(result.missing, 1);
      });

      test('merge history survives reload and can be undone', () async {
        await provider.mergeVocab(survivorId: only(l1).id, absorbedIds: [only(l2).id]);
        final reloaded = await reload();
        expect(reloaded.mergeHistory, hasLength(1));
        final result = await reloaded.undoMerge(reloaded.mergeHistory.single.id);
        expect(result.restored, 1);
        reloaded.dispose();
      });
    });

    group('AI assistance', () {
      http.Response ok(Object content) => http.Response(
        jsonEncode({'choices': [{'message': {'content': jsonEncode(content)}}]}),
        200,
      );

      test('canUseAi follows the key and a rejected key', () async {
        final provider = await newProvider();
        expect(provider.canUseAi, isFalse);
        await provider.setDeepSeekApiKey('k');
        expect(provider.canUseAi, isTrue);

        final client = MockClient((_) async => http.Response('bad', 401));
        await expectLater(provider.suggestVocabMerges(client: client), completion(isEmpty));
        // no candidate groups yet, so no request was made and the key stays valid
        expect(provider.canUseAi, isTrue);

        await provider.importYaml(adjYaml('L1', '아름답다', 'beautiful'));
        await provider.importYaml(adjYaml('L2', '아름답다', 'to be beautiful'));
        await expectLater(
          provider.suggestVocabMerges(client: client),
          throwsA(isA<DeepSeekException>()),
        );
        expect(provider.canUseAi, isFalse);

        await provider.setDeepSeekApiKey('new-key');
        expect(provider.canUseAi, isTrue);
        provider.dispose();
      });

      test('suggestEnKoHint feeds all same-POS vocab and maps numbers back', () async {
        final provider = await newProvider();
        await provider.setDeepSeekApiKey('k');
        final big = await provider.importYaml(adjYaml('L1', '크다', 'big'));
        final wide = await provider.importYaml(adjYaml('L2', '넓다', 'wide'));
        await provider.importYaml(adjYaml('L3', '작다', 'small'));
        await provider.importYaml(adjYaml('L4', '크다', 'to be big')); // same form
        await provider.importYaml('''
---
vocabulary:
  nouns:
    - ko: 배
      en: pear
---
# L5
''');

        final client = MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final user = jsonDecode((body['messages'] as List)[1]['content'] as String)
              as Map<String, dynamic>;
          final pool = user['pool'] as String;
          expect(pool, contains('1|넓다|wide'));
          expect(pool, contains('2|작다|small'));
          expect(pool, isNot(contains('pear')));
          expect(pool, isNot(contains('to be big')));
          expect(pool, isNot(contains('auto-')));
          return ok({'hint': 'general size', 'similar': [{'n': 1, 'hint': 'area or width'}]});
        });

        final result = await provider.suggestEnKoHint(only(big), client: client);
        expect(result.hint, 'general size');
        expect(result.similar.single.id, only(wide).id);
        provider.dispose();
      });

      test('suggestKoEnHint sends only same-spelling entries', () async {
        final provider = await newProvider();
        await provider.setDeepSeekApiKey('k');
        final pear = await provider.importYaml(lessonYaml('L1')); // 배 / pear
        await provider.importYaml('''
---
vocabulary:
  nouns:
    - ko: 배
      en: stomach
---
# L2
''');
        await provider.importYaml(adjYaml('L3', '크다', 'big'));

        final client = MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final user = jsonDecode((body['messages'] as List)[1]['content'] as String)
              as Map<String, dynamic>;
          expect(user['others'], '1|nouns|stomach');
          expect(request.body, isNot(contains('크다')));
          return ok({'hint': 'fruit', 'similar': [{'n': 1, 'hint': 'body part'}]});
        });

        final result = await provider.suggestKoEnHint(only(pear), client: client);
        expect(result.hint, 'fruit');
        expect(result.similar.single.hint, 'body part');
        provider.dispose();
      });

      test('suggestKoEnHint makes no request when nothing shares the spelling',
          () async {
        final provider = await newProvider();
        await provider.setDeepSeekApiKey('k');
        final big = await provider.importYaml(adjYaml('L1', '크다', 'big'));
        final client = MockClient((_) async {
          fail('no request expected');
        });
        final result = await provider.suggestKoEnHint(only(big), client: client);
        expect(result.hint, '');
        expect(result.similar, isEmpty);
        provider.dispose();
      });

      test('both hint suggestions report an auth failure', () async {
        final provider = await newProvider();
        await provider.setDeepSeekApiKey('k');
        final big = await provider.importYaml(adjYaml('L1', '크다', 'big'));
        await provider.importYaml(adjYaml('L2', '넓다', 'wide'));
        final client = MockClient((_) async => http.Response('bad', 401));
        await expectLater(
          provider.suggestEnKoHint(only(big), client: client),
          throwsA(isA<DeepSeekException>()),
        );
        expect(provider.canUseAi, isFalse);
        provider.dispose();
      });

      test('applyFrontHints is per direction, fills only blanks, and persists',
          () async {
        final provider = await newProvider();
        final a = await provider.importYaml(adjYaml('L1', '크다', 'big'));
        final b = await provider.importYaml(adjYaml('L2', '넓다', 'wide'));
        final aAgain = await provider.importYaml(adjYaml('L3', '크다', 'big'));
        only(b).cardNativeToTarget.frontHint = 'existing';

        final changed = await provider.applyFrontHints(
          {only(a).id: 'general size', only(b).id: 'ignored'},
          CardDirection.nativeToTarget,
        );

        expect(changed, 1);
        expect(only(a).cardNativeToTarget.frontHint, 'general size');
        expect(only(aAgain).cardNativeToTarget.frontHint, 'general size'); // same id
        expect(only(a).cardTargetToNative.frontHint, '');                  // other direction
        expect(only(b).cardNativeToTarget.frontHint, 'existing');

        final reloaded = await reload();
        expect(only(reloaded.lessons[0]).cardNativeToTarget.frontHint, 'general size');
        provider.dispose();
        reloaded.dispose();
      });

      test('AI calls are refused without a key', () async {
        final provider = await newProvider();
        await expectLater(provider.suggestVocabMerges(), throwsStateError);
        provider.dispose();
      });
    });

    test('Later duplicate inherits audio from the earlier lesson', () async {
      final provider = await newProvider();
      await provider.importYaml(lessonYaml('Lesson 1', audio: 'https://a/1.mp3'));
      final second = await provider.importYaml(lessonYaml('Lesson 2'));

      expect(pear(second).audioUrl, 'https://a/1.mp3');
      provider.dispose();
    });

    test('Earlier duplicate receives audio supplied by a later lesson', () async {
      final provider = await newProvider();
      final first = await provider.importYaml(lessonYaml('Lesson 1'));
      await provider.importYaml(lessonYaml('Lesson 2', audio: 'https://a/2.mp3'));

      expect(pear(first).audioUrl, 'https://a/2.mp3');
      provider.dispose();
    });

    test('Filled details survive a reload', () async {
      final provider = await newProvider();
      await provider.importYaml(lessonYaml('Lesson 1', audio: 'https://a/1.mp3'));
      await provider.importYaml(lessonYaml('Lesson 2'));

      final reloaded = AppProvider();
      while (reloaded.isLoading) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(reloaded.lessons.map((l) => pear(l).audioUrl),
          everyElement('https://a/1.mp3'));
      provider.dispose();
      reloaded.dispose();
    });

    test('Re-import without audio does not erase existing audio', () async {
      final provider = await newProvider();
      await provider.importYaml(lessonYaml('Lesson 1', audio: 'https://a/1.mp3'));
      final again = await provider.importYaml(lessonYaml('Lesson 1'));

      expect(pear(again).audioUrl, 'https://a/1.mp3');
      provider.dispose();
    });

    test('Progress stays shared while details sync', () async {
      final provider = await newProvider();
      final first = await provider.importYaml(lessonYaml('Lesson 1'));
      final second = await provider.importYaml(
          lessonYaml('Lesson 2', audio: 'https://a/2.mp3'));

      expect(identical(pear(first).cardTargetToNative,
          pear(second).cardTargetToNative), isTrue);
      provider.dispose();
    });

    test('addVocabToLesson fills details from an existing duplicate', () async {
      final provider = await newProvider();
      await provider.importYaml(lessonYaml('Lesson 1', audio: 'https://a/1.mp3'));
      final other = await provider.importYaml('''
---
vocabulary:
  nouns:
    - ko: 사과
      en: apple
---
# Lesson 2
''');
      final added = VocabItem(targetWord: '배', translation: 'pear', pos: 'nouns');
      await provider.addVocabToLesson(other.id, added);

      expect(added.audioUrl, 'https://a/1.mp3');
      provider.dispose();
    });

    test('Batch import fills details through importParsedLessons', () async {
      final provider = await newProvider();
      final results = await provider.importParsedLessons([
        YamlParserService.parseLessonYaml(
            lessonYaml('Lesson 1', audio: 'https://a/1.mp3')),
        YamlParserService.parseLessonYaml(lessonYaml('Lesson 2')),
      ]);

      expect(pear(results[1]).audioUrl, 'https://a/1.mp3');
      provider.dispose();
    });
  });

  group('Per-direction front hints', () {
    test('SrsCard frontHint round-trips and defaults to empty', () {
      final card = SrsCard(direction: CardDirection.nativeToTarget, frontHint: 'area or width');
      expect(SrsCard.fromJson(card.toJson()).frontHint, 'area or width');
      final legacy = card.toJson()..remove('frontHint');
      expect(SrsCard.fromJson(legacy).frontHint, '');
    });

    test('resetProgress keeps the hint', () {
      final card = SrsCard(direction: CardDirection.targetToNative, frontHint: 'fruit')
        ..repetitions = 4;
      card.resetProgress();
      expect(card.repetitions, 0);
      expect(card.frontHint, 'fruit');
    });

    test('frontHintFor prefers the direction hint, else the general one', () {
      final vocab = VocabItem(
        targetWord: '배', translation: 'pear', pos: 'nouns', disambiguation: 'general');
      expect(vocab.frontHintFor(CardDirection.targetToNative), 'general');
      vocab.cardTargetToNative.frontHint = 'fruit';
      expect(vocab.frontHintFor(CardDirection.targetToNative), 'fruit');
      expect(vocab.frontHintFor(CardDirection.nativeToTarget), 'general');
    });
  });

}
