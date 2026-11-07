import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/srs_card.dart';
import 'package:lingua_srs/providers/app_provider.dart';
import 'package:lingua_srs/services/audio_service.dart';
import 'package:lingua_srs/services/tts_voice.dart';
import 'package:lingua_srs/services/storage_service.dart';
import 'package:lingua_srs/services/sync_records.dart';
import 'package:lingua_srs/views/study_view.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'secret_storage_mock.dart';

/// Touches no audio plugin.
class _SilentAudioService extends ChangeNotifier implements AudioService {
  @override
  TtsVoiceUsed? get lastVoice => null;
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

/// A card already learned and due now, so its review counts toward the
/// 24-hour limit.
SrsCard _seenCard() {
  final now = DateTime.now();
  return SrsCard(
    direction: CardDirection.targetToNative,
    status: SrsStatus.review,
    interval: 3,
    repetitions: 2,
    lastReviewed: now.subtract(const Duration(days: 3)),
    dueDate: now,
  );
}

/// A card on a sub-24h interval, whose review does not count toward the
/// 24-hour limit.
SrsCard _shortIntervalCard() {
  final now = DateTime.now();
  return SrsCard(
    direction: CardDirection.targetToNative,
    status: SrsStatus.learning,
    lastReviewed: now.subtract(const Duration(hours: 1)),
    dueDate: now,
  );
}

DateTime _today() {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(setUpSecretStorage);

  group('AppProvider.undoCardReview', () {
    late AppProvider provider;

    setUp(() async {
      SharedPreferences.setMockInitialValues({
        'lingua_srs_windows_legacy_migration_complete': true,
      });
      provider = AppProvider();
      for (var attempt = 0; attempt < 100 && provider.isLoading; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(provider.isLoading, isFalse);
    });

    tearDown(() => provider.dispose());

    test('takes back the day count and the 24-hour entry', () async {
      final at = DateTime.now();
      await provider.recordCardReview(_seenCard(), SrsRating.good, at: at);
      expect(provider.dailyReviewCounts[_today()], 1);
      expect(provider.dailyRatingCounts[_today()], {SrsRating.good: 1});
      expect(provider.reviewsInLast24Hours, 1);
      expect(await StorageService.loadDailyRatingCounts(), {
        _today(): {SrsRating.good: 1},
      });

      await provider.undoCardReview(at, SrsRating.good);

      expect(provider.dailyReviewCounts.containsKey(_today()), isFalse);
      expect(provider.dailyRatingCounts.containsKey(_today()), isFalse);
      expect(provider.reviewsInLast24Hours, 0);
      expect(provider.remainingReviews24h, provider.maxReviews24h);
      expect(
        (await StorageService.loadDailyReviewCounts()).containsKey(_today()),
        isFalse,
      );
      expect(await StorageService.loadDailyRatingCounts(), isEmpty);
      expect(await StorageService.loadReviewTimestamps(), isEmpty);
    });

    test('undo and rating again counts the review once', () async {
      final first = DateTime.now();
      await provider.recordCardReview(_seenCard(), SrsRating.again, at: first);
      await provider.undoCardReview(first, SrsRating.again);
      // Undo also restores the card (the study view does that), so rate it
      // as it was: `again` put it on a sub-24h interval.
      final second = first.add(const Duration(seconds: 5));
      await provider.recordCardReview(_seenCard(), SrsRating.good, at: second);

      expect(provider.dailyReviewCounts[_today()], 1);
      expect(provider.dailyRatingCounts[_today()], {SrsRating.good: 1});
      expect(provider.reviewsInLast24Hours, 1);
    });

    test('leaves the other reviews of the day alone', () async {
      final seenAt = DateTime.now();
      await provider.recordCardReview(_seenCard(), SrsRating.good, at: seenAt);
      final shortAt = seenAt.add(const Duration(seconds: 5));
      await provider.recordCardReview(
        _shortIntervalCard(),
        SrsRating.good,
        at: shortAt,
      );
      expect(provider.dailyReviewCounts[_today()], 2);
      expect(provider.reviewsInLast24Hours, 1);

      // The short-interval review had no 24-hour entry to take back.
      await provider.undoCardReview(shortAt, SrsRating.good);

      expect(provider.dailyReviewCounts[_today()], 1);
      expect(provider.dailyRatingCounts[_today()], {SrsRating.good: 1});
      expect(provider.reviewsInLast24Hours, 1);
      expect(await StorageService.loadReviewTimestamps(), [seenAt]);
    });

    test('counts a new card started, and undo takes it back', () async {
      final newAt = DateTime.now();
      final newCard = SrsCard(direction: CardDirection.targetToNative);
      await provider.recordCardReview(newCard, SrsRating.good, at: newAt);
      final seenAt = newAt.add(const Duration(seconds: 5));
      await provider.recordCardReview(_seenCard(), SrsRating.good, at: seenAt);

      expect(provider.dailyReviewCounts[_today()], 2);
      expect(provider.dailyNewCardCounts[_today()], 1);
      expect(await StorageService.loadDailyNewCardCounts(), {_today(): 1});

      // The seen card's review started no new card.
      await provider.undoCardReview(seenAt, SrsRating.good);
      expect(provider.dailyNewCardCounts[_today()], 1);

      await provider.undoCardReview(
        newAt,
        SrsRating.good,
        startedNewCard: true,
      );
      expect(provider.dailyNewCardCounts.containsKey(_today()), isFalse);
      expect(await StorageService.loadDailyNewCardCounts(), isEmpty);
    });

    test('re-rating moves the review to the new rating', () async {
      final at = DateTime.now();
      await provider.recordCardReview(_seenCard(), SrsRating.good, at: at);

      await provider.recountCardReview(at, SrsRating.good, SrsRating.again);

      expect(provider.dailyReviewCounts[_today()], 1);
      expect(provider.dailyRatingCounts[_today()], {SrsRating.again: 1});
      expect(provider.reviewsInLast24Hours, 1);
      expect(await StorageService.loadDailyRatingCounts(), {
        _today(): {SrsRating.again: 1},
      });
    });

    test("counts other devices' ratings, and old records without", () async {
      final day = DateTime(2026, 11, 5);
      await provider.apply('device-a', {
        const SyncRecordKey(SyncKinds.activity, 'device-b:2026-11-05'): {
          'day': '2026-11-05',
          'count': 4,
          'ratings': {'good': 3, 'again': 1},
          'newCards': 2,
          'reviews': <String>[],
        },
        // From an app version that did not count ratings yet.
        const SyncRecordKey(SyncKinds.activity, 'device-c:2026-11-05'): {
          'day': '2026-11-05',
          'count': 2,
          'reviews': <String>[],
        },
      });

      expect(provider.dailyReviewCounts[day], 6);
      expect(provider.dailyRatingCounts[day], {
        SrsRating.good: 3,
        SrsRating.again: 1,
      });
      expect(provider.dailyNewCardCounts[day], 2);
    });
  });

  group('Undo in a review', () {
    const pathProviderChannel = MethodChannel(
      'plugins.flutter.io/path_provider',
    );
    late Directory storageDirectory;

    setUp(() {
      storageDirectory = Directory.systemTemp.createTempSync(
        'lingua_srs_review_undo_count_test_',
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
      return provider;
    }

    Future<void> openLesson(
      WidgetTester tester,
      AppProvider provider,
      String yaml,
    ) async {
      final lesson = (await tester.runAsync(() => provider.importYaml(yaml)))!;
      for (final vocab in lesson.vocabularies) {
        vocab.cardNativeToTarget.isEnabled = false;
      }

      tester.view.physicalSize = const Size(800, 1280);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AppProvider>.value(value: provider),
            ChangeNotifierProvider<AudioService>(
              create: (_) => _SilentAudioService(),
            ),
          ],
          child: MaterialApp(home: StudyView(lessonId: lesson.id)),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('re-rating an answered card moves its rating count', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      await openLesson(
        tester,
        provider,
        '---\nvocabulary:\n  nouns:\n    - ko: 단어\n      en: word\n'
        '    - ko: 문장\n      en: sentence\n---\n# Lesson\n',
      );

      await tester.tap(find.textContaining('Show Answer'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Good'));
      await tester.pumpAndSettle();
      expect(provider.dailyRatingCounts[_today()], {SrsRating.good: 1});

      // Back to the answered card, and mark it Again instead.
      await tester.tap(find.byIcon(Icons.chevron_left));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Again'));
      await tester.pumpAndSettle();

      expect(provider.dailyReviewCounts[_today()], 1);
      expect(provider.dailyRatingCounts[_today()], {SrsRating.again: 1});
    });

    for (final (label, rating) in [
      ('Good', SrsRating.good),
      ('Again', SrsRating.again),
    ]) {
      testWidgets('rating $label, undoing and rating again counts once', (
        tester,
      ) async {
        final provider = await loadedProvider(tester);
        const yaml =
            '---\nvocabulary:\n  nouns:\n    - ko: 단어\n      en: word\n'
            '---\n# Lesson\n';
        final lesson = (await tester.runAsync(
          () => provider.importYaml(yaml),
        ))!;
        lesson.vocabularies.single.cardNativeToTarget.isEnabled = false;

        tester.view.physicalSize = const Size(800, 1280);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider<AppProvider>.value(value: provider),
              ChangeNotifierProvider<AudioService>(
                create: (_) => _SilentAudioService(),
              ),
            ],
            child: MaterialApp(home: StudyView(lessonId: lesson.id)),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.textContaining('Show Answer'));
        await tester.pumpAndSettle();
        await tester.tap(find.textContaining(label));
        await tester.pumpAndSettle();
        expect(provider.dailyReviewCounts[_today()], 1);
        expect(provider.dailyRatingCounts[_today()], {rating: 1});
        expect(provider.dailyNewCardCounts[_today()], 1);
        expect(provider.reviewsInLast24Hours, 1);

        // The only card is done, so the session is over; undo brings it back.
        await tester.tap(find.textContaining('Undo Last Card'));
        await tester.pumpAndSettle();
        expect(provider.dailyReviewCounts.containsKey(_today()), isFalse);
        expect(provider.dailyRatingCounts.containsKey(_today()), isFalse);
        expect(provider.dailyNewCardCounts.containsKey(_today()), isFalse);
        expect(provider.reviewsInLast24Hours, 0);

        await tester.tap(find.textContaining(label));
        await tester.pumpAndSettle();
        expect(provider.dailyReviewCounts[_today()], 1);
        expect(provider.dailyRatingCounts[_today()], {rating: 1});
        expect(provider.dailyNewCardCounts[_today()], 1);
        expect(provider.reviewsInLast24Hours, 1);
      });
    }
  });
}
