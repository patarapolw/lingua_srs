import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/lesson.dart';
import '../models/srs_card.dart';
import '../models/vocab_item.dart';
import '../providers/app_provider.dart';

const _leechLapseThreshold = 8;

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
    _scrolledToEnd = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
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
          final calendarStart = firstDay.subtract(
            Duration(days: firstDay.weekday - DateTime.monday),
          );
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
          final total = counts.entries
              .where(
                (entry) =>
                    !entry.key.isBefore(firstDay) &&
                    !entry.key.isAfter(
                      DateTime(today.year, today.month, today.day),
                    ),
              )
              .fold(0, (sum, entry) => sum + entry.value);

          if (total == 0 && leeches.isEmpty) {
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

          _scrollToEnd();
          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text(
                '$total ${total == 1 ? 'review' : 'reviews'} in the past year',
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
                    Container(
                      width: 12,
                      height: 12,
                      margin: const EdgeInsets.only(right: 4),
                      decoration: BoxDecoration(
                        color: _activityColor(theme.colorScheme, level),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  Text('More', style: theme.textTheme.labelSmall),
                ],
              ),
              const SizedBox(height: 24),
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
  ) {
    final isInRange =
        !date.isBefore(firstDay) &&
        !date.isAfter(DateTime(today.year, today.month, today.day));
    final count = isInRange ? counts[date] ?? 0 : 0;
    final label =
        '${date.year}-${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}: $count reviews';
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
              color: isInRange
                  ? _activityColor(Theme.of(context).colorScheme, _level(count))
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ),
    );
  }

  int _level(int count) => switch (count) {
    0 => 0,
    1 => 1,
    2 || 3 => 2,
    >= 4 && <= 6 => 3,
    _ => 4,
  };

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
