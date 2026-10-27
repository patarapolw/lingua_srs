import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/lesson.dart';
import 'package:lingua_srs/models/srs_card.dart';
import 'package:lingua_srs/models/vocab_item.dart';
import 'package:lingua_srs/providers/app_provider.dart';
import 'package:lingua_srs/services/srs_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final storageDirectory = Directory.systemTemp.createTempSync(
    'lingua_srs_short_interval_test_',
  );
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(pathProviderChannel, (call) async {
        if (call.method == 'getApplicationSupportDirectory') {
          return storageDirectory.path;
        }
        throw MissingPluginException('Unexpected method: ${call.method}');
      });
  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    await storageDirectory.delete(recursive: true);
  });

  SrsCard dueCard({int interval = 6, SrsStatus status = SrsStatus.review}) =>
      SrsCard(
        direction: CardDirection.targetToNative,
        status: status,
        interval: interval,
        repetitions: 3,
        dueDate: DateTime.now().subtract(const Duration(minutes: 5)),
      );

  group('SrsCard.isShortInterval', () {
    test('a new card is not a short-interval card', () {
      expect(
        SrsCard(direction: CardDirection.targetToNative).isShortInterval,
        isFalse,
      );
    });

    test('Again schedules a 1 h interval', () {
      final card = dueCard();
      SrsService.processReview(card, SrsRating.again);

      expect(card.dueDate.difference(card.lastReviewed!).inMinutes, 60);
      expect(card.isShortInterval, isTrue);
    });

    test('Hard on a young card schedules a 12 h interval', () {
      final card = dueCard(interval: 1);
      SrsService.processReview(card, SrsRating.hard);

      expect(card.dueDate.difference(card.lastReviewed!).inHours, 12);
      expect(card.isShortInterval, isTrue);
    });

    test('a card with a 1 day or longer interval is not short', () {
      final card = dueCard(interval: 6);
      SrsService.processReview(card, SrsRating.good);

      expect(card.isShortInterval, isFalse);
    });

    test('Hard on a mature card stays on a multi-day interval', () {
      final card = dueCard(interval: 10);
      SrsService.processReview(card, SrsRating.hard);

      expect(card.isShortInterval, isFalse);
    });
  });

  group('review limit ignores sub-24h intervals', () {
    Future<AppProvider> newProvider({int maxReviews = 100}) async {
      SharedPreferences.setMockInitialValues({
        'lingua_srs_windows_legacy_migration_complete': true,
        'lingua_srs_lessons': '[]',
        'lingua_srs_sentences': '[]',
        'lingua_srs_max_reviews_24h': maxReviews,
      });
      final provider = AppProvider();
      while (provider.isLoading) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      provider.lessons.clear();
      return provider;
    }

    void addCards(AppProvider provider, List<SrsCard> cards) {
      final lesson = Lesson(title: 'L');
      for (var i = 0; i < cards.length; i++) {
        lesson.vocabularies.add(
          VocabItem(
            targetWord: 'w$i',
            translation: 't$i',
            pos: 'nouns',
            cardTargetToNative: cards[i],
          ),
        );
      }
      provider.lessons.add(lesson);
    }

    test('reviewing a 1 h card does not use the review quota', () async {
      final provider = await newProvider(maxReviews: 5);
      final card = dueCard(status: SrsStatus.learning, interval: 0);
      addCards(provider, [card]);

      await provider.recordCardReview(card, SrsRating.good);

      expect(provider.reviewsInLast24Hours, 0);
      expect(provider.remainingReviews24h, 5);
    });

    test('reviewing a 12 h card does not use the review quota', () async {
      final provider = await newProvider(maxReviews: 5);
      final card = dueCard(interval: 0);
      addCards(provider, [card]);

      await provider.recordCardReview(card, SrsRating.good);

      expect(provider.reviewsInLast24Hours, 0);
      expect(provider.remainingReviews24h, 5);
    });

    test('reviewing a card with a 1 day+ interval still counts', () async {
      final provider = await newProvider(maxReviews: 5);
      final card = dueCard(interval: 6);
      addCards(provider, [card]);

      await provider.recordCardReview(card, SrsRating.good);

      expect(provider.reviewsInLast24Hours, 1);
      expect(provider.remainingReviews24h, 4);
    });

    test('Again counts once; the 1 h retry does not count again', () async {
      final provider = await newProvider(maxReviews: 5);
      final card = dueCard(interval: 6);
      addCards(provider, [card]);

      await provider.recordCardReview(card, SrsRating.again);
      expect(provider.remainingReviews24h, 4);

      await provider.recordCardReview(card, SrsRating.again);
      await provider.recordCardReview(card, SrsRating.good);

      expect(provider.reviewsInLast24Hours, 1);
      expect(provider.remainingReviews24h, 4);
    });

    test('short-interval cards are queued past the limit', () async {
      final provider = await newProvider(maxReviews: 1);
      final used = dueCard(interval: 6);
      final retry = dueCard(status: SrsStatus.learning, interval: 0);
      final blocked = dueCard(interval: 6);
      addCards(provider, [used, retry, blocked]);

      await provider.recordCardReview(used, SrsRating.good);
      expect(provider.remainingReviews24h, 0);

      final queue = provider.getStudyQueue(dueOnly: true);

      expect(queue.map((item) => item.card.id), [retry.id]);
    });

    test('short-interval cards do not take a slot from the limit', () async {
      final provider = await newProvider(maxReviews: 2);
      final shortCard = dueCard(status: SrsStatus.learning, interval: 0);
      final normal = [for (var i = 0; i < 3; i++) dueCard(interval: 6)];
      addCards(provider, [shortCard, ...normal]);

      final queue = provider.getStudyQueue(dueOnly: true);
      final ids = queue.map((item) => item.card.id).toSet();

      expect(queue, hasLength(3)); // 1 short + 2 of the 3 normal cards
      expect(ids, contains(shortCard.id));
      expect(normal.where((c) => ids.contains(c.id)), hasLength(2));
    });
  });
}
