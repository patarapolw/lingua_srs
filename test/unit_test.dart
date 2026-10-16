import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/lesson.dart';
import 'package:lingua_srs/models/srs_card.dart';
import 'package:lingua_srs/models/sentence.dart';
import 'package:lingua_srs/models/vocab_item.dart';
import 'package:lingua_srs/providers/app_provider.dart';
import 'package:lingua_srs/services/korean_text_search.dart';
import 'package:lingua_srs/services/yaml_parser_service.dart';
import 'package:lingua_srs/services/srs_service.dart';
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
Lesson: Unit 2/Lesson 26

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
      expect(res.lesson.title, 'Unit 2/Lesson 26');
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

    test('Splits legacy Unit/Lesson title into hierarchy display fields', () {
      final lesson = YamlParserService.parseLessonYaml(sampleYaml).lesson;

      expect(lesson.title, 'Unit 2/Lesson 26');
      expect(lesson.effectiveUnitTitle, 'Unit 2');
      expect(lesson.displayTitle, 'Lesson 26');
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
              title: 'Unit 2/Lesson 26',
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

      await provider.deleteLessonGroup('unit 1');

      expect(provider.lessons, hasLength(1));
      expect(provider.lessons.single, same(remaining));
      expect(provider.lessons.any((lesson) => lesson.id == first.id), isFalse);
      provider.dispose();
    });

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
}
