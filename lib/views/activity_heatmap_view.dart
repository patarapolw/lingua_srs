import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/app_provider.dart';

class ActivityHeatmapView extends StatelessWidget {
  const ActivityHeatmapView({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final today = DateTime.now();
    final firstDay = DateTime(today.year, today.month, today.day - 364);
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

    return Scaffold(
      appBar: AppBar(title: const Text('Study activity')),
      body: Consumer<AppProvider>(
        builder: (context, provider, _) {
          final counts = provider.dailyReviewCounts;
          final total = counts.entries
              .where(
                (entry) =>
                    !entry.key.isBefore(firstDay) &&
                    !entry.key.isAfter(
                      DateTime(today.year, today.month, today.day),
                    ),
              )
              .fold(0, (sum, entry) => sum + entry.value);

          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text(
                '$total ${total == 1 ? 'review' : 'reviews'} in the past year',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 16),
              SingleChildScrollView(
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
                            child: Text(
                              _monthLabel(weeks, index),
                              maxLines: 1,
                              overflow: TextOverflow.clip,
                              style: theme.textTheme.labelSmall,
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

  Color _activityColor(ColorScheme colors, int level) {
    if (level == 0) return colors.surfaceContainerHighest;
    return Color.lerp(
      colors.surfaceContainerHighest,
      colors.primary,
      level / 4,
    )!;
  }
}
