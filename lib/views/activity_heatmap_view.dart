import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/lesson.dart';
import '../models/srs_card.dart';
import '../models/vocab_item.dart';
import '../providers/app_provider.dart';
import '../services/study_stats.dart';

const _leechLapseThreshold = 8;

/// The widest the content gets: room for a year of the calendar (53 weeks of
/// 16 pixels after 32 of weekday labels), so on a desktop window it doesn't
/// scroll and the charts below don't stretch across the whole screen.
const _maxContentWidth = 880.0;

/// From this content width, the three summary tiles share one row. Less than
/// [_twoColumnWidth], so a tablet in portrait gets the row too, instead of
/// tiles stretched wide around a few words.
const _summaryRowWidth = 600.0;

/// From this content width, Next 7 days and New cards sit side by side.
const _twoColumnWidth = 720.0;

const _pagePadding = 20.0;

/// Colours shared with other screens: right and wrong as in the study
/// session's progress bar, and due as in the lesson list's Due badge.
final _rightColor = Colors.green.shade600;
final _wrongColor = Colors.red.shade600;
final _dueColor = Colors.amber.shade800;

/// The shade, 0 to 4, of a day with [count] reviews, on a scale whose top is
/// [busiest]: the review limit, or the busiest day shown when there is no
/// limit (see [activityScaleTop]). A day over the top gets the darkest shade.
/// Shades are quarters of the top, so a calendar
/// of 100-review days still shows which days were heavier. 0 is no reviews.
@visibleForTesting
int activityLevel(int count, int busiest) {
  if (count <= 0 || busiest <= 0) return 0;
  return (count * 4 / busiest).ceil().clamp(1, 4);
}

/// The review counts that get shade [level] (1 to 4), as `(lowest, highest)`,
/// or null when no count does (with a quiet busiest day, some shades are
/// skipped).
@visibleForTesting
(int, int)? activityLevelRange(int level, int busiest) {
  final lowest = (level - 1) * busiest ~/ 4 + 1;
  final highest = level * busiest ~/ 4;
  return lowest > highest ? null : (lowest, highest);
}

/// The number of reviews that the calendar's darkest shade ends at: the
/// 24-hour review [limit], so a shade means the same share of a full day from
/// one month to the next, or with no limit (0) the [busiest] day shown.
@visibleForTesting
int activityScaleTop({required int limit, required int busiest}) =>
    limit > 0 ? limit : busiest;

/// The Monday of [day]'s week, at midnight. Built from the day number rather
/// than by subtracting days, so a clock change in between can't land it on
/// the Sunday before.
@visibleForTesting
DateTime calendarWeekStart(DateTime day) =>
    DateTime(day.year, day.month, day.day - (day.weekday - DateTime.monday));

/// New cards started in the last 24 hours against the daily limit (0 is
/// unlimited), e.g. "4 of 10 started in the last 24 hours". Learn New Words
/// can go past the limit.
@visibleForTesting
String newCardsLimitText(int started, int limit) => limit > 0
    ? '${formatCount(started)} of ${formatCount(limit)} started in the last '
          '24 hours'
    : '${formatCount(started)} started in the last 24 hours (no limit)';

/// Under the new-cards chart: its bars are calendar days, while the limit
/// refills 16 hours after a batch (see `NewCardQuota`), so a bar and the
/// "started in the last 24 hours" line can differ from the limit line.
@visibleForTesting
String newCardsChartCaption(int limit) => limit > 0
    ? '*per calendar day. The limit refills 16 hours after a batch, '
          'and averages out to the limit per day.'
    : '*per calendar day.';

/// The new cards not started yet, and how long they take at [limit] a day,
/// e.g. "312 new left, about 32 days at 10 a day".
@visibleForTesting
String newCardsLeftText(int left, int limit) {
  if (left <= 0) return 'Every card has been started';
  final cards = '${formatCount(left)} new ${left == 1 ? 'card' : 'cards'} left';
  final days = daysToFinishNewCards(left, limit);
  if (days == null) return cards;
  return '$cards, about ${formatCount(days)} '
      '${days == 1 ? 'day' : 'days'} at ${formatCount(limit)} a day';
}

class ActivityHeatmapView extends StatefulWidget {
  const ActivityHeatmapView({super.key});

  @override
  State<ActivityHeatmapView> createState() => _ActivityHeatmapViewState();
}

class _ActivityHeatmapViewState extends State<ActivityHeatmapView> {
  final _scrollController = ScrollController();
  bool _scrolledToEnd = false;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToEnd() {
    if (_scrolledToEnd) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _scrolledToEnd) return;
      if (!_scrollController.hasClients) {
        // Not laid out yet: try again after the next frame.
        _scrollToEnd();
        return;
      }
      _scrolledToEnd = true;
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final today = DateTime.now();
    return Scaffold(
      appBar: AppBar(title: const Text('Study activity')),
      body: Consumer<AppProvider>(
        builder: (context, provider, _) {
          final counts = provider.dailyReviewCounts;
          final yearStart = DateTime(today.year, today.month, today.day - 364);
          final earliest = counts.entries
              .where(
                (entry) => entry.value > 0 && !entry.key.isBefore(yearStart),
              )
              .map((entry) => entry.key)
              .fold<DateTime?>(
                null,
                (min, date) => min == null || date.isBefore(min) ? date : min,
              );
          final firstDay = earliest ?? yearStart;
          final calendarStart = calendarWeekStart(firstDay);
          final calendarDays = DateTime.utc(today.year, today.month, today.day)
              .difference(
                DateTime.utc(
                  calendarStart.year,
                  calendarStart.month,
                  calendarStart.day,
                ),
              )
              .inDays;
          final weekCount = (calendarDays ~/ 7) + 1;
          final weeks = [
            for (var week = 0; week < weekCount; week++)
              DateTime(
                calendarStart.year,
                calendarStart.month,
                calendarStart.day + week * 7,
              ),
          ];

          final leeches = _findLeeches(provider.lessons);
          final stageCounts = _studyStageCounts(provider.lessons);
          final maxStageCount = stageCounts.values.fold(
            0,
            (maximum, count) => count > maximum ? count : maximum,
          );
          final todayDate = DateTime(today.year, today.month, today.day);
          final shownCounts = [
            for (final entry in counts.entries)
              if (!entry.key.isBefore(firstDay) &&
                  !entry.key.isAfter(todayDate))
                entry.value,
          ];
          final total = shownCounts.fold(0, (sum, count) => sum + count);
          final busiest = shownCounts.fold(
            0,
            (maximum, count) => count > maximum ? count : maximum,
          );
          final hasReviewLimit = provider.maxReviews24h > 0;
          final scaleTop = activityScaleTop(
            limit: provider.maxReviews24h,
            busiest: busiest,
          );
          final ratingCounts = provider.dailyRatingCounts;
          final newCardCounts = provider.dailyNewCardCounts;
          final forecast = dueForecast(provider.lessons, today);
          final newPerDay = newCardsPerDay(
            newCardCounts,
            provider.lessons,
            today,
          );
          final newLeft = newCardsLeft(provider.lessons);
          final maxDue = forecast.fold(
            0,
            (maximum, count) => count > maximum ? count : maximum,
          );
          final hasActivity = total > 0 || leeches.isNotEmpty;
          final hasCards = maxStageCount > 0;

          if (!hasActivity && !hasCards) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.calendar_month_outlined, size: 40),
                    SizedBox(height: 12),
                    Text('No study activity yet'),
                    SizedBox(height: 4),
                    Text('Review vocabulary to see your activity here.'),
                  ],
                ),
              ),
            );
          }

          if (hasActivity) _scrollToEnd();
          return LayoutBuilder(
            builder: (context, constraints) {
              final available = constraints.maxWidth - 2 * _pagePadding;
              final contentWidth = available < _maxContentWidth
                  ? available
                  : _maxContentWidth;
              // Centred by padding rather than a narrower list, so the whole
              // window still scrolls and the scrollbar stays at its edge.
              final sidePadding = (constraints.maxWidth - contentWidth) / 2;
              final forecastSection = maxDue > 0
                  ? _forecastSection(
                      context,
                      forecast: forecast,
                      today: today,
                      maxDue: maxDue,
                      maxReviews24h: provider.maxReviews24h,
                    )
                  : null;
              final newCardsSection =
                  newPerDay.any((count) => count > 0) || newLeft > 0
                  ? _newCardsSection(
                      context,
                      perDay: newPerDay,
                      today: today,
                      startedLast24h: provider.newCardsIntroducedLast24h,
                      limit: provider.maxNewCards24h,
                      left: newLeft,
                    )
                  : null;
              return ListView(
                padding: EdgeInsets.symmetric(
                  horizontal: sidePadding,
                  vertical: _pagePadding,
                ),
                children: [
                  // Before the first review, the cards waiting are still worth
                  // showing, under a note in place of the calendar.
                  if (!hasActivity) ...[
                    Row(
                      children: [
                        const Icon(Icons.calendar_month_outlined),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'No study activity yet',
                                style: theme.textTheme.titleMedium,
                              ),
                              const Text(
                                'Review vocabulary to see your activity here.',
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                  ] else ...[
                    _summary(
                      context,
                      wide: contentWidth >= _summaryRowWidth,
                      streak: studyStreak(counts, today),
                      todayReviews: counts[todayDate] ?? 0,
                      todayNew: newCardCounts[todayDate] ?? 0,
                      recent: recentRatings(ratingCounts, today),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      '${formatCount(total)} ${total == 1 ? 'review' : 'reviews'} '
                      'in the past year',
                      style: theme.textTheme.titleSmall,
                    ),
                    const SizedBox(height: 16),
                    // As wide as the calendar, up to the screen, so the legend
                    // ends under the newest week instead of at the far edge of
                    // a wide window.
                    Align(
                      alignment: Alignment.centerLeft,
                      child: IntrinsicWidth(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SingleChildScrollView(
                              controller: _scrollController,
                              scrollDirection: Axis.horizontal,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      const SizedBox(width: 32),
                                      for (
                                        var index = 0;
                                        index < weeks.length;
                                        index++
                                      )
                                        SizedBox(
                                          width: 16,
                                          height: 56,
                                          child: Center(
                                            child: RotatedBox(
                                              quarterTurns: 3,
                                              child: Text(
                                                _monthLabel(weeks, index),
                                                maxLines: 1,
                                                style:
                                                    theme.textTheme.labelSmall,
                                              ),
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      SizedBox(
                                        width: 28,
                                        child: Column(
                                          children: [
                                            // One row per day, Monday first, as in
                                            // calendarWeekStart.
                                            for (final label in const [
                                              'Mon',
                                              '',
                                              'Wed',
                                              '',
                                              'Fri',
                                              '',
                                              '',
                                            ])
                                              SizedBox(
                                                height: 16,
                                                child: Text(
                                                  label,
                                                  style: theme
                                                      .textTheme
                                                      .labelSmall,
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                      for (final week in weeks)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            right: 4,
                                          ),
                                          child: Column(
                                            children: [
                                              for (
                                                var dayIndex = 0;
                                                dayIndex < 7;
                                                dayIndex++
                                              )
                                                _dayCell(
                                                  context,
                                                  DateTime(
                                                    week.year,
                                                    week.month,
                                                    week.day + dayIndex,
                                                  ),
                                                  firstDay,
                                                  today,
                                                  counts,
                                                  ratingCounts,
                                                  newCardCounts,
                                                  scaleTop,
                                                ),
                                            ],
                                          ),
                                        ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 16),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                // The scale's two ends in numbers, since the
                                // squares' tooltips need a hover or a long
                                // press to find. A day can go over the limit
                                // (first reviews and same-day repeats don't
                                // count towards it), hence the plus.
                                Text(
                                  scaleTop > 0 ? '0' : 'Less',
                                  key: const ValueKey('legend-low'),
                                  style: theme.textTheme.labelSmall,
                                ),
                                const SizedBox(width: 6),
                                for (var level = 0; level <= 4; level++)
                                  Tooltip(
                                    message: _legendLabel(
                                      level,
                                      scaleTop,
                                      isLimit: hasReviewLimit,
                                    ),
                                    child: Container(
                                      width: 12,
                                      height: 12,
                                      margin: const EdgeInsets.only(right: 4),
                                      decoration: BoxDecoration(
                                        color: _activityColor(
                                          theme.colorScheme,
                                          level,
                                        ),
                                        borderRadius: BorderRadius.circular(2),
                                      ),
                                    ),
                                  ),
                                Text(
                                  scaleTop > 0
                                      ? '${formatCount(scaleTop)}'
                                            '${hasReviewLimit ? '+' : ''} '
                                            '${scaleTop == 1 ? 'review' : 'reviews'} '
                                            'a day'
                                      : 'More',
                                  key: const ValueKey('legend-high'),
                                  style: theme.textTheme.labelSmall,
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],
                  Text('Cards by stage', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Wrap(
                    children: [
                      for (final (index, entry)
                          in stageCounts.entries.indexed) ...[
                        if (index > 0) const Text(' · '),
                        _stageCount(entry.key, entry.value),
                      ],
                    ],
                  ),
                  const SizedBox(height: 24),
                  if (forecastSection != null &&
                      newCardsSection != null &&
                      contentWidth >= _twoColumnWidth) ...[
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: forecastSection),
                        const SizedBox(width: 40),
                        Expanded(child: newCardsSection),
                      ],
                    ),
                    const SizedBox(height: 24),
                  ] else ...[
                    if (forecastSection != null) ...[
                      forecastSection,
                      const SizedBox(height: 24),
                    ],
                    if (newCardsSection != null) ...[
                      newCardsSection,
                      const SizedBox(height: 24),
                    ],
                  ],
                  // Each section above ends with its own gap.
                  if (leeches.isNotEmpty) ...[
                    Text(
                      'Leeches (${leeches.length})',
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Cards with at least $_leechLapseThreshold lapses may need a new approach.',
                      style: theme.textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 8),
                    for (final leech in leeches)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.warning_amber_rounded),
                        title: Text(
                          leech.card.direction == CardDirection.targetToNative
                              ? leech.vocab.targetWord
                              : leech.vocab.translation,
                        ),
                        subtitle: Text(
                          leech.card.direction == CardDirection.targetToNative
                              ? leech.vocab.translation
                              : leech.vocab.targetWord,
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('${leech.card.lapses} lapses'),
                            IconButton(
                              tooltip: 'Suspend',
                              icon: const Icon(Icons.pause_circle_outline),
                              onPressed: () => _suspendLeech(provider, leech),
                            ),
                          ],
                        ),
                      ),
                  ],
                ],
              );
            },
          );
        },
      ),
    );
  }

  /// A bar per day for the cards coming due over the next week.
  Widget _forecastSection(
    BuildContext context, {
    required List<int> forecast,
    required DateTime today,
    required int maxDue,
    required int maxReviews24h,
  }) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Next 7 days', style: theme.textTheme.titleMedium),
        // The Study button counts fewer when the 24-hour limit holds some
        // back, so say these are all the cards due.
        if (maxReviews24h > 0)
          Text(
            'All cards coming due, before your limit of '
            '${formatCount(maxReviews24h)} reviews '
            'per 24 hours',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        const SizedBox(height: 12),
        SizedBox(
          height: 110,
          child: Row(
            children: [
              for (var index = 0; index < forecast.length; index++)
                Expanded(
                  child: _bar(
                    context,
                    label: _forecastLabel(today, index),
                    count: forecast[index],
                    maximum: maxDue,
                    // Today's bar is the lesson list's Due count.
                    color: index == 0 ? _dueColor : null,
                    tooltip:
                        '${_forecastLabel(today, index)}: '
                        '${formatCount(forecast[index])} due',
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  String _monthLabel(List<DateTime> weeks, int index) {
    final month = weeks[index].month;
    if (index > 0 && weeks[index - 1].month == month) return '';
    return switch (month) {
      1 => 'Jan',
      2 => 'Feb',
      3 => 'Mar',
      4 => 'Apr',
      5 => 'May',
      6 => 'Jun',
      7 => 'Jul',
      8 => 'Aug',
      9 => 'Sep',
      10 => 'Oct',
      11 => 'Nov',
      _ => 'Dec',
    };
  }

  Widget _dayCell(
    BuildContext context,
    DateTime date,
    DateTime firstDay,
    DateTime today,
    Map<DateTime, int> counts,
    Map<DateTime, Map<SrsRating, int>> ratingCounts,
    Map<DateTime, int> newCardCounts,
    int busiest,
  ) {
    final isInRange =
        !date.isBefore(firstDay) &&
        !date.isAfter(DateTime(today.year, today.month, today.day));
    // Days before the first one shown, or after today, are blank space: no
    // tooltip, and nothing for a screen reader to read out.
    if (!isInRange) return const SizedBox(width: 12, height: 16);
    final count = counts[date] ?? 0;
    final ratings = ratingCounts[date];
    final newCards = newCardCounts[date] ?? 0;
    final label = [
      '${date.year}-${date.month.toString().padLeft(2, '0')}-'
          '${date.day.toString().padLeft(2, '0')}: '
          '${formatCount(count)} ${count == 1 ? 'review' : 'reviews'}',
      // Days counted before ratings were have only the total.
      if (ratings != null) '${formatCount(rightWrongOf(ratings).right)} right',
      if (newCards > 0) '${formatCount(newCards)} new',
    ].join(', ');
    return SizedBox(
      width: 12,
      height: 16,
      child: Semantics(
        label: label,
        child: Tooltip(
          message: label,
          child: Container(
            margin: const EdgeInsets.only(bottom: 4),
            decoration: BoxDecoration(
              color: _activityColor(
                Theme.of(context).colorScheme,
                activityLevel(count, busiest),
              ),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ),
    );
  }

  /// What a legend square's shade stands for, on a scale that ends at [top]:
  /// the review limit when [isLimit], otherwise the busiest day shown.
  String _legendLabel(int level, int top, {required bool isLimit}) {
    if (level == 0) return 'No reviews';
    final range = activityLevelRange(level, top);
    if (range == null) {
      if (top <= 0) return 'Not used yet';
      final reviews = '${formatCount(top)} ${top == 1 ? 'review' : 'reviews'}';
      return isLimit
          ? 'Not used with a limit of $reviews'
          : 'Not used: the busiest day had $reviews';
    }
    final (lowest, highest) = range;
    // The darkest shade has no upper end: days over the limit get it too.
    if (isLimit && level == 4) {
      return '${formatCount(lowest)} ${lowest == 1 ? 'review' : 'reviews'} '
          'or more';
    }
    if (lowest == highest) {
      return '${formatCount(lowest)} ${lowest == 1 ? 'review' : 'reviews'}';
    }
    return '${formatCount(lowest)}–${formatCount(highest)} reviews';
  }

  Map<SrsStatus, int> _studyStageCounts(List<Lesson> lessons) {
    final counts = {for (final status in SrsStatus.values) status: 0};
    final seenCardIds = <String>{};
    for (final vocab in lessons.expand((lesson) => lesson.vocabularies)) {
      for (final card in [vocab.cardTargetToNative, vocab.cardNativeToTarget]) {
        if (!card.isActive || !seenCardIds.add(card.id)) continue;
        counts[card.status] = counts[card.status]! + 1;
      }
    }
    return counts;
  }

  String _stageLabel(SrsStatus status) => switch (status) {
    SrsStatus.isNew => 'New',
    SrsStatus.learning => 'Learning',
    SrsStatus.review => 'Review',
  };

  /// A tile each for the streak, today's reviews and the answers right over
  /// the last 30 days. On a [wide] screen they share a row; otherwise the two
  /// counts share one and the answers go underneath.
  Widget _summary(
    BuildContext context, {
    required bool wide,
    required int streak,
    required int todayReviews,
    required int todayNew,
    required Map<SrsRating, int> recent,
  }) {
    final (:right, :wrong) = rightWrongOf(recent);
    final streakTile = _statTile(
      context,
      key: const ValueKey('summary-streak'),
      label: 'Streak',
      value: formatCount(streak),
      unit: streak == 1 ? 'day' : 'days',
    );
    final todayTile = _statTile(
      context,
      key: const ValueKey('summary-today'),
      label: 'Today',
      value: formatCount(todayReviews),
      unit: todayReviews == 1 ? 'review' : 'reviews',
      // "cards", to tell it from Cards by stage's "3 new".
      note: todayNew > 0
          ? '${formatCount(todayNew)} new ${todayNew == 1 ? 'card' : 'cards'}'
          : null,
    );
    final answersTile = right + wrong > 0
        ? _answersTile(context, recent)
        : null;
    const gap = SizedBox(width: 12);
    if (wide) {
      // IntrinsicHeight, so the three tiles are as tall as the tallest.
      return IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(flex: 2, child: streakTile),
            gap,
            Expanded(flex: 2, child: todayTile),
            gap,
            Expanded(flex: 5, child: answersTile ?? const SizedBox()),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: streakTile),
              gap,
              Expanded(child: todayTile),
            ],
          ),
        ),
        if (answersTile != null) ...[const SizedBox(height: 12), answersTile],
      ],
    );
  }

  /// The filled, rounded box of a summary tile, with its [label] on top.
  Widget _tile(
    BuildContext context, {
    Key? key,
    required String label,
    required Widget child,
  }) {
    final theme = Theme.of(context);
    return Container(
      key: key,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }

  /// A summary tile for one count: the [value] large with its [unit] after
  /// it, such as "9 days", and a [note] underneath.
  Widget _statTile(
    BuildContext context, {
    required Key key,
    required String label,
    required String value,
    required String unit,
    String? note,
  }) {
    final theme = Theme.of(context);
    final quiet = theme.colorScheme.onSurfaceVariant;
    return MergeSemantics(
      child: _tile(
        context,
        key: key,
        label: label,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                // Shrinks rather than overflows when a long count, such as
                // "1,234", meets a narrow tile or a large text size.
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.bottomLeft,
                    child: Text(
                      value,
                      maxLines: 1,
                      style: theme.textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  unit,
                  style: theme.textTheme.bodyMedium?.copyWith(color: quiet),
                ),
              ],
            ),
            if (note != null)
              Text(
                note,
                style: theme.textTheme.bodySmall?.copyWith(color: quiet),
              ),
          ],
        ),
      ),
    );
  }

  /// A summary tile with a ring of right (green) and wrong (red) answers,
  /// the percentage right in the middle, then a line each for right and
  /// wrong, with the counts of its two ratings at the far end, so it shows
  /// whether Good or Easy, and Again or Hard, made up more.
  Widget _answersTile(BuildContext context, Map<SrsRating, int> recent) {
    final theme = Theme.of(context);
    final (:right, :wrong) = rightWrongOf(recent);
    final answered = right + wrong;
    final percent = (right * 100 / answered).round();
    final quiet = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    String ratings(
      SrsRating first,
      String firstName,
      SrsRating second,
      String secondName,
    ) =>
        '$firstName ${formatCount(recent[first] ?? 0)} · '
        '$secondName ${formatCount(recent[second] ?? 0)}';
    TableRow legend(Color color, String text, String ratings) => TableRow(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.circle, size: 10, color: color),
              const SizedBox(width: 6),
              Text(text),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 16),
          child: Text(ratings, style: quiet),
        ),
      ],
    );
    return Semantics(
      label:
          '$percent% right in the last 30 days: ${formatCount(right)} right, '
          '${formatCount(wrong)} wrong',
      excludeSemantics: true,
      child: _tile(
        context,
        key: const ValueKey('summary-answers'),
        label: 'Last 30 days',
        child: Row(
          children: [
            SizedBox.square(
              dimension: 56,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // The same colours as the study session's progress bar.
                  SizedBox.expand(
                    child: CircularProgressIndicator(
                      value: right / answered,
                      strokeWidth: 6,
                      color: _rightColor,
                      backgroundColor: _wrongColor,
                    ),
                  ),
                  Text('$percent%', style: theme.textTheme.labelLarge),
                ],
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              // A table, so the ratings start in line after the longer
              // count, close to both.
              child: Table(
                columnWidths: const {
                  0: IntrinsicColumnWidth(),
                  1: FlexColumnWidth(),
                },
                defaultVerticalAlignment: TableCellVerticalAlignment.middle,
                children: [
                  legend(
                    _rightColor,
                    '${formatCount(right)} right',
                    ratings(SrsRating.good, 'Good', SrsRating.easy, 'Easy'),
                  ),
                  legend(
                    _wrongColor,
                    '${formatCount(wrong)} wrong',
                    ratings(SrsRating.again, 'Again', SrsRating.hard, 'Hard'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// One stage in the Cards by stage line, such as "45 learning".
  Widget _stageCount(SrsStatus status, int count) {
    final label = _stageLabel(status);
    return Tooltip(
      message: '$label: ${formatCount(count)} ${count == 1 ? 'card' : 'cards'}',
      child: Text('${formatCount(count)} ${label.toLowerCase()}'),
    );
  }

  /// New cards against the daily limit, how long the cards left take at
  /// that limit, and a bar per day over the last 30 days with the limit as a
  /// line.
  Widget _newCardsSection(
    BuildContext context, {
    required List<int> perDay,
    required DateTime today,
    required int startedLast24h,
    required int limit,
    required int left,
  }) {
    final theme = Theme.of(context);
    final quiet = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final busiest = perDay.fold(0, (maximum, n) => n > maximum ? n : maximum);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('New cards', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(newCardsLimitText(startedLast24h, limit)),
        Text(newCardsLeftText(left, limit), style: quiet),
        if (busiest > 0) ...[
          const SizedBox(height: 12),
          _newCardsChart(context, perDay, today, limit),
        ],
      ],
    );
  }

  Widget _newCardsChart(
    BuildContext context,
    List<int> perDay,
    DateTime today,
    int limit,
  ) {
    final theme = Theme.of(context);
    final quiet = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    const plotHeight = 80.0;
    final busiest = perDay.fold(0, (maximum, n) => n > maximum ? n : maximum);
    final top = limit > busiest ? limit : busiest;
    final days = perDay.length;
    final firstDay = DateTime(today.year, today.month, today.day - (days - 1));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: plotHeight + 16,
          child: Stack(
            children: [
              Positioned.fill(
                top: 16,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (var index = 0; index < days; index++)
                      Expanded(
                        child: Builder(
                          builder: (context) {
                            final day = DateTime(
                              firstDay.year,
                              firstDay.month,
                              firstDay.day + index,
                            );
                            final count = perDay[index];
                            final label =
                                '${_shortDate(day)}: ${formatCount(count)} new';
                            return Semantics(
                              label: label,
                              excludeSemantics: true,
                              child: Tooltip(
                                message: label,
                                child: Container(
                                  // Taller than the bar, so short bars are
                                  // still easy to hover.
                                  height: plotHeight,
                                  alignment: Alignment.bottomCenter,
                                  color: Colors.transparent,
                                  child: count == 0
                                      ? null
                                      : Container(
                                          // A gap between thin bars, so 30
                                          // days don't merge into a block.
                                          margin: const EdgeInsets.symmetric(
                                            horizontal: 2,
                                          ),
                                          constraints: const BoxConstraints(
                                            maxWidth: 12,
                                          ),
                                          height: plotHeight * count / top,
                                          decoration: BoxDecoration(
                                            color: theme.colorScheme.primary,
                                            borderRadius:
                                                const BorderRadius.vertical(
                                                  top: Radius.circular(2),
                                                ),
                                          ),
                                        ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                  ],
                ),
              ),
              if (limit > 0) ...[
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: plotHeight * limit / top,
                  child: IgnorePointer(
                    child: Container(
                      height: 1,
                      color: theme.colorScheme.onSurfaceVariant.withValues(
                        alpha: 0.6,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  right: 0,
                  bottom: plotHeight * limit / top + 2,
                  child: IgnorePointer(
                    child: Text('Limit ${formatCount(limit)}', style: quiet),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Text(_shortDate(firstDay), style: quiet),
            const Spacer(),
            Text('Today', style: quiet),
          ],
        ),
        const SizedBox(height: 4),
        // Italic, so it doesn't read as one more axis label like the date
        // just above it.
        Text(
          newCardsChartCaption(limit),
          style: quiet?.copyWith(fontStyle: FontStyle.italic),
        ),
      ],
    );
  }

  /// "Nov 7".
  String _shortDate(DateTime day) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${months[day.month - 1]} ${day.day}';
  }

  /// "Today", then the weekday of each day after it.
  String _forecastLabel(DateTime today, int daysAhead) {
    if (daysAhead == 0) return 'Today';
    const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final day = DateTime(today.year, today.month, today.day + daysAhead);
    return weekdays[day.weekday - 1];
  }

  /// Suspends a leech, with a snackbar to undo it.
  void _suspendLeech(AppProvider provider, _LeechCard leech) {
    provider.setCardSuspended(leech.card, true);
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text('Suspended "${leech.vocab.targetWord}"'),
        // With an action a snackbar persists by default; an old Undo would
        // stay for minutes, across screens.
        persist: false,
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => provider.setCardSuspended(leech.card, false),
        ),
      ),
    );
  }

  Widget _bar(
    BuildContext context, {
    required String label,
    required int count,
    required int maximum,
    required String tooltip,
    Color? color,
  }) {
    final barHeight = maximum == 0 ? 2.0 : 60.0 * count / maximum;
    final theme = Theme.of(context);
    return Semantics(
      label: tooltip,
      excludeSemantics: true,
      child: Tooltip(
        message: tooltip,
        child: Column(
          children: [
            // Seven bars leave room to print each count.
            if (count > 0)
              Text(
                formatCount(count),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            const SizedBox(height: 2),
            Expanded(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Container(
                  // Wide enough that the week doesn't look empty.
                  width: 32,
                  height: barHeight,
                  decoration: BoxDecoration(
                    color: color ?? Theme.of(context).colorScheme.primary,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(3),
                    ),
                  ),
                ),
              ),
            ),
            SizedBox(
              height: 20,
              child: Text(label, style: Theme.of(context).textTheme.labelSmall),
            ),
          ],
        ),
      ),
    );
  }

  Color _activityColor(ColorScheme colors, int level) {
    if (level == 0) return colors.surfaceContainerHighest;
    return Color.lerp(
      colors.surfaceContainerHighest,
      colors.primary,
      level / 4,
    )!;
  }

  List<_LeechCard> _findLeeches(List<Lesson> lessons) {
    final cardsById = <String, _LeechCard>{};
    for (final vocab in lessons.expand((lesson) => lesson.vocabularies)) {
      for (final card in [vocab.cardTargetToNative, vocab.cardNativeToTarget]) {
        if (card.isActive && card.lapses >= _leechLapseThreshold) {
          cardsById.putIfAbsent(
            card.id,
            () => _LeechCard(vocab: vocab, card: card),
          );
        }
      }
    }
    final leeches = cardsById.values.toList()
      ..sort(
        (first, second) => second.card.lapses.compareTo(first.card.lapses),
      );
    return leeches;
  }
}

class _LeechCard {
  const _LeechCard({required this.vocab, required this.card});

  final VocabItem vocab;
  final SrsCard card;
}
