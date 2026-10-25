import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/lesson.dart';
import 'package:lingua_srs/models/srs_card.dart';
import 'package:lingua_srs/models/vocab_item.dart';
import 'package:lingua_srs/providers/app_provider.dart';
import 'package:lingua_srs/services/srs_service.dart';
import 'package:lingua_srs/services/storage_service.dart';
import 'package:lingua_srs/views/lesson_detail_view.dart';
import 'package:lingua_srs/views/lesson_list_view.dart';
import 'package:lingua_srs/views/study_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final storageDirectory = Directory.systemTemp.createTempSync(
    'lingua_srs_new_vs_due_test_',
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

  group('SrsCard: new is not due', () {
    test('a fresh card is new and available, but not due', () {
      final card = SrsCard(direction: CardDirection.targetToNative);

      expect(card.isNewCard, isTrue);
      expect(card.isDue, isFalse);
      expect(card.isAvailable, isTrue);
      expect(card.introducedAt, isNull);
    });

    test('a disabled card is neither new nor due nor available', () {
      final card = SrsCard(
        direction: CardDirection.targetToNative,
        isEnabled: false,
      );

      expect(card.isNewCard, isFalse);
      expect(card.isDue, isFalse);
      expect(card.isAvailable, isFalse);
    });

    test('a reviewed card is due only once its due date has passed', () {
      final now = DateTime.now();
      final scheduled = SrsCard(
        direction: CardDirection.targetToNative,
        status: SrsStatus.review,
        dueDate: now.add(const Duration(hours: 5)),
      );
      final overdue = SrsCard(
        direction: CardDirection.targetToNative,
        status: SrsStatus.review,
        dueDate: now.subtract(const Duration(minutes: 1)),
      );

      expect(scheduled.isDue, isFalse);
      expect(scheduled.isNewCard, isFalse);
      expect(scheduled.isAvailable, isFalse);
      expect(overdue.isDue, isTrue);
      expect(overdue.isNewCard, isFalse);
      expect(overdue.isAvailable, isTrue);
    });

    test('the first review introduces the card, later ones keep the time', () {
      final card = SrsCard(direction: CardDirection.targetToNative);

      SrsService.processReview(card, SrsRating.good);
      final introducedAt = card.introducedAt;

      expect(introducedAt, isNotNull);
      expect(card.isNewCard, isFalse);
      expect(card.isDue, isFalse);

      SrsService.processReview(card, SrsRating.good);
      expect(card.introducedAt, introducedAt);
    });

    test('Again on a new card introduces it and makes it due in an hour', () {
      final card = SrsCard(direction: CardDirection.targetToNative);

      SrsService.processReview(card, SrsRating.again);

      expect(card.introducedAt, isNotNull);
      expect(card.status, SrsStatus.learning);
      expect(card.isNewCard, isFalse);
      expect(card.isDue, isFalse);

      card.dueDate = DateTime.now().subtract(const Duration(minutes: 1));
      expect(card.isDue, isTrue);
    });

    test('previewing the interval buttons does not introduce the card', () {
      final card = SrsCard(direction: CardDirection.targetToNative);

      for (final rating in SrsRating.values) {
        SrsService.previewInterval(card, rating);
      }

      expect(card.introducedAt, isNull);
      expect(card.status, SrsStatus.isNew);
      expect(card.isNewCard, isTrue);
    });

    test('resetting progress makes the card new again', () {
      final card = SrsCard(direction: CardDirection.targetToNative);
      SrsService.processReview(card, SrsRating.good);

      card.resetProgress();

      expect(card.introducedAt, isNull);
      expect(card.isNewCard, isTrue);
    });

    test('introducedAt survives JSON, and old saves without it still load', () {
      final card = SrsCard(direction: CardDirection.targetToNative);
      SrsService.processReview(card, SrsRating.good);

      final restored = SrsCard.fromJson(card.toJson());
      expect(restored.introducedAt, card.introducedAt);

      final legacy = card.toJson()..remove('introducedAt');
      expect(SrsCard.fromJson(legacy).introducedAt, isNull);
    });

    test('restoring a history record takes the card back to new', () {
      final card = SrsCard(direction: CardDirection.targetToNative);
      final record = ReviewHistoryRecord.capture(
        queueIndex: 0,
        card: card,
        rating: SrsRating.good,
      );
      SrsService.processReview(card, SrsRating.good);
      expect(card.introducedAt, isNotNull);

      record.restore();

      expect(card.introducedAt, isNull);
      expect(card.status, SrsStatus.isNew);
      expect(card.isNewCard, isTrue);
    });
  });

  group('Lesson counts', () {
    test('new cards are counted as new, not as due', () {
      final lesson = Lesson(title: 'Counts');
      lesson.vocabularies.addAll([
        VocabItem(targetWord: '새1', translation: 'new 1', pos: 'nouns'),
        VocabItem(targetWord: '새2', translation: 'new 2', pos: 'nouns'),
        VocabItem(
          targetWord: '복습',
          translation: 'due',
          pos: 'nouns',
          cardTargetToNative: SrsCard(
            direction: CardDirection.targetToNative,
            status: SrsStatus.review,
            dueDate: DateTime.now().subtract(const Duration(days: 1)),
          ),
        ),
      ]);

      expect(lesson.newCardsCount, 2);
      expect(lesson.dueCardsCount, 1);
      expect(lesson.activeCardsCount, 3);
    });
  });

  group('Study queue and daily limits', () {
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

    VocabItem newVocab(String name) =>
        VocabItem(targetWord: name, translation: name, pos: 'nouns');

    VocabItem dueVocab(String name) => VocabItem(
      targetWord: name,
      translation: name,
      pos: 'nouns',
      cardTargetToNative: SrsCard(
        direction: CardDirection.targetToNative,
        status: SrsStatus.review,
        dueDate: DateTime.now().subtract(const Duration(days: 1)),
      ),
    );

    Lesson lessonWith(String title, List<VocabItem> vocab) {
      final lesson = Lesson(title: title);
      lesson.vocabularies.addAll(vocab);
      return lesson;
    }

    test('defaults are 100 reviews and 10 new cards per 24 hours', () async {
      final provider = await newProvider();

      expect(provider.maxReviews24h, 100);
      expect(provider.maxNewCards24h, 10);
      expect(provider.remainingReviews24h, 100);
      expect(provider.remainingNewCards24h, 10);
    });

    test('the new-card limit is saved and loaded', () async {
      final provider = await newProvider();

      await provider.setMaxNewCards24h(5);

      expect(provider.maxNewCards24h, 5);
      expect(await StorageService.loadMaxNewCards24h(), 5);
    });

    test('due cards come before new cards', () async {
      final provider = await newProvider();
      provider.lessons.add(
        lessonWith('Mixed', [
          newVocab('새1'),
          newVocab('새2'),
          dueVocab('복습1'),
          dueVocab('복습2'),
          newVocab('새3'),
        ]),
      );

      final queue = provider.getStudyQueue(dueOnly: true);

      expect(queue, hasLength(5));
      expect(queue.take(2).every((item) => item.card.isDue), isTrue);
      expect(queue.skip(2).every((item) => item.card.isNewCard), isTrue);
    });

    test(
      'the new-card limit caps new cards without touching due ones',
      () async {
        final provider = await newProvider(maxNewCards: 3);
        provider.lessons.add(
          lessonWith('Capped', [
            for (var i = 0; i < 5; i++) newVocab('새$i'),
            for (var i = 0; i < 2; i++) dueVocab('복습$i'),
          ]),
        );

        final queue = provider.getStudyQueue(dueOnly: true);

        expect(queue, hasLength(5));
        expect(queue.where((item) => item.card.isDue), hasLength(2));
        expect(queue.where((item) => item.card.isNewCard), hasLength(3));
      },
    );

    test('the review limit caps due cards without touching new ones', () async {
      final provider = await newProvider(maxReviews: 1);
      provider.lessons.add(
        lessonWith('Capped', [
          for (var i = 0; i < 4; i++) dueVocab('복습$i'),
          for (var i = 0; i < 2; i++) newVocab('새$i'),
        ]),
      );

      final queue = provider.getStudyQueue(dueOnly: true);

      expect(queue.where((item) => item.card.isDue), hasLength(1));
      expect(queue.where((item) => item.card.isNewCard), hasLength(2));
    });

    test('0 means unlimited new cards', () async {
      final provider = await newProvider(maxNewCards: 0);
      provider.lessons.add(
        lessonWith('Unlimited', [for (var i = 0; i < 25; i++) newVocab('새$i')]),
      );

      expect(provider.remainingNewCards24h, greaterThan(1000));
      expect(provider.getStudyQueue(dueOnly: true), hasLength(25));
    });

    test(
      'a first review uses the new-card quota, not the review quota',
      () async {
        final provider = await newProvider(maxReviews: 5, maxNewCards: 2);
        provider.lessons.add(
          lessonWith('Quota', [
            for (var i = 0; i < 4; i++) newVocab('새$i'),
            dueVocab('복습'),
          ]),
        );

        final queue = provider.getStudyQueue(dueOnly: true);
        final firstNew = queue.firstWhere((item) => item.card.isNewCard);
        await provider.recordCardReview(firstNew.card, SrsRating.good);

        expect(provider.reviewsInLast24Hours, 1);
        expect(provider.newCardsIntroducedLast24h, 1);
        expect(provider.reviewsOfSeenCardsInLast24Hours, 0);
        expect(provider.remainingReviews24h, 5);
        expect(provider.remainingNewCards24h, 1);
      },
    );

    test('reviewing a due card does not use the new-card quota', () async {
      final provider = await newProvider(maxReviews: 5, maxNewCards: 2);
      provider.lessons.add(
        lessonWith('Quota', [dueVocab('복습'), newVocab('새')]),
      );

      final queue = provider.getStudyQueue(dueOnly: true);
      final due = queue.firstWhere((item) => item.card.isDue);
      await provider.recordCardReview(due.card, SrsRating.good);

      expect(provider.newCardsIntroducedLast24h, 0);
      expect(provider.remainingNewCards24h, 2);
      expect(provider.remainingReviews24h, 4);
    });

    test(
      'once the new-card limit is used up no new cards are queued',
      () async {
        final provider = await newProvider(maxNewCards: 1);
        provider.lessons.add(
          lessonWith('Limit', [newVocab('새1'), newVocab('새2'), dueVocab('복습')]),
        );

        final queue = provider.getStudyQueue(dueOnly: true);
        expect(queue.where((item) => item.card.isNewCard), hasLength(1));
        await provider.recordCardReview(
          queue.firstWhere((item) => item.card.isNewCard).card,
          SrsRating.good,
        );

        final after = provider.getStudyQueue(dueOnly: true);
        expect(provider.remainingNewCards24h, 0);
        expect(after.where((item) => item.card.isNewCard), isEmpty);
        expect(after.where((item) => item.card.isDue), hasLength(1));
      },
    );

    test('a card introduced more than 24 hours ago no longer counts', () async {
      final provider = await newProvider(maxNewCards: 3);
      final recent = dueVocab('최근');
      final old = dueVocab('예전');
      recent.cardTargetToNative.introducedAt = DateTime.now().subtract(
        const Duration(hours: 23),
      );
      old.cardTargetToNative.introducedAt = DateTime.now().subtract(
        const Duration(hours: 25),
      );
      provider.lessons.add(lessonWith('Rolling', [recent, old]));

      expect(provider.newCardsIntroducedLast24h, 1);
      expect(provider.remainingNewCards24h, 2);
    });

    test('undoing a first review gives the new-card slot back', () async {
      final provider = await newProvider(maxNewCards: 1);
      provider.lessons.add(lessonWith('Undo', [newVocab('새')]));

      final item = provider.getStudyQueue(dueOnly: true).single;
      final record = ReviewHistoryRecord.capture(
        queueIndex: 0,
        card: item.card,
        rating: SrsRating.good,
      );
      await provider.recordCardReview(item.card, SrsRating.good);
      expect(provider.remainingNewCards24h, 0);
      expect(provider.getStudyQueue(dueOnly: true), isEmpty);

      record.restore();

      expect(provider.newCardsIntroducedLast24h, 0);
      expect(provider.remainingNewCards24h, 1);
      expect(provider.getStudyQueue(dueOnly: true), hasLength(1));
    });

    test('re-rating a first review counts the card once', () async {
      final provider = await newProvider(maxNewCards: 2);
      provider.lessons.add(lessonWith('Rerate', [newVocab('새')]));

      final item = provider.getStudyQueue(dueOnly: true).single;
      final record = ReviewHistoryRecord.capture(
        queueIndex: 0,
        card: item.card,
        rating: SrsRating.again,
      );
      await provider.recordCardReview(item.card, SrsRating.again);

      record.restore();
      SrsService.processReview(item.card, SrsRating.good);

      expect(provider.newCardsIntroducedLast24h, 1);
      expect(provider.remainingNewCards24h, 1);
    });

    test('cram mode ignores both daily limits', () async {
      final provider = await newProvider(maxReviews: 1, maxNewCards: 1);
      provider.lessons.add(
        lessonWith('Cram', [
          for (var i = 0; i < 3; i++) newVocab('새$i'),
          for (var i = 0; i < 3; i++) dueVocab('복습$i'),
        ]),
      );

      expect(provider.getStudyQueue(dueOnly: false), hasLength(6));
    });

    test('recent mistakes ignore both daily limits', () async {
      final provider = await newProvider(maxReviews: 1, maxNewCards: 1);
      final now = DateTime.now();
      provider.lessons.add(
        lessonWith('Mistakes', [
          for (var i = 0; i < 3; i++)
            VocabItem(
              targetWord: '실수$i',
              translation: 'mistake $i',
              pos: 'nouns',
              cardTargetToNative: SrsCard(
                direction: CardDirection.targetToNative,
                status: SrsStatus.learning,
                dueDate: now.add(const Duration(hours: 1)),
                lastMistakeDate: now,
                lastRating: SrsRating.again,
              ),
            ),
        ]),
      );

      expect(provider.getStudyQueue(mistakesOnly: true), hasLength(3));
    });

    test('studying one lesson uses the same global new-card quota', () async {
      final provider = await newProvider(maxNewCards: 3);
      final first = lessonWith('First', [
        for (var i = 0; i < 2; i++) newVocab('하나$i'),
      ]);
      final second = lessonWith('Second', [
        for (var i = 0; i < 5; i++) newVocab('둘$i'),
      ]);
      provider.lessons.addAll([first, second]);

      final queue = provider.getStudyQueue(lessonId: second.id, dueOnly: true);
      expect(queue, hasLength(3));

      await provider.recordCardReview(queue.first.card, SrsRating.good);
      await provider.recordCardReview(queue[1].card, SrsRating.good);

      // Two slots are used up; one remains for any lesson.
      expect(provider.remainingNewCards24h, 1);
      expect(
        provider.getStudyQueue(lessonId: first.id, dueOnly: true),
        hasLength(1),
      );
    });
  });

  group('Labels', () {
    test('card chips say Hidden, New, Due, or the interval', () {
      final hidden = SrsCard(
        direction: CardDirection.targetToNative,
        isEnabled: false,
      );
      final fresh = SrsCard(direction: CardDirection.targetToNative);
      final due = SrsCard(
        direction: CardDirection.targetToNative,
        status: SrsStatus.review,
        dueDate: DateTime.now().subtract(const Duration(days: 1)),
      );
      final scheduled = SrsCard(
        direction: CardDirection.targetToNative,
        status: SrsStatus.review,
        interval: 6,
        dueDate: DateTime.now().add(const Duration(days: 6)),
      );

      expect(cardStatusLabel(hidden), 'Hidden');
      expect(cardStatusLabel(fresh), 'New');
      expect(cardStatusLabel(due), 'Due');
      expect(cardStatusLabel(scheduled), '6d');
    });

    test('the lesson Study button counts the cards the session will hold', () {
      String label(int due, int fresh, int remaining) => lessonStudyLabel(
        due: due,
        newCards: fresh,
        remainingNewCards: remaining,
      );

      expect(label(3, 20, 10), 'Study (13)');
      expect(label(3, 4, 10), 'Study (7)');
      expect(label(3, 20, 0), 'Study (3)');
      expect(label(0, 5, 0), 'Study');
      expect(label(0, 0, 10), 'Study');
    });

    test('a lesson row says how many words it has', () {
      expect(lessonWordsLabel(12), '12 words');
      expect(lessonWordsLabel(1), '1 word');
      expect(lessonWordsLabel(0), '0 words');
    });
  });
}
