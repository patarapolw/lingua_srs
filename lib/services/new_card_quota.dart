import 'dart:math';

/// How the daily new-card limit refills.
///
/// A plain rolling 24-hour window only refills a full day after a batch, so
/// studying even an hour earlier than the day before leaves part of the
/// batch locked, and the limit is hard to reach every day. Instead:
///
/// - A batch refills [refillAfter] (16 hours) after it was started: at most
///   the limit can be started in any 16 hours.
/// - On average, still at most the limit per 24 hours. An allowance grows by
///   the limit every 24 hours, holds at most [carryOverDays] + 1 days' worth,
///   and each new card started uses one. Starting a batch early uses some of
///   the carried-over day, and a later or skipped session earns it back.
///
/// The allowance never goes below zero: cards started past the limit (Learn
/// New Words, or two devices studying at once) hold back the next batch, but
/// are not paid back over the following days.
class NewCardQuota {
  NewCardQuota._();

  /// Every new card started in this span counts against the limit.
  static const refillAfter = Duration(hours: 16);

  /// Days of unused limit the allowance can carry over.
  static const carryOverDays = 1;

  /// The allowance earns the limit over this span.
  static const _earnPeriod = Duration(hours: 24);

  /// New cards that can be started at [now] under a limit of [limit] per
  /// day, given the times new cards were started ([startTimes], any order).
  /// [limit] 0 or less is unlimited and is not handled here.
  static int remaining(int limit, Iterable<DateTime> startTimes, DateTime now) {
    if (limit <= 0) throw ArgumentError.value(limit, 'limit');
    // Every start is replayed, from a full allowance before the first one.
    final starts = startTimes.where((t) => !t.isAfter(now)).toList()..sort();

    final recent = starts.where((t) => now.difference(t) < refillAfter).length;
    final windowLeft = limit - recent;

    // The allowance in cards × milliseconds of [_earnPeriod], so it earns
    // exactly [limit] per millisecond and stays an integer.
    final period = _earnPeriod.inMilliseconds;
    final capacity = limit * (carryOverDays + 1) * period;
    // A gap this long refills the allowance from empty; capping gaps at it
    // keeps the products small.
    final fullAfter = (carryOverDays + 1) * period;
    int earned(DateTime from, DateTime to) =>
        limit * min(fullAfter, to.difference(from).inMilliseconds);
    var allowance = capacity;
    var last = starts.isEmpty ? now : starts.first;
    for (final start in starts) {
      allowance = min(capacity, allowance + earned(last, start));
      allowance = max(0, allowance - period);
      last = start;
    }
    allowance = min(capacity, allowance + earned(last, now));

    return max(0, min(windowLeft, allowance ~/ period));
  }
}
