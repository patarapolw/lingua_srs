import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/lesson.dart';
import '../models/srs_card.dart';
import '../models/vocab_item.dart';
import '../providers/app_provider.dart';

const _leechLapseThreshold = 8;

/// The shade, 0 to 4, of a day with [count] reviews, when the busiest day
/// shown had [busiest]. Shades are quarters of the busiest day, so a calendar
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

/// The Monday of [day]'s week, at midnight. Built from the day number rather
/// than by subtracting days, so a clock change in between can't land it on
/// the Sunday before.
@visibleForTesting
DateTime calendarWeekStart(DateTime day) =>
    DateTime(day.year, day.month, day.day - (day.weekday - DateTime.monday));

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
          return ListView(
            padding: const EdgeInsets.all(20),
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
                Text(
                  '$total ${total == 1 ? 'review' : 'reviews'} '
                  'in the past year',
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 16),
                SingleChildScrollView(
                  controller: _scrollController,
                  scrollDirection: Axis.horizontal,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const SizedBox(width: 32),
                          for (var index = 0; index < weeks.length; index++)
                            SizedBox(
                              width: 16,
                              height: 56,
                              child: Center(
                                child: RotatedBox(
                                  quarterTurns: 3,
                                  child: Text(
                                    _monthLabel(weeks, index),
                                    maxLines: 1,
                                    style: theme.textTheme.labelSmall,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 28,
                            child: Column(
                              children: [
                                for (final label in const [
                                  '',
                                  'Mon',
                                  '',
                                  'Wed',
                                  '',
                                  'Fri',
                                  '',
                                ])
                                  SizedBox(
                                    height: 16,
                                    child: Text(
                                      label,
                                      style: theme.textTheme.labelSmall,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          for (final week in weeks)
                            Padding(
                              padding: const EdgeInsets.only(right: 4),
                              child: Column(
                                children: [
                                  for (var dayIndex = 0; dayIndex < 7; dayIndex++)
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
                                      busiest,
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
                    Text('Less', style: theme.textTheme.labelSmall),
                    const SizedBox(width: 6),
                    for (var level = 0; level <= 4; level++)
                      Tooltip(
                        message: _legendLabel(level, busiest),
                        child: Container(
                          width: 12,
                          height: 12,
                          margin: const EdgeInsets.only(right: 4),
                          decoration: BoxDecoration(
                            color: _activityColor(theme.colorScheme, level),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                    Text('More', style: theme.textTheme.labelSmall),
                  ],
                ),
                const SizedBox(height: 24),
              ],
              Text('Cards by stage', style: theme.textTheme.titleMedium),
              const SizedBox(height: 12),
              SizedBox(
                height: 120,
                child: Row(
                  children: [
                    for (final entry in stageCounts.entries)
                      Expanded(
                        child: _stageBar(
                          context,
                          _stageLabel(entry.key),
                          entry.value,
                          maxStageCount,
                        ),
                      ),
                  ],
                ),
              ),
              if (leeches.isNotEmpty) ...[
                const SizedBox(height: 24),
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
                    trailing: Text('${leech.card.lapses} lapses'),
                  ),
              ],
            ],
          );
        },
      ),
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
    int busiest,
  ) {
    final isInRange =
        !date.isBefore(firstDay) &&
        !date.isAfter(DateTime(today.year, today.month, today.day));
    // Days before the first one shown, or after today, are blank space: no
    // tooltip, and nothing for a screen reader to read out.
    if (!isInRange) return const SizedBox(width: 12, height: 16);
    final count = counts[date] ?? 0;
    final label =
        '${date.year}-${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}: '
        '$count ${count == 1 ? 'review' : 'reviews'}';
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

  /// What a legend square's shade stands for, with the calendar's busiest
  /// day at [busiest].
  String _legendLabel(int level, int busiest) {
    if (level == 0) return 'No reviews';
    final range = activityLevelRange(level, busiest);
    if (range == null) {
      if (busiest <= 0) return 'Not used yet';
      return 'Not used: the busiest day had '
          '$busiest ${busiest == 1 ? 'review' : 'reviews'}';
    }
    final (lowest, highest) = range;
    if (lowest == highest) {
      return '$lowest ${lowest == 1 ? 'review' : 'reviews'}';
    }
    return '$lowest–$highest reviews';
  }

  Map<SrsStatus, int> _studyStageCounts(List<Lesson> lessons) {
    final counts = {for (final status in SrsStatus.values) status: 0};
    final seenCardIds = <String>{};
    for (final vocab in lessons.expand((lesson) => lesson.vocabularies)) {
      for (final card in [vocab.cardTargetToNative, vocab.cardNativeToTarget]) {
        if (!card.isEnabled || !seenCardIds.add(card.id)) continue;
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

  Widget _stageBar(BuildContext context, String label, int count, int maximum) {
    final tooltip = '$label: $count ${count == 1 ? 'card' : 'cards'}';
    final barHeight = maximum == 0 ? 2.0 : 80.0 * count / maximum;
    return Semantics(
      label: tooltip,
      child: Tooltip(
        message: tooltip,
        child: Column(
          children: [
            Expanded(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Container(
                  width: 16,
                  height: barHeight,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary,
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
        if (card.isEnabled && card.lapses >= _leechLapseThreshold) {
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
