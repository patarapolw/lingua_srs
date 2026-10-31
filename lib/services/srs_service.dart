import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../models/srs_card.dart';

class SrsService {
  /// How soon a card rated Again comes back.
  static const Duration againDelay = Duration(hours: 1);

  /// How soon a card rated Hard comes back. Always shown as 12 h; the card's
  /// real (hidden) Hard interval is kept in [SrsCard.interval].
  static const Duration hardDelay = Duration(hours: 12);

  /// Previews how long until the card is next due for [rating], without changing it.
  static Duration previewInterval(SrsCard card, SrsRating rating) {
    final saved = (
      card.lastReviewed,
      card.lastRating,
      card.repetitions,
      card.interval,
      card.easeFactor,
      card.status,
      card.dueDate,
      card.lapses,
      card.lastMistakeDate,
      card.introducedAt,
    );
    processReview(card, rating, log: false);
    final result = card.dueDate.difference(card.lastReviewed ?? DateTime.now());
    card.lastReviewed = saved.$1;
    card.lastRating = saved.$2;
    card.repetitions = saved.$3;
    card.interval = saved.$4;
    card.easeFactor = saved.$5;
    card.status = saved.$6;
    card.dueDate = saved.$7;
    card.lapses = saved.$8;
    card.lastMistakeDate = saved.$9;
    card.introducedAt = saved.$10;
    return result;
  }

  static String formatDuration(Duration d) {
    if (d.inMinutes < 60) return '${max(1, d.inMinutes)}m';
    if (d.inHours < 24) return '${d.inHours}h';
    final days = d.inDays;
    if (days < 30) return '${days}d';
    if (days < 365) return '${(days / 30).round()}mo';
    return '${(days / 365).toStringAsFixed(1)}y';
  }

  /// Days until the next review if [card] is rated Good now.
  static int goodInterval(SrsCard card) {
    final repetitions = card.repetitions + 1;
    if (repetitions == 1) return 1;
    if (repetitions == 2) return 6;
    return max(1, (card.interval * card.easeFactor).round());
  }

  /// Days until the next review if [card] is rated Easy now. Always longer
  /// than [goodInterval], and at least 2 days.
  static int easyInterval(SrsCard card) {
    final repetitions = card.repetitions + 1;
    final int raw;
    if (repetitions == 1) {
      raw = 4;
    } else if (repetitions == 2) {
      raw = 10;
    } else {
      raw = (card.interval * card.easeFactor * 1.3).round();
    }
    return max(max(2, goodInterval(card) + 1), raw);
  }

  /// The hidden interval in days that a Hard review gives the card. It is not
  /// shown (Hard always comes back in [hardDelay]) but it is what the next
  /// review grows from. It is shorter than [goodInterval] whenever possible:
  /// it can only equal it when Good is 1 day.
  static int hardInterval(SrsCard card) {
    final good = goodInterval(card);
    if (good <= 1) return 1;
    final raw = max(1, (card.interval * 1.2).round());
    return min(raw, good - 1);
  }

  /// Applies the SM-2 algorithm to update an SRS card based on user rating.
  ///
  /// Again and Hard are rescheduled within 24 h ([againDelay], [hardDelay]).
  /// Their intervals in days are not visible there, so they are logged
  /// (`adb logcat -s flutter`) unless [log] is false.
  static void processReview(SrsCard card, SrsRating rating, {bool log = true}) {
    final now = DateTime.now();
    card.lastReviewed = now;
    card.lastRating = rating;
    if (card.status == SrsStatus.isNew) card.introducedAt = now;

    switch (rating) {
      case SrsRating.again:
        card.repetitions = 0;
        card.interval = 0;
        card.easeFactor = max(1.3, card.easeFactor - 0.2);
        card.status = SrsStatus.learning;
        card.dueDate = now.add(againDelay);
        card.lapses += 1;
        card.lastMistakeDate = now;
        if (log) {
          // Interval the card gets when the retry is answered Good.
          _log(card, rating, againDelay, goodInterval(card));
        }
        break;

      case SrsRating.hard:
        final hidden = hardInterval(card);
        card.repetitions += 1;
        card.interval = hidden;
        card.easeFactor = max(1.3, card.easeFactor - 0.15);
        card.status = SrsStatus.review;
        card.dueDate = now.add(hardDelay);
        if (log) _log(card, rating, hardDelay, hidden);
        break;

      case SrsRating.good:
        card.interval = goodInterval(card);
        card.repetitions += 1;
        card.status = SrsStatus.review;
        card.dueDate = now.add(Duration(days: card.interval));
        break;

      case SrsRating.easy:
        card.interval = easyInterval(card);
        card.repetitions += 1;
        card.easeFactor += 0.15;
        card.status = SrsStatus.review;
        card.dueDate = now.add(Duration(days: card.interval));
        break;
    }
  }

  static void _log(
    SrsCard card,
    SrsRating rating,
    Duration shown,
    int hiddenDays,
  ) {
    // Keep `flutter test` output quiet; this is for logcat only.
    if (Platform.environment.containsKey('FLUTTER_TEST')) return;
    debugPrint(
      'SRS ${rating.name}: card ${card.id} shown ${formatDuration(shown)}, '
      'hidden interval ${hiddenDays}d, reps ${card.repetitions}, '
      'ease ${card.easeFactor.toStringAsFixed(2)}',
    );
  }
}
