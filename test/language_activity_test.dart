import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/srs_card.dart';
import 'package:lingua_srs/services/language_activity.dart';
import 'package:lingua_srs/services/sync_records.dart';

void main() {
  final day = DateTime(2026, 11, 12);
  final morning = DateTime(2026, 11, 12, 9);
  final noon = DateTime(2026, 11, 12, 12);

  group('ActivityShare.of', () {
    final total = ActivityShare(
      count: 10,
      ratings: {SrsRating.good: 6, SrsRating.again: 2},
      newCards: 3,
    );
    final byLanguage = {
      'zh-tw': ActivityShare(
        count: 4,
        ratings: {SrsRating.good: 3, SrsRating.again: 1},
        newCards: 1,
      ),
    };

    test('a language has its recorded share', () {
      final share = ActivityShare.of(
        total,
        byLanguage,
        'zh-tw',
        takesRest: false,
      );
      expect(share.count, 4);
      expect(share.ratings, {SrsRating.good: 3, SrsRating.again: 1});
      expect(share.newCards, 1);
    });

    test('a language with nothing recorded has nothing', () {
      final share = ActivityShare.of(total, byLanguage, 'ja', takesRest: false);
      expect(share.isEmpty, isTrue);
    });

    test('the language that takes the rest gets what no share has', () {
      final share = ActivityShare.of(total, byLanguage, 'ko', takesRest: true);
      expect(share.count, 6);
      expect(share.ratings, {SrsRating.good: 3, SrsRating.again: 1});
      expect(share.newCards, 2);
    });

    test('the rest is added to that language\'s own share', () {
      final share = ActivityShare.of(
        total,
        {...byLanguage, 'ko': ActivityShare(count: 1, newCards: 1)},
        'ko',
        takesRest: true,
      );
      expect(share.count, 6);
      expect(share.newCards, 2);
    });

    test('shares that add up to more than the total leave no rest', () {
      final share = ActivityShare.of(
        ActivityShare(count: 2),
        {'zh-tw': ActivityShare(count: 5)},
        'ko',
        takesRest: true,
      );
      expect(share.isEmpty, isTrue);
    });
  });

  group('LanguageActivity', () {
    test('counts a review under its language, day and rating', () {
      final activity = LanguageActivity()
        ..record('ko', morning, SrsRating.good, newCard: true, timed: true)
        ..record('ko', noon, SrsRating.again, newCard: false, timed: false)
        ..record('zh-tw', noon, SrsRating.good, newCard: false, timed: true);

      final shares = activity.sharesOn(day);
      expect(shares.keys, {'ko', 'zh-tw'});
      expect(shares['ko']!.count, 2);
      expect(shares['ko']!.ratings, {SrsRating.good: 1, SrsRating.again: 1});
      expect(shares['ko']!.newCards, 1);
      expect(shares['zh-tw']!.count, 1);
      // Only reviews that count toward the 24-hour limit keep their time.
      expect(activity.reviewTimes['ko'], [morning]);
      expect(activity.reviewTimes['zh-tw'], [noon]);
    });

    test('undo takes back the review, its new card and its time', () {
      final activity = LanguageActivity()
        ..record('ko', morning, SrsRating.good, newCard: true, timed: true)
        ..undo('ko', morning, SrsRating.good, newCard: true);

      expect(activity.sharesOn(day), isEmpty);
      expect(activity.days, isEmpty);
      expect(activity.reviewTimes['ko'], isEmpty);
    });

    test('undoing a review that was never recorded here changes nothing', () {
      final activity = LanguageActivity()
        ..record('ko', morning, SrsRating.good, newCard: false, timed: true)
        ..undo('zh-tw', morning, SrsRating.good, newCard: false);

      expect(activity.sharesOn(day)['ko']!.count, 1);
    });

    test('recount moves a review to another rating', () {
      final activity = LanguageActivity()
        ..record('ko', morning, SrsRating.good, newCard: false, timed: true)
        ..recount('ko', morning, SrsRating.good, SrsRating.hard);

      final share = activity.sharesOn(day)['ko']!;
      expect(share.count, 1);
      expect(share.ratings, {SrsRating.hard: 1});
    });

    test('prune drops review times older than 24 hours', () {
      final activity = LanguageActivity()
        ..record('ko', morning, SrsRating.good, newCard: false, timed: true)
        ..record('ko', noon, SrsRating.good, newCard: false, timed: true)
        ..prune(morning.add(const Duration(hours: 25)));

      expect(activity.reviewTimes['ko'], [noon]);
      // The day's counts stay.
      expect(activity.sharesOn(day)['ko']!.count, 2);
    });

    test('is saved and loaded', () {
      final activity = LanguageActivity()
        ..record('ko', morning, SrsRating.good, newCard: true, timed: true)
        ..record('zh-tw', noon, SrsRating.again, newCard: false, timed: true);

      final loaded = LanguageActivity.fromJson(
        jsonDecode(jsonEncode(activity.toJson())),
      );

      expect(loaded.sharesOn(day)['ko']!.count, 1);
      expect(loaded.sharesOn(day)['ko']!.newCards, 1);
      expect(loaded.sharesOn(day)['zh-tw']!.ratings, {SrsRating.again: 1});
      expect(loaded.reviewTimes['ko'], [morning]);
      expect(loaded.reviewTimes['zh-tw'], [noon]);
    });

    test('anything that is not its format loads as nothing', () {
      for (final json in [
        null,
        'text',
        3,
        <String, dynamic>{'days': 'x'},
      ]) {
        final loaded = LanguageActivity.fromJson(json);
        expect(loaded.days, isEmpty);
        expect(loaded.reviewTimes, isEmpty);
      }
    });
  });

  group('activity record', () {
    Map<String, dynamic> recordOf(LanguageActivity? activity) =>
        SyncSnapshot.build(
          lessons: const [],
          sentences: const [],
          mergeHistory: const [],
          aiDiscussions: const {},
          lessonOrder: const {},
          settings: const SyncSettings(
            maxReviews24h: 100,
            maxNewCards24h: 10,
            autoplayAudio: true,
            pronunciationOptions: {},
          ),
          dailyReviewCounts: {day: 3},
          reviewTimestamps: [morning, noon],
          languageActivity: activity,
          deviceId: 'device',
        ).entries.singleWhere((e) => e.key.kind == SyncKinds.activity).value;

    test('has each language\'s share of the day', () {
      final record = recordOf(
        LanguageActivity()
          ..record('ko', morning, SrsRating.good, newCard: true, timed: true)
          ..record('zh-tw', noon, SrsRating.again, newCard: false, timed: true),
      );

      expect(record['count'], 3);
      final languages = record['languages'] as Map;
      expect(languages.keys, {'ko', 'zh-tw'});
      expect(languages['ko']['count'], 1);
      expect(languages['ko']['newCards'], 1);
      expect(languages['ko']['reviews'], [morning.toUtc().toIso8601String()]);
      expect(languages['zh-tw']['ratings'], {'again': 1});
    });

    test('is as before when no review was recorded with a language', () {
      for (final activity in [null, LanguageActivity()]) {
        expect(recordOf(activity).containsKey('languages'), isFalse);
      }
    });
  });
}
