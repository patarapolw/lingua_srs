import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/lesson.dart';
import 'package:lingua_srs/models/srs_card.dart';
import 'package:lingua_srs/models/vocab_item.dart';
import 'package:lingua_srs/providers/app_provider.dart';
import 'package:lingua_srs/services/audio_service.dart';
import 'package:lingua_srs/views/study_view.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'secret_storage_mock.dart';

/// A study screen must not touch real audio plugins.
class _FakeAudioService extends ChangeNotifier implements AudioService {
  @override
  bool get isPlaying => false;
  @override
  String? get currentlyPlayingKey => null;
  @override
  bool get usesOfflineTts => true;
  @override
  void prefetchAudios(List<String?> urls) {}
  @override
  String getTtsUrl(String text, {String? language}) => '';
  @override
  Future<void> stop() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

VocabItem newVocab(String name) =>
    VocabItem(targetWord: name, translation: name, pos: 'nouns');

/// Seen and scheduled for later: not due.
VocabItem seenVocab(String name) => VocabItem(
  targetWord: name,
  translation: name,
  pos: 'nouns',
  cardTargetToNative: SrsCard(
    direction: CardDirection.targetToNative,
    status: SrsStatus.review,
    interval: 6,
    repetitions: 2,
    dueDate: DateTime.now().add(const Duration(days: 6)),
    introducedAt: DateTime.now().subtract(const Duration(days: 10)),
  ),
);

Lesson lessonWith(String title, List<VocabItem> vocab) =>
    Lesson(title: title)..vocabularies.addAll(vocab);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(setUpSecretStorage);

  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory storageDirectory;
  setUp(() {
    storageDirectory = Directory.systemTemp.createTempSync(
      'lingua_srs_cram_mode_test_',
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

  group('cramChoicesAfterSession', () {
    test('all lessons: practice only and updating schedules', () {
      expect(cramChoicesAfterSession(lessonCram: false), [
        CramMode.practice,
        CramMode.reschedule,
      ]);
      expect(cramChoicesAfterSession(lessonCram: false, canLearnNew: true), [
        CramMode.practice,
        CramMode.reschedule,
      ], reason: 'Learn New Words is only for one lesson');
    });

    test('one lesson: Learn New Words while it can, and practice only', () {
      expect(cramChoicesAfterSession(lessonCram: true, canLearnNew: true), [
        CramMode.learnNew,
        CramMode.practice,
      ]);
      expect(cramChoicesAfterSession(lessonCram: true), [CramMode.practice]);
    });

    test('labels', () {
      expect(cramButtonLabel(CramMode.practice), 'Cram (Practice Only)');
      expect(cramButtonLabel(CramMode.reschedule), 'Cram and Update Schedules');
      expect(cramButtonLabel(CramMode.learnNew), 'Learn New Words');
    });
  });

  group('unscheduledCardChip', () {
    test('practice and repeat say the schedule is unchanged', () {
      expect(
        unscheduledCardChip(practice: true).label,
        'PRACTICE · schedule unchanged',
      );
      expect(
        unscheduledCardChip(practice: false).label,
        'REPEAT · schedule unchanged',
      );
    });
  });

  group('getCramQueue', () {
    Future<AppProvider> newProvider({int? maxReviews, int? maxNewCards}) async {
      SharedPreferences.setMockInitialValues({
        'lingua_srs_windows_legacy_migration_complete': true,
        'lingua_srs_lessons': '[]',
        'lingua_srs_sentences': '[]',
        'lingua_srs_max_reviews_24h': ?maxReviews,
        'lingua_srs_max_new_cards_24h': ?maxNewCards,
      });
      final provider = AppProvider();
      while (provider.isLoading) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      provider.lessons.clear();
      return provider;
    }

    test(
      'all lessons: seen cards only, due or not, past the review limit',
      () async {
        final provider = await newProvider(maxReviews: 1);
        provider.lessons.addAll([
          lessonWith('A', [seenVocab('a1'), seenVocab('a2'), newVocab('a새')]),
          lessonWith('B', [seenVocab('b1'), newVocab('b새')]),
        ]);

        final queue = provider.getCramQueue();

        expect(queue, hasLength(3));
        expect(queue.any((item) => item.card.isNewCard), isFalse);
      },
    );

    test('one lesson: its new cards first, then its seen cards', () async {
      final provider = await newProvider();
      final lesson = lessonWith('A', [
        seenVocab('a1'),
        newVocab('새1'),
        seenVocab('a2'),
        newVocab('새2'),
      ]);
      provider.lessons.addAll([
        lesson,
        lessonWith('B', [seenVocab('b1')]),
      ]);

      final queue = provider.getCramQueue(lessonId: lesson.id);

      expect(queue, hasLength(4));
      expect(queue.take(2).every((item) => item.card.isNewCard), isTrue);
      expect(queue.skip(2).every((item) => !item.card.isNewCard), isTrue);
      expect(queue.every((item) => item.lesson.id == lesson.id), isTrue);
    });

    test('one lesson: practice holds every new card, past the limit', () async {
      final provider = await newProvider(maxNewCards: 2);
      final lesson = lessonWith('A', [
        for (var i = 0; i < 5; i++) newVocab('새$i'),
        seenVocab('a1'),
      ]);
      provider.lessons.add(lesson);

      final queue = provider.getCramQueue(lessonId: lesson.id);
      expect(queue.where((item) => item.card.isNewCard), hasLength(5));
      expect(queue, hasLength(6));
    });
  });

  group('getLearnNewQueue', () {
    Future<AppProvider> newProvider({int? maxNewCards}) async {
      SharedPreferences.setMockInitialValues({
        'lingua_srs_windows_legacy_migration_complete': true,
        'lingua_srs_lessons': '[]',
        'lingua_srs_sentences': '[]',
        'lingua_srs_max_new_cards_24h': ?maxNewCards,
      });
      final provider = AppProvider();
      while (provider.isLoading) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      provider.lessons.clear();
      return provider;
    }

    test('new cards spread among up to 2 seen cards each, new first', () async {
      final provider = await newProvider();
      final lesson = lessonWith('Learn', [
        for (var i = 0; i < 3; i++) newVocab('새$i'),
        for (var i = 0; i < 10; i++) seenVocab('봄$i'),
      ]);
      provider.lessons.addAll([
        lesson,
        lessonWith('Other', [newVocab('딴'), seenVocab('딴봄')]),
      ]);

      final queue = provider.getLearnNewQueue(lesson.id);
      final kinds = [for (final i in queue) i.card.isNewCard ? 'N' : 'o'];

      expect(kinds.join(), 'NooNooNoo');
      expect(queue.every((item) => item.lesson.id == lesson.id), isTrue);
    });

    test('a batch is the size of the daily new-card limit', () async {
      final provider = await newProvider(maxNewCards: 2);
      final lesson = lessonWith('Batch', [
        for (var i = 0; i < 5; i++) newVocab('새$i'),
        seenVocab('봄'),
      ]);
      provider.lessons.add(lesson);

      expect(provider.learnableNewCardCount(lesson.id), 2);
      final queue = provider.getLearnNewQueue(lesson.id);
      expect(queue.where((item) => item.card.isNewCard), hasLength(2));
      expect(queue, hasLength(3), reason: 'only one seen card to mix in');
    });

    test('learns past the daily limit, and still counts toward it', () async {
      final provider = await newProvider(maxNewCards: 2);
      final lesson = lessonWith('Extra', [
        for (var i = 0; i < 5; i++) newVocab('새$i'),
      ]);
      provider.lessons.add(lesson);

      for (final item in provider.getLearnNewQueue(lesson.id)) {
        await provider.recordCardReview(item.card, SrsRating.good);
      }
      expect(provider.remainingNewCards24h, 0);
      expect(provider.getStudyQueue(dueOnly: true), isEmpty);

      // The next batch is still offered: 3 new cards left, batches of 2.
      expect(provider.learnableNewCardCount(lesson.id), 2);
      for (final item in provider.getLearnNewQueue(lesson.id)) {
        await provider.recordCardReview(item.card, SrsRating.good);
      }
      expect(provider.newCardsIntroducedLast24h, 4);
      expect(provider.learnableNewCardCount(lesson.id), 1);
    });

    test('0 (unlimited) learns every new card in one batch', () async {
      final provider = await newProvider(maxNewCards: 0);
      final lesson = lessonWith('All', [
        for (var i = 0; i < 25; i++) newVocab('새$i'),
      ]);
      provider.lessons.add(lesson);

      expect(provider.learnableNewCardCount(lesson.id), 25);
    });

    test('no new cards left: nothing to learn', () async {
      final provider = await newProvider();
      final lesson = lessonWith('Done', [seenVocab('봄')]);
      provider.lessons.add(lesson);

      expect(provider.learnableNewCardCount(lesson.id), 0);
      expect(provider.getLearnNewQueue(lesson.id), isEmpty);
    });
  });

  group('Cram sessions', () {
    Future<AppProvider> loadedProvider(WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({
        'lingua_srs_windows_legacy_migration_complete': true,
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
      provider.lessons.clear();
      return provider;
    }

    Future<void> openCram(
      WidgetTester tester,
      AppProvider provider,
      Lesson lesson,
      CramMode mode,
    ) async {
      tester.view.physicalSize = const Size(1200, 2400);
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
          child: MaterialApp(
            home: StudyView(lessonId: lesson.id, cramMode: mode),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    Future<void> answerGood(WidgetTester tester) async {
      await tester.tap(find.textContaining('Show Answer'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Good'));
      await tester.pumpAndSettle();
    }

    testWidgets('a repeat after Again says its schedule is unchanged', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      final lesson = lessonWith('Repeat', [seenVocab('봄'), seenVocab('여름')]);
      for (final vocab in lesson.vocabularies) {
        vocab.cardTargetToNative.dueDate = DateTime.now().subtract(
          const Duration(days: 1),
        );
      }
      provider.lessons.add(lesson);
      tester.view.physicalSize = const Size(1200, 2400);
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
          child: MaterialApp(home: StudyView(lessonId: lesson.id)),
        ),
      );
      await tester.pump();
      await tester.pump();

      // First pass: scheduled, so no chip and real intervals.
      expect(find.textContaining('schedule unchanged'), findsNothing);
      expect(find.text('no change'), findsNothing);
      await tester.tap(find.textContaining('Show Answer'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Again'));
      await tester.pumpAndSettle();
      await answerGood(tester);

      // The Again card is back at the end, as a repeat.
      expect(find.text('REPEAT · schedule unchanged'), findsOneWidget);
      await tester.tap(find.textContaining('Show Answer'));
      await tester.pumpAndSettle();
      expect(find.text('no change'), findsNWidgets(2));
    });

    testWidgets('practice only leaves schedules and new cards alone', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      final fresh = newVocab('새');
      final seen = seenVocab('봄');
      final lesson = lessonWith('Practice', [seen, fresh]);
      provider.lessons.add(lesson);
      final seenCard = seen.cardTargetToNative;
      final dueDate = seenCard.dueDate;
      final repetitions = seenCard.repetitions;

      await openCram(tester, provider, lesson, CramMode.practice);
      expect(find.text('PRACTICE · schedule unchanged'), findsOneWidget);
      await answerGood(tester); // the new card comes first
      await answerGood(tester);

      expect(fresh.cardTargetToNative.isNewCard, isTrue);
      expect(fresh.cardTargetToNative.introducedAt, isNull);
      expect(seenCard.dueDate, dueDate);
      expect(seenCard.repetitions, repetitions);
      expect(provider.newCardsIntroducedLast24h, 0);
      expect(provider.reviewsInLast24Hours, 0);

      // The new card is still new, so a lesson can then learn it.
      expect(find.text('Learn New Words'), findsOneWidget);
      expect(find.text('Cram (Practice Only)'), findsOneWidget);
      expect(find.text('Cram and Update Schedules'), findsNothing);
    });

    testWidgets('Learn New Words starts new cards, only practises old ones', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      final fresh = newVocab('새');
      final seen = seenVocab('봄');
      final lesson = lessonWith('Learn', [seen, fresh]);
      provider.lessons.add(lesson);
      final seenCard = seen.cardTargetToNative;
      final dueDate = seenCard.dueDate;
      final repetitions = seenCard.repetitions;
      final remainingBefore = provider.remainingNewCards24h;

      await openCram(tester, provider, lesson, CramMode.learnNew);
      expect(find.text('NEW'), findsOneWidget, reason: 'a new card first');
      await answerGood(tester);
      await answerGood(tester);

      expect(fresh.cardTargetToNative.isNewCard, isFalse);
      expect(fresh.cardTargetToNative.introducedAt, isNotNull);
      expect(provider.remainingNewCards24h, remainingBefore - 1);
      expect(seenCard.repetitions, repetitions);
      expect(seenCard.dueDate, dueDate);
    });

    testWidgets('updating schedules reschedules every lesson\'s seen cards', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      final seen = seenVocab('봄');
      final lesson = lessonWith('Reschedule', [seen, newVocab('새')]);
      provider.lessons.add(lesson);
      final seenCard = seen.cardTargetToNative;
      final repetitions = seenCard.repetitions;
      tester.view.physicalSize = const Size(1200, 2400);
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
          child: const MaterialApp(
            home: StudyView(cramMode: CramMode.reschedule),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('NEW'), findsNothing, reason: 'no new cards');
      await answerGood(tester);

      expect(seenCard.repetitions, repetitions + 1);
      expect(find.text('Cram and Update Schedules'), findsOneWidget);
    });

    testWidgets('a normal lesson session offers practice-only cram', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      final lesson = lessonWith('Done', [seenVocab('봄')]);
      provider.lessons.add(lesson);
      tester.view.physicalSize = const Size(1200, 2400);
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
          child: MaterialApp(home: StudyView(lessonId: lesson.id)),
        ),
      );
      await tester.pump();
      await tester.pump();

      // Nothing is due, so the session is over at once.
      expect(find.text('Cram (Practice Only)'), findsOneWidget);
      expect(find.text('Cram and Update Schedules'), findsNothing);
    });
  });
}
