import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/lesson.dart';
import 'package:lingua_srs/models/srs_card.dart';
import 'package:lingua_srs/models/vocab_item.dart';
import 'package:lingua_srs/services/study_stats.dart';

final _now = DateTime(2026, 11, 6, 15, 30);
final _today = DateTime(2026, 11, 6);

DateTime _daysAgo(int days) => DateTime(2026, 11, 6 - days);

VocabItem _word(String id, SrsCard card) => VocabItem(
  id: id,
  targetWord: id,
  translation: id,
  pos: 'nouns',
  cardTargetToNative: card,
  cardNativeToTarget: SrsCard(
    id: '$id-nt',
    direction: CardDirection.nativeToTarget,
    isEnabled: false,
  ),
);

SrsCard _due(String id, DateTime dueDate, {bool suspended = false}) => SrsCard(
  id: id,
  direction: CardDirection.targetToNative,
  status: SrsStatus.review,
  interval: 3,
  lastReviewed: dueDate.subtract(const Duration(days: 3)),
  dueDate: dueDate,
  isSuspended: suspended,
);

void main() {
  group('studyStreak', () {
    test('counts days in a row up to today', () {
      final counts = {
        _today: 5,
        _daysAgo(1): 3,
        _daysAgo(2): 1,
        _daysAgo(4): 9, // after a gap: not part of the streak
      };
      expect(studyStreak(counts, _now), 3);
    });

    test('runs up to yesterday while today has no reviews yet', () {
      expect(studyStreak({_daysAgo(1): 3, _daysAgo(2): 1}, _now), 2);
    });

    test('is 0 when neither today nor yesterday had reviews', () {
      expect(studyStreak({_daysAgo(2): 3}, _now), 0);
      expect(studyStreak({}, _now), 0);
    });

    test('crosses the start of a month', () {
      final counts = {
        DateTime(2026, 12, 2): 1,
        DateTime(2026, 12, 1): 1,
        DateTime(2026, 11, 30): 1,
      };
      expect(studyStreak(counts, DateTime(2026, 12, 2, 9)), 3);
    });
  });

  group('right and wrong', () {
    test('Good and Easy are right, Again and Hard are wrong', () {
      expect(
        rightWrongOf({
          SrsRating.again: 1,
          SrsRating.hard: 2,
          SrsRating.good: 3,
          SrsRating.easy: 4,
        }),
        (right: 7, wrong: 3),
      );
    });

    test('sums the last 30 days only', () {
      final counts = {
        _today: {SrsRating.good: 4, SrsRating.again: 1},
        _daysAgo(29): {SrsRating.easy: 2, SrsRating.hard: 1},
        _daysAgo(30): {SrsRating.again: 50}, // 31 days ago with today
        DateTime(2026, 11, 7): {SrsRating.again: 50}, // tomorrow
      };
      expect(recentRatings(counts, _now), {
        SrsRating.again: 1,
        SrsRating.hard: 1,
        SrsRating.good: 4,
        SrsRating.easy: 2,
      });
    });
  });

  group('dueForecast', () {
    test('counts cards due on each of the next 7 days', () {
      final lesson = Lesson(
        title: 'L',
        vocabularies: [
          _word('overdue', _due('overdue', _daysAgo(3))),
          _word('later-today', _due('later-today', DateTime(2026, 11, 6, 22))),
          _word('tomorrow', _due('tomorrow', DateTime(2026, 11, 7, 8))),
          _word('in-6-days', _due('in-6-days', DateTime(2026, 11, 12))),
          _word('in-7-days', _due('in-7-days', DateTime(2026, 11, 13))),
        ],
      );

      expect(dueForecast([lesson], _now), [2, 1, 0, 0, 0, 0, 1]);
    });

    test('leaves out new, hidden and suspended cards', () {
      final lesson = Lesson(
        title: 'L',
        vocabularies: [
          _word(
            'new',
            SrsCard(id: 'new', direction: CardDirection.targetToNative),
          ),
          _word('suspended', _due('suspended', _today, suspended: true)),
          _word('hidden', _due('hidden', _today)..isEnabled = false),
        ],
      );

      expect(dueForecast([lesson], _now), [0, 0, 0, 0, 0, 0, 0]);
    });

    test('counts a card shared by two lessons once', () {
      final shared = _word('shared', _due('shared', _today));
      final first = Lesson(title: 'A', vocabularies: [shared]);
      final second = Lesson(
        title: 'B',
        vocabularies: [
          VocabItem(
            id: 'shared',
            targetWord: 'shared',
            translation: 'shared',
            pos: 'nouns',
          )..shared = shared.shared,
        ],
      );

      expect(dueForecast([first, second], _now).first, 1);
    });
  });
}
