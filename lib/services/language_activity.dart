import '../models/saved_time.dart';
import '../models/srs_card.dart';

/// The reviews of one day on one device: all of them, or one language's
/// share of them.
class ActivityShare {
  ActivityShare({
    this.count = 0,
    Map<SrsRating, int>? ratings,
    this.newCards = 0,
  }) : ratings = ratings ?? {};

  /// Reviews made.
  int count;

  /// Reviews by rating. Reviews counted before ratings were recorded are
  /// only in [count].
  final Map<SrsRating, int> ratings;

  /// New cards started: reviews of a card that was still new.
  int newCards;

  bool get isEmpty => count <= 0 && newCards <= 0 && ratings.isEmpty;

  void add(ActivityShare other) {
    count += other.count;
    newCards += other.newCards;
    for (final entry in other.ratings.entries) {
      ratings[entry.key] = (ratings[entry.key] ?? 0) + entry.value;
    }
  }

  /// What of [total] is [language]'s, given the shares that were recorded
  /// with a language ([byLanguage]). Reviews made before languages were
  /// recorded are in [total] and in no share: they go to the language that
  /// [takesRest].
  static ActivityShare of(
    ActivityShare total,
    Map<String, ActivityShare> byLanguage,
    String language, {
    required bool takesRest,
  }) {
    final share = ActivityShare()..add(byLanguage[language] ?? ActivityShare());
    if (!takesRest) return share;
    final recorded = ActivityShare();
    for (final other in byLanguage.values) {
      recorded.add(other);
    }
    int rest(int all, int counted) => all > counted ? all - counted : 0;
    share.count += rest(total.count, recorded.count);
    share.newCards += rest(total.newCards, recorded.newCards);
    for (final entry in total.ratings.entries) {
      final left = rest(entry.value, recorded.ratings[entry.key] ?? 0);
      if (left > 0) {
        share.ratings[entry.key] = (share.ratings[entry.key] ?? 0) + left;
      }
    }
    return share;
  }

  Map<String, dynamic> toJson() => {
    'count': count,
    if (ratings.isNotEmpty) 'ratings': ratingCountsToJson(ratings),
    if (newCards > 0) 'newCards': newCards,
  };

  /// Reads [toJson]'s format, and an activity record's own fields, which
  /// are the same. Anything else counts as nothing.
  static ActivityShare fromJson(Object? json) {
    if (json is! Map) return ActivityShare();
    final count = json['count'];
    final newCards = json['newCards'];
    return ActivityShare(
      count: count is num && count > 0 ? count.toInt() : 0,
      ratings: ratingCountsFromJson(json['ratings']),
      newCards: newCards is num && newCards > 0 ? newCards.toInt() : 0,
    );
  }
}

/// This device's reviews by language, next to the totals the app has always
/// kept: for each language (a `Lesson.languageKey`), its share of each day,
/// and of the reviews that count toward the 24-hour limit.
///
/// Only reviews made since languages were recorded are here. The totals
/// hold the rest too; see [ActivityShare.of].
class LanguageActivity {
  LanguageActivity({
    Map<String, Map<DateTime, ActivityShare>>? days,
    Map<String, List<DateTime>>? reviewTimes,
  }) : days = days ?? {},
       reviewTimes = reviewTimes ?? {};

  /// By language, then by day (local midnight).
  final Map<String, Map<DateTime, ActivityShare>> days;

  /// By language: when the reviews that count toward the 24-hour limit were
  /// made.
  final Map<String, List<DateTime>> reviewTimes;

  static DateTime _day(DateTime at) => DateTime(at.year, at.month, at.day);

  /// Counts a review of [language] made [at]. [timed] when it counts toward
  /// the 24-hour limit.
  void record(
    String language,
    DateTime at,
    SrsRating rating, {
    required bool newCard,
    required bool timed,
  }) {
    final share = days
        .putIfAbsent(language, () => {})
        .putIfAbsent(_day(at), ActivityShare.new);
    share.count++;
    share.ratings[rating] = (share.ratings[rating] ?? 0) + 1;
    if (newCard) share.newCards++;
    if (timed) reviewTimes.putIfAbsent(language, () => []).add(at);
  }

  /// Takes back what [record] counted. A review made before languages were
  /// recorded has nothing here to take back.
  void undo(
    String language,
    DateTime at,
    SrsRating rating, {
    required bool newCard,
  }) {
    final day = _day(at);
    final share = days[language]?[day];
    if (share != null && share.count > 0) {
      share.count--;
      _takeRating(share, rating);
      if (newCard && share.newCards > 0) share.newCards--;
      if (share.isEmpty) {
        days[language]!.remove(day);
        if (days[language]!.isEmpty) days.remove(language);
      }
    }
    reviewTimes[language]?.remove(at);
  }

  /// Moves a review of [language] made [at] from rating [from] to [to].
  void recount(String language, DateTime at, SrsRating from, SrsRating to) {
    final share = days[language]?[_day(at)];
    if (share == null || (share.ratings[from] ?? 0) <= 0) return;
    _takeRating(share, from);
    share.ratings[to] = (share.ratings[to] ?? 0) + 1;
  }

  static void _takeRating(ActivityShare share, SrsRating rating) {
    final count = (share.ratings[rating] ?? 0) - 1;
    if (count > 0) {
      share.ratings[rating] = count;
    } else {
      share.ratings.remove(rating);
    }
  }

  /// Each language's share of [day].
  Map<String, ActivityShare> sharesOn(DateTime day) => {
    for (final entry in days.entries)
      if (entry.value[day] case final share? when !share.isEmpty)
        entry.key: share,
  };

  /// Drops review times older than 24 hours before [now].
  void prune(DateTime now) {
    for (final times in reviewTimes.values) {
      times.removeWhere((time) => now.difference(time).inHours >= 24);
    }
    reviewTimes.removeWhere((_, times) => times.isEmpty);
  }

  /// [day] by language for the day's activity record, which other devices
  /// pull: each language's share, with its review times of that day. Empty
  /// when no review of the day was recorded with a language.
  Map<String, dynamic> recordJson(DateTime day) => {
    for (final entry in sharesOn(day).entries)
      entry.key: {
        ...entry.value.toJson(),
        'reviews': [
          for (final time in reviewTimes[entry.key] ?? const <DateTime>[])
            if (_day(time) == day) time.toUtc().toIso8601String(),
        ]..sort(),
      },
  };

  Map<String, dynamic> toJson() => {
    'days': {
      for (final language in days.entries)
        language.key: {
          for (final day in language.value.entries)
            if (!day.value.isEmpty) _dayKey(day.key): day.value.toJson(),
        },
    },
    'reviews': {
      for (final entry in reviewTimes.entries)
        entry.key: [for (final time in entry.value) savedTime(time)],
    },
  };

  /// Reads [toJson]'s format. Anything that does not fit is left out, so
  /// data from another app version can't break it.
  factory LanguageActivity.fromJson(Object? json) {
    final activity = LanguageActivity();
    if (json is! Map) return activity;
    final days = json['days'];
    if (days is Map) {
      for (final language in days.entries) {
        if (language.value is! Map) continue;
        for (final day in (language.value as Map).entries) {
          final date = DateTime.tryParse('${day.key}');
          final share = ActivityShare.fromJson(day.value);
          if (date == null || share.isEmpty) continue;
          activity.days.putIfAbsent('${language.key}', () => {})[_day(date)] =
              share;
        }
      }
    }
    final reviews = json['reviews'];
    if (reviews is Map) {
      for (final entry in reviews.entries) {
        if (entry.value is! List) continue;
        final times = [
          for (final time in entry.value as List) ?tryLoadedTime('$time'),
        ];
        if (times.isNotEmpty) activity.reviewTimes['${entry.key}'] = times;
      }
    }
    return activity;
  }

  static String _dayKey(DateTime day) =>
      '${day.year.toString().padLeft(4, '0')}-'
      '${day.month.toString().padLeft(2, '0')}-'
      '${day.day.toString().padLeft(2, '0')}';
}
