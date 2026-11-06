import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/srs_card.dart';
import 'package:lingua_srs/providers/app_provider.dart';
import 'package:lingua_srs/services/audio_service.dart';
import 'package:lingua_srs/services/storage_service.dart';
import 'package:lingua_srs/views/study_view.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'secret_storage_mock.dart';

/// Touches no audio plugin.
class _SilentAudioService extends ChangeNotifier implements AudioService {
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
      expect(provider.reviewsInLast24Hours, 1);

      await provider.undoCardReview(at);

      expect(provider.dailyReviewCounts.containsKey(_today()), isFalse);
      expect(provider.reviewsInLast24Hours, 0);
      expect(provider.remainingReviews24h, provider.maxReviews24h);
      expect(
        (await StorageService.loadDailyReviewCounts()).containsKey(_today()),
        isFalse,
      );
      expect(await StorageService.loadReviewTimestamps(), isEmpty);
    });

    test('undo and rating again counts the review once', () async {
      final card = _seenCard();
      final first = DateTime.now();
      await provider.recordCardReview(card, SrsRating.again, at: first);
      await provider.undoCardReview(first);
      final second = first.add(const Duration(seconds: 5));
      await provider.recordCardReview(card, SrsRating.good, at: second);

      expect(provider.dailyReviewCounts[_today()], 1);
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
      await provider.undoCardReview(shortAt);

      expect(provider.dailyReviewCounts[_today()], 1);
      expect(provider.reviewsInLast24Hours, 1);
      expect(await StorageService.loadReviewTimestamps(), [seenAt]);
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

    for (final label in ['Good', 'Again']) {
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
        expect(provider.reviewsInLast24Hours, 1);

        // The only card is done, so the session is over; undo brings it back.
        await tester.tap(find.textContaining('Undo Last Card'));
        await tester.pumpAndSettle();
        expect(provider.dailyReviewCounts.containsKey(_today()), isFalse);
        expect(provider.reviewsInLast24Hours, 0);

        await tester.tap(find.textContaining(label));
        await tester.pumpAndSettle();
        expect(provider.dailyReviewCounts[_today()], 1);
        expect(provider.reviewsInLast24Hours, 1);
      });
    }
  });
}
