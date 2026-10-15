import 'dart:convert';

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
      - ko: 배
        en: pear
  examples:
    - ko: 배
      en: pear
---
# Lesson 3: Deletion
''';
        final lesson = await provider.importYaml(frontmatter);
        final sharedVocab = lesson.vocabularies;
        expect(sharedVocab, hasLength(2));
        final sibling = sharedVocab.last;
        sibling.cardTargetToNative.repetitions = 4;
        sibling.cardTargetToNative.status = SrsStatus.review;

        await provider.deleteSection(lesson.id, ['fruit']);
        expect(lesson.vocabularies, hasLength(1));
        expect(lesson.vocabularies.single, same(sibling));
        expect(sibling.cardTargetToNative.repetitions, 0);
        expect(sibling.cardTargetToNative.status, SrsStatus.isNew);
        provider.dispose();
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

      // 3. Again (reset)
      SrsService.processReview(card, SrsRating.again);
      expect(card.repetitions, 0);
      expect(card.interval, 1);
      expect(card.status, SrsStatus.learning);
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
  });
}
