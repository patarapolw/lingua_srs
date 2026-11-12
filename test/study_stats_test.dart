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

  group('dueTimes', () {
    test('lists studied cards earliest first, each shared card once', () {
      final shared = _word('shared', _due('shared', DateTime(2026, 11, 7)));
      final lesson = Lesson(
        title: 'L',
        vocabularies: [
          _word('late', _due('late', DateTime(2026, 11, 9))),
          shared,
          _word('early', _due('early', DateTime(2026, 11, 1))),
          _word(
            'new',
            SrsCard(id: 'new', direction: CardDirection.targetToNative),
          ),
          _word('suspended', _due('suspended', _today, suspended: true)),
        ],
      );
      final other = Lesson(
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

      expect(dueTimes([lesson, other]), [
        DateTime(2026, 11, 1),
        DateTime(2026, 11, 7),
        DateTime(2026, 11, 9),
      ]);
    });
  });

  group('dueForecastHourly', () {
    test('counts cards by clock hour, overdue ones in the first', () {
      // _now is 15:30, so the first hour is 15:00 to 16:00.
      final times = [
        _daysAgo(2),
        DateTime(2026, 11, 6, 15, 10),
        DateTime(2026, 11, 6, 15, 59),
        DateTime(2026, 11, 6, 16),
        DateTime(2026, 11, 6, 18, 45),
        DateTime(2026, 11, 8, 14, 59),
        DateTime(2026, 11, 8, 15),
      ];

      final counts = dueForecastHourly(times, _now);

      expect(counts, hasLength(48));
      expect(counts[0], 3);
      expect(counts[1], 1);
      expect(counts[3], 1);
      expect(counts[47], 1);
      // The card at 15:00 two days on is past the 48 hours.
      expect(counts.fold(0, (sum, count) => sum + count), 6);
    });

    test('takes the number of hours', () {
      final times = [DateTime(2026, 11, 6, 20)];

      expect(dueForecastHourly(times, _now, hours: 6), [0, 0, 0, 0, 0, 1]);
      expect(dueForecastHourly(times, _now, hours: 3), [0, 0, 0]);
    });

    test('starts at the clock hour now is in', () {
      expect(forecastHourStart(_now), DateTime(2026, 11, 6, 15));
    });
  });

  test('countDueBetween counts the times after from, up to until', () {
    final times = [
      DateTime(2026, 11, 6, 15, 30),
      DateTime(2026, 11, 6, 16),
      DateTime(2026, 11, 6, 21, 30),
      DateTime(2026, 11, 6, 21, 31),
    ];

    expect(countDueBetween(times, _now, DateTime(2026, 11, 6, 21, 30)), 2);
  });

  test('formatCount puts commas between thousands', () {
    expect(formatCount(0), '0');
    expect(formatCount(999), '999');
    expect(formatCount(1000), '1,000');
    expect(formatCount(1234), '1,234');
    expect(formatCount(123456), '123,456');
    expect(formatCount(1234567), '1,234,567');
    expect(formatCount(-1234), '-1,234');
  });

  group('newCardsPerDay', () {
    SrsCard started(String id, DateTime at) => SrsCard(
      id: id,
      direction: CardDirection.targetToNative,
      status: SrsStatus.review,
      dueDate: at.add(const Duration(days: 1)),
      introducedAt: at,
    );

    test('one count per day, oldest first, today last', () {
      final perDay = newCardsPerDay(
        {_today: 4, _daysAgo(2): 1},
        const [],
        _now,
        days: 3,
      );

      expect(perDay, [1, 0, 4]);
    });

    test('days without a count are filled in from the cards', () {
      final lesson = Lesson(title: 'L')
        ..vocabularies.addAll([
          _word('a', started('a', _daysAgo(1).add(const Duration(hours: 9)))),
          _word('b', started('b', _daysAgo(1).add(const Duration(hours: 20)))),
          _word('c', started('c', _now)),
        ]);

      expect(newCardsPerDay({}, [lesson], _now, days: 3), [0, 2, 1]);
    });

    test('a counted day is not counted twice', () {
      final lesson = Lesson(title: 'L')
        ..vocabularies.addAll([
          _word('a', started('a', _now)),
          _word('b', started('b', _now)),
        ]);

      // Counted 3 (one card was reset since); the cards show 2.
      expect(newCardsPerDay({_today: 3}, [lesson], _now, days: 1), [3]);
      // Counted 1 (the other was started on a device with an older app).
      expect(newCardsPerDay({_today: 1}, [lesson], _now, days: 1), [2]);
    });

    test('a card shared by two lessons counts once', () {
      final card = started('shared', _now);
      final first = Lesson(title: 'A')..vocabularies.add(_word('x', card));
      final second = Lesson(title: 'B')..vocabularies.add(_word('y', card));

      expect(newCardsPerDay({}, [first, second], _now, days: 1), [1]);
    });

    test('older days are left out', () {
      final lesson = Lesson(title: 'L')
        ..vocabularies.add(_word('a', started('a', _daysAgo(40))));

      expect(
        newCardsPerDay({_daysAgo(31): 5}, [lesson], _now),
        everyElement(0),
      );
      expect(newCardsPerDay({}, [lesson], _now), hasLength(30));
    });
  });

  group('newCardsLeft', () {
    test('counts enabled, unsuspended cards not started yet', () {
      final lesson = Lesson(title: 'L')
        ..vocabularies.addAll([
          _word(
            'new1',
            SrsCard(id: 'new1', direction: CardDirection.targetToNative),
          ),
          _word(
            'new2',
            SrsCard(id: 'new2', direction: CardDirection.targetToNative),
          ),
          _word(
            'suspended',
            SrsCard(
              id: 'suspended',
              direction: CardDirection.targetToNative,
              isSuspended: true,
            ),
          ),
          _word('due', _due('due', _today)),
        ]);

      // Each word's other direction is disabled, so it is not counted.
      expect(newCardsLeft([lesson]), 2);
    });
  });

  group('daysToFinishNewCards', () {
    test('rounds up', () {
      expect(daysToFinishNewCards(312, 10), 32);
      expect(daysToFinishNewCards(30, 10), 3);
      expect(daysToFinishNewCards(1, 10), 1);
    });

    test('null with nothing left or no limit', () {
      expect(daysToFinishNewCards(0, 10), isNull);
      expect(daysToFinishNewCards(50, 0), isNull);
    });
  });
}
