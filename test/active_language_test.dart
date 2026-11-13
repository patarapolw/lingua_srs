import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/lesson.dart';
import 'package:lingua_srs/models/sentence.dart';
import 'package:lingua_srs/models/srs_card.dart';
import 'package:lingua_srs/providers/app_provider.dart';
import 'package:lingua_srs/services/audio_service.dart';
import 'package:lingua_srs/services/tts_voice.dart';
import 'package:lingua_srs/views/vocab_pool_view.dart';
import 'package:lingua_srs/widgets/language_selector.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'secret_storage_mock.dart';

/// The tabs must not touch real audio plugins.
class _FakeAudioService extends ChangeNotifier implements AudioService {
  @override
  TtsVoiceUsed? get lastVoice => null;
  @override
  bool get isPlaying => false;
  @override
  String? get currentlyPlayingKey => null;
  @override
  bool get usesOfflineTts => true;
  @override
  Future<void> stop() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

const _korean = '''
---
vocabulary:
  nouns:
    - ko: 학생
      en: student
      examples:
        - ko: 저는 **학생**이에요.
          en: I am a **student**.
---
# Korean 1
''';

const _taiwan = '''
---
target: zh-TW
vocabulary:
  nouns:
    - zh: 學生
      en: student
      examples:
        - zh: 我是**學生**。
          en: I am a **student**.
    - zh: 老師
      en: teacher
---
# Taiwan 1
''';

const _mainland = '''
---
target: zh-CN
vocabulary:
  nouns:
    - zh: 学生
      en: student
---
# Mainland 1
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(setUpSecretStorage);

  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory storageDirectory;

  setUp(() {
    storageDirectory = Directory.systemTemp.createTempSync(
      'lingua_srs_active_language_test_',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (call) async {
          if (call.method == 'getApplicationSupportDirectory') {
            return storageDirectory.path;
          }
          throw MissingPluginException('Unexpected method: ${call.method}');
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    if (storageDirectory.existsSync()) {
      await storageDirectory.delete(recursive: true);
    }
  });

  Future<AppProvider> loadedProvider(
    WidgetTester tester, [
    Map<String, Object> prefs = const {},
  ]) async {
    SharedPreferences.setMockInitialValues({
      'lingua_srs_windows_legacy_migration_complete': true,
      ...prefs,
    });
    final provider = AppProvider();
    addTearDown(provider.dispose);
    for (var i = 0; i < 100 && provider.isLoading; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(provider.isLoading, isFalse, reason: 'provider never loaded');
    return provider;
  }

  Future<void> import(
    WidgetTester tester,
    AppProvider provider,
    String yaml,
  ) async {
    await tester.runAsync(() => provider.importYaml(yaml));
  }

  List<String> titles(Iterable<Lesson> lessons) => [
    for (final lesson in lessons) lesson.displayTitle,
  ];

  test('languageKey tells regions apart and drops one that adds nothing', () {
    expect(Lesson(title: 'L').languageKey, 'ko');
    expect(Lesson(title: 'L', targetLanguage: 'ko-KR').languageKey, 'ko');
    expect(Lesson(title: 'L', targetLanguage: 'zh_TW').languageKey, 'zh-tw');
    expect(Lesson(title: 'L', targetLanguage: 'zh-CN').languageKey, 'zh-cn');
    expect(Lesson(title: 'L', targetLanguage: 'ZH').languageKey, 'zh');
  });

  group('one language', () {
    testWidgets('shows every lesson, with nothing to pick', (tester) async {
      final provider = await loadedProvider(tester);
      expect(provider.languages, isEmpty);
      expect(provider.activeLanguage, isNull);
      expect(provider.activeLessons, isEmpty);

      await import(tester, provider, _korean);

      expect(provider.languages, ['ko']);
      expect(provider.activeLanguage, 'ko');
      expect(identical(provider.activeLessons, provider.lessons), isTrue);
      expect(provider.activeSentences, hasLength(1));
    });
  });

  group('several languages', () {
    testWidgets('a lesson in a new language is shown when it is imported', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      await import(tester, provider, _korean);
      await import(tester, provider, _taiwan);

      expect(provider.languages, ['ko', 'zh-tw']);
      expect(provider.activeLanguage, 'zh-tw');
      expect(titles(provider.activeLessons), ['Taiwan 1']);

      // Mainland and Taiwan lessons are apart too.
      await import(tester, provider, _mainland);
      expect(provider.languages, ['ko', 'zh-tw', 'zh-cn']);
      expect(titles(provider.activeLessons), ['Mainland 1']);
    });

    testWidgets('importing a lesson again does not change the language', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      await import(tester, provider, _korean);
      await import(tester, provider, _taiwan);
      await tester.runAsync(() => provider.setActiveLanguage('ko'));

      await import(tester, provider, _taiwan);

      expect(provider.activeLanguage, 'ko');
      expect(provider.lessons, hasLength(2));
    });

    testWidgets('lessons, words, sentences and the study queue are of the '
        'language picked', (tester) async {
      final provider = await loadedProvider(tester);
      await import(tester, provider, _korean);
      await import(tester, provider, _taiwan);

      var notified = 0;
      provider.addListener(() => notified++);
      await tester.runAsync(() => provider.setActiveLanguage('ko'));
      expect(notified, 1);

      expect(provider.activeLanguage, 'ko');
      expect(titles(provider.activeLessons), ['Korean 1']);
      expect(
        [for (final group in provider.vocabGroups) group.entry.targetWord],
        ['학생'],
      );
      expect(
        [for (final sentence in provider.activeSentences) sentence.targetText],
        ['저는 학생이에요.'],
      );
      expect(
        {
          for (final item in provider.getStudyQueue(dueOnly: false))
            item.vocab.targetWord,
        },
        {'학생'},
      );

      await tester.runAsync(() => provider.setActiveLanguage('zh-tw'));

      expect(titles(provider.activeLessons), ['Taiwan 1']);
      expect(
        {for (final group in provider.vocabGroups) group.entry.targetWord},
        {'學生', '老師'},
      );
      expect(
        [for (final sentence in provider.activeSentences) sentence.targetText],
        ['我是學生。'],
      );
      expect(
        {
          for (final item in provider.getStudyQueue(dueOnly: false))
            item.vocab.targetWord,
        },
        {'學生', '老師'},
      );
      // A lesson's own queue does not depend on the language shown.
      final korean = provider.lessons.first;
      expect(
        provider.getStudyQueue(lessonId: korean.id, dueOnly: false),
        isNotEmpty,
      );
    });

    testWidgets('the language picked is remembered', (tester) async {
      final provider = await loadedProvider(tester);
      await import(tester, provider, _korean);
      await import(tester, provider, _taiwan);
      await tester.runAsync(() => provider.setActiveLanguage('ko'));

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('lingua_srs_active_language'), 'ko');
    });

    testWidgets('a language with no lessons left falls back to the first', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      await import(tester, provider, _korean);
      await import(tester, provider, _taiwan);
      expect(provider.activeLanguage, 'zh-tw');

      final taiwan = provider.lessons.last;
      await tester.runAsync(() => provider.deleteLesson(taiwan.id));

      expect(provider.languages, ['ko']);
      expect(provider.activeLanguage, 'ko');
      expect(titles(provider.activeLessons), ['Korean 1']);
    });

    testWidgets('deleting or resetting a folder leaves the other language '
        'in it alone', (tester) async {
      final provider = await loadedProvider(tester);
      await import(tester, provider, _korean);
      await import(tester, provider, _taiwan);
      for (final lesson in provider.lessons) {
        await tester.runAsync(
          () => provider.moveLessonToFolder(lesson.id, ['Shared']),
        );
      }
      await tester.runAsync(() => provider.setActiveLanguage('ko'));

      await tester.runAsync(() => provider.deleteLessonGroup(['Shared']));

      expect(titles(provider.lessons), ['Taiwan 1']);
    });
  });

  group('sentences', () {
    testWidgets('a sentence added by hand is in the language shown only', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      await import(tester, provider, _korean);
      await import(tester, provider, _taiwan);

      await tester.runAsync(
        () => provider.addSentenceToPool(
          Sentence(targetText: 'Hand-written.', translationText: 'By hand.'),
        ),
      );

      List<String> shown() => [
        for (final sentence in provider.activeSentences) sentence.targetText,
      ];
      expect(shown(), ['我是學生。', 'Hand-written.']);
      await tester.runAsync(() => provider.setActiveLanguage('ko'));
      expect(shown(), ['저는 학생이에요.']);
    });

    testWidgets('a sentence with no lesson and no language goes by its '
        'script', (tester) async {
      final provider = await loadedProvider(tester);
      await import(tester, provider, _korean);
      await import(tester, provider, _taiwan);
      // As saved before sentences had a language.
      provider.sentences.addAll([
        Sentence(targetText: '안녕하세요.', translationText: 'Hello.'),
        Sentence(targetText: '你好。', translationText: 'Hello.'),
      ]);

      List<String> shown() => [
        for (final sentence in provider.activeSentences) sentence.targetText,
      ];
      expect(shown(), ['我是學生。', '你好。']);
      await tester.runAsync(() => provider.setActiveLanguage('ko'));
      expect(shown(), ['저는 학생이에요.', '안녕하세요.']);
    });

    testWidgets('Mainland and Taiwan lessons share one pool', (tester) async {
      final provider = await loadedProvider(tester);
      await import(tester, provider, _korean);
      await import(tester, provider, _taiwan);
      await import(tester, provider, _mainland);
      expect(provider.activeLanguage, 'zh-cn');

      // The Mainland lesson has no sentence of its own.
      expect(
        [for (final sentence in provider.activeSentences) sentence.targetText],
        ['我是學生。'],
      );

      // Words and lessons stay apart.
      expect(
        [for (final group in provider.vocabGroups) group.entry.targetWord],
        ['学生'],
      );
    });
  });

  group('activity and limits', () {
    final day = DateTime(2026, 1, 5);

    Future<AppProvider> studied(WidgetTester tester) async {
      final provider = await loadedProvider(tester, {
        // Counted before reviews were recorded with a language.
        'lingua_srs_daily_review_counts': '{"2026-01-05": 5}',
      });
      await import(tester, provider, _korean);
      await import(tester, provider, _taiwan);
      return provider;
    }

    SrsCard cardOf(AppProvider provider, int lesson, [int word = 0]) =>
        provider.lessons[lesson].vocabularies[word].cardTargetToNative;

    testWidgets('a review is counted for its language only', (tester) async {
      final provider = await studied(tester);
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);

      await tester.runAsync(
        () => provider.recordCardReview(cardOf(provider, 1), SrsRating.good),
      );
      await tester.runAsync(
        () =>
            provider.recordCardReview(cardOf(provider, 1, 1), SrsRating.again),
      );
      await tester.runAsync(
        () => provider.recordCardReview(cardOf(provider, 0), SrsRating.good),
      );

      expect(provider.dailyReviewCountsOf('zh-tw')[today], 2);
      expect(provider.dailyReviewCountsOf('ko')[today], 1);
      // Every language together, as before.
      expect(provider.dailyReviewCountsOf(null)[today], 3);

      // The getters without a language are of the one shown.
      expect(provider.activeLanguage, 'zh-tw');
      expect(provider.dailyReviewCounts[today], 2);
      expect(provider.dailyRatingCounts[today], {
        SrsRating.good: 1,
        SrsRating.again: 1,
      });
      expect(provider.dailyNewCardCounts[today], 2);
      expect(provider.reviewsInLast24Hours, 2);
      expect(provider.newCardsIntroducedLast24h, 2);

      await tester.runAsync(() => provider.setActiveLanguage('ko'));
      expect(provider.dailyReviewCounts[today], 1);
      expect(provider.dailyRatingCounts[today], {SrsRating.good: 1});
      expect(provider.reviewsInLast24Hours, 1);
      expect(provider.newCardsIntroducedLast24h, 1);
    });

    testWidgets('reviews counted before languages were recorded belong to '
        'the first language', (tester) async {
      final provider = await studied(tester);

      expect(provider.dailyReviewCountsOf('ko')[day], 5);
      expect(provider.dailyReviewCountsOf('zh-tw')[day], isNull);
      expect(provider.dailyReviewCountsOf(null)[day], 5);
    });

    testWidgets('each language has the 24-hour limits to itself', (
      tester,
    ) async {
      final provider = await studied(tester);
      await tester.runAsync(() => provider.setMaxNewCards24h(1));
      expect(provider.remainingNewCards24hOf('ko'), 1);
      expect(provider.remainingNewCards24hOf('zh-tw'), 1);

      await tester.runAsync(
        () => provider.recordCardReview(cardOf(provider, 1), SrsRating.good),
      );

      expect(provider.remainingNewCards24hOf('zh-tw'), 0);
      expect(provider.remainingNewCards24hOf('ko'), 1);
      // The Korean queue still starts its new card.
      await tester.runAsync(() => provider.setActiveLanguage('ko'));
      expect(provider.remainingNewCards24h, 1);
      expect(
        provider.getStudyQueue().where((item) => item.card.isNewCard),
        isNotEmpty,
      );
      await tester.runAsync(() => provider.setActiveLanguage('zh-tw'));
      expect(
        provider.getStudyQueue().where((item) => item.card.isNewCard),
        isEmpty,
      );
    });

    testWidgets('undoing a review takes it back from its language', (
      tester,
    ) async {
      final provider = await studied(tester);
      final at = DateTime.now();
      final today = DateTime(at.year, at.month, at.day);
      await tester.runAsync(
        () => provider.recordCardReview(
          cardOf(provider, 1),
          SrsRating.good,
          at: at,
          language: 'zh-tw',
        ),
      );
      expect(provider.dailyReviewCountsOf('zh-tw')[today], 1);

      await tester.runAsync(
        () => provider.undoCardReview(
          at,
          SrsRating.good,
          startedNewCard: true,
          language: 'zh-tw',
        ),
      );

      expect(provider.dailyReviewCountsOf('zh-tw')[today], isNull);
      expect(provider.dailyReviewCountsOf('ko')[today], isNull);
      expect(provider.reviewsInLast24HoursOf('zh-tw'), 0);
    });

    testWidgets('with one language the counts are the totals', (tester) async {
      final provider = await loadedProvider(tester, {
        'lingua_srs_daily_review_counts': '{"2026-01-05": 5}',
      });
      await import(tester, provider, _korean);

      expect(provider.dailyReviewCounts[day], 5);
      expect(provider.dailyReviewCountsOf('ko')[day], 5);
    });
  });

  group('LanguageSelector', () {
    test('names Mandarin variants', () {
      expect(LanguageSelector.nameOf('zh-cn'), 'Mandarin Chinese (Mainland)');
      expect(LanguageSelector.nameOf('zh-tw'), 'Mandarin Chinese (Taiwan)');
    });

    Future<void> pump(WidgetTester tester, AppProvider provider) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AppProvider>.value(value: provider),
            ChangeNotifierProvider<AudioService>(
              create: (_) => _FakeAudioService(),
            ),
          ],
          child: const MaterialApp(home: VocabPoolView()),
        ),
      );
      await tester.pump();
    }

    testWidgets('is not shown while there is one language', (tester) async {
      final provider = await loadedProvider(tester);
      await import(tester, provider, _korean);
      await pump(tester, provider);

      expect(find.byType(LanguageSelector), findsOneWidget);
      expect(find.byKey(const ValueKey('language-selector')), findsNothing);
      expect(find.text('학생'), findsOneWidget);
    });

    testWidgets('names the language shown and switches to the one picked', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      await import(tester, provider, _korean);
      await import(tester, provider, _taiwan);
      await pump(tester, provider);

      expect(find.text('Mandarin Chinese (Taiwan)'), findsOneWidget);
      expect(find.text('學生'), findsOneWidget);
      expect(find.text('학생'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('language-selector')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Korean').last);
      await tester.pumpAndSettle();

      expect(provider.activeLanguage, 'ko');
      expect(find.text('학생'), findsOneWidget);
      expect(find.text('學生'), findsNothing);
    });
  });
}
