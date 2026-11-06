import '../models/lesson.dart';
import '../models/srs_card.dart';

/// Figures for the Study activity summary, worked out from the daily counts
/// and the cards. Every date is a local day at midnight.

DateTime _day(DateTime time) => DateTime(time.year, time.month, time.day);

DateTime _addDays(DateTime day, int days) =>
    DateTime(day.year, day.month, day.day + days);

/// Days in a row with at least one review, up to today. While today has no
/// reviews yet, the streak runs up to yesterday, so it does not look broken
/// before the day's study.
int studyStreak(Map<DateTime, int> dailyReviewCounts, DateTime now) {
  var day = _day(now);
  if ((dailyReviewCounts[day] ?? 0) <= 0) day = _addDays(day, -1);
  var streak = 0;
  while ((dailyReviewCounts[day] ?? 0) > 0) {
    streak++;
    day = _addDays(day, -1);
  }
  return streak;
}

/// Right and wrong answers among [ratings]: Good and Easy are right, Again
/// and Hard are wrong. A new card's first rating counts too.
({int right, int wrong}) rightWrongOf(Map<SrsRating, int> ratings) => (
  right: (ratings[SrsRating.good] ?? 0) + (ratings[SrsRating.easy] ?? 0),
  wrong: (ratings[SrsRating.again] ?? 0) + (ratings[SrsRating.hard] ?? 0),
);

/// Answers of each rating over the [days] days up to today, Again first.
/// [rightWrongOf] splits them into right and wrong.
Map<SrsRating, int> recentRatings(
  Map<DateTime, Map<SrsRating, int>> dailyRatingCounts,
  DateTime now, {
  int days = 30,
}) {
  final today = _day(now);
  final first = _addDays(today, -(days - 1));
  final totals = {for (final rating in SrsRating.values) rating: 0};
  for (final entry in dailyRatingCounts.entries) {
    if (entry.key.isBefore(first) || entry.key.isAfter(today)) continue;
    for (final MapEntry(key: rating, value: count) in entry.value.entries) {
      totals[rating] = totals[rating]! + count;
    }
  }
  return totals;
}

/// Cards coming due on each of the next [days] days, today first. Cards
/// already overdue count today. New cards are left out, since they are not
/// due (they have their own daily limit), and so are hidden and suspended
/// cards. A card shared by several lessons is counted once.
List<int> dueForecast(Iterable<Lesson> lessons, DateTime now, {int days = 7}) {
  final today = _day(now);
  final counts = List.filled(days, 0);
  final seenCardIds = <String>{};
  for (final vocab in lessons.expand((lesson) => lesson.vocabularies)) {
    for (final card in [vocab.cardTargetToNative, vocab.cardNativeToTarget]) {
      if (!card.isActive || card.status == SrsStatus.isNew) continue;
      if (!seenCardIds.add(card.id)) continue;
      final due = _day(card.dueDate);
      // Counted in whole days, so a clock change can't shift a card a day.
      final index = due.isBefore(today)
          ? 0
          : DateTime.utc(due.year, due.month, due.day)
                .difference(DateTime.utc(today.year, today.month, today.day))
                .inDays;
      if (index < days) counts[index]++;
    }
  }
  return counts;
}
