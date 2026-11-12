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

/// When each card comes due, earliest first. New cards are left out, since
/// they are not due (they have their own daily limit), and so are hidden and
/// suspended cards. A card shared by several lessons is counted once.
List<DateTime> dueTimes(Iterable<Lesson> lessons) {
  final times = <DateTime>[];
  final seenCardIds = <String>{};
  for (final vocab in lessons.expand((lesson) => lesson.vocabularies)) {
    for (final card in [vocab.cardTargetToNative, vocab.cardNativeToTarget]) {
      if (!card.isActive || card.status == SrsStatus.isNew) continue;
      if (!seenCardIds.add(card.id)) continue;
      times.add(card.dueDate);
    }
  }
  return times..sort();
}

/// Cards coming due on each of the next [days] days, today first. Cards
/// already overdue count today. Which cards count is as in [dueTimes].
List<int> dueForecast(Iterable<Lesson> lessons, DateTime now, {int days = 7}) {
  final today = _day(now);
  final counts = List.filled(days, 0);
  for (final dueDate in dueTimes(lessons)) {
    final due = _day(dueDate);
    // Counted in whole days, so a clock change can't shift a card a day.
    final index = due.isBefore(today)
        ? 0
        : DateTime.utc(
            due.year,
            due.month,
            due.day,
          ).difference(DateTime.utc(today.year, today.month, today.day)).inDays;
    if (index < days) counts[index]++;
  }
  return counts;
}

/// The start of the clock hour [now] is in: the first hour of
/// [dueForecastHourly].
DateTime forecastHourStart(DateTime now) =>
    DateTime(now.year, now.month, now.day, now.hour);

/// Cards coming due in each of the next [hours] hours, by clock hour: the
/// first is the hour [now] is in ([forecastHourStart]), and it also counts
/// the cards already overdue. The rest are an hour apart in real time, so
/// on the night the clocks change one clock hour shows twice or not at all,
/// but no card is counted twice or left out. [times] are from [dueTimes].
List<int> dueForecastHourly(
  Iterable<DateTime> times,
  DateTime now, {
  int hours = 48,
}) {
  final start = forecastHourStart(now);
  final counts = List.filled(hours, 0);
  for (final due in times) {
    final index = due.isBefore(start) ? 0 : due.difference(start).inHours;
    if (index < hours) counts[index]++;
  }
  return counts;
}

/// The [times] after [from], up to and including [until].
int countDueBetween(Iterable<DateTime> times, DateTime from, DateTime until) =>
    times.where((time) => time.isAfter(from) && !time.isAfter(until)).length;

/// [count] with commas between thousands, such as "1,234".
String formatCount(int count) {
  final digits = count.abs().toString();
  final buffer = StringBuffer(count < 0 ? '-' : '');
  for (var index = 0; index < digits.length; index++) {
    if (index > 0 && (digits.length - index) % 3 == 0) buffer.write(',');
    buffer.write(digits[index]);
  }
  return buffer.toString();
}

/// New cards started on each of the [days] days up to today, oldest first.
/// A day's count is the larger of [dailyNewCardCounts] (counted as cards
/// are started) and the cards whose first review ([SrsCard.introducedAt])
/// fell on that day, so days from before new cards were counted are filled
/// in from the cards. Resetting a card clears that time, so filled-in days
/// can be low.
List<int> newCardsPerDay(
  Map<DateTime, int> dailyNewCardCounts,
  Iterable<Lesson> lessons,
  DateTime now, {
  int days = 30,
}) {
  final today = _day(now);
  final first = _addDays(today, -(days - 1));
  final fromCards = <DateTime, int>{};
  final seenCardIds = <String>{};
  for (final vocab in lessons.expand((lesson) => lesson.vocabularies)) {
    for (final card in [vocab.cardTargetToNative, vocab.cardNativeToTarget]) {
      final introducedAt = card.introducedAt;
      if (introducedAt == null || !seenCardIds.add(card.id)) continue;
      final day = _day(introducedAt);
      fromCards[day] = (fromCards[day] ?? 0) + 1;
    }
  }
  final counts = <int>[];
  for (var index = 0; index < days; index++) {
    final day = _addDays(first, index);
    final counted = dailyNewCardCounts[day] ?? 0;
    final filled = fromCards[day] ?? 0;
    counts.add(counted > filled ? counted : filled);
  }
  return counts;
}

/// Enabled, unsuspended cards not started yet. A card shared by several
/// lessons is counted once.
int newCardsLeft(Iterable<Lesson> lessons) {
  final ids = <String>{};
  for (final vocab in lessons.expand((lesson) => lesson.vocabularies)) {
    for (final card in [vocab.cardTargetToNative, vocab.cardNativeToTarget]) {
      if (card.isNewCard) ids.add(card.id);
    }
  }
  return ids.length;
}

/// Days to start [left] new cards at [limit] a day, rounded up, or null
/// when there is nothing left or the limit is unlimited (0).
int? daysToFinishNewCards(int left, int limit) {
  if (left <= 0 || limit <= 0) return null;
  return (left + limit - 1) ~/ limit;
}
