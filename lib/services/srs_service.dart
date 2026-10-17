import 'dart:math';

import '../models/srs_card.dart';

class SrsService {
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
    );
    processReview(card, rating);
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

  /// Applies the SM-2 algorithm to update an SRS card based on user rating.
  static void processReview(SrsCard card, SrsRating rating) {
    final now = DateTime.now();
    card.lastReviewed = now;
    card.lastRating = rating;

    switch (rating) {
      case SrsRating.again:
        card.repetitions = 0;
        card.interval = 0;
        card.easeFactor = max(1.3, card.easeFactor - 0.2);
        card.status = SrsStatus.learning;
        card.dueDate = now.add(const Duration(hours: 1));
        card.lapses += 1;
        card.lastMistakeDate = now;
        break;

      case SrsRating.hard:
        card.repetitions += 1;
        if (card.repetitions <= 1 || card.interval <= 1) {
          card.interval = 0;
          card.dueDate = now.add(const Duration(hours: 12));
        } else {
          card.interval = (card.interval * 1.2).round();
          card.dueDate = now.add(Duration(days: max(1, card.interval)));
        }
        card.easeFactor = max(1.3, card.easeFactor - 0.15);
        card.status = SrsStatus.review;
        break;

      case SrsRating.good:
        card.repetitions += 1;
        if (card.repetitions == 1) {
          card.interval = 1;
        } else if (card.repetitions == 2) {
          card.interval = 6;
        } else {
          card.interval = (card.interval * card.easeFactor).round();
        }
        card.status = SrsStatus.review;
        card.dueDate = now.add(Duration(days: max(1, card.interval)));
        break;

      case SrsRating.easy:
        card.repetitions += 1;
        if (card.repetitions == 1) {
          card.interval = 4;
        } else if (card.repetitions == 2) {
          card.interval = 10;
        } else {
          card.interval = (card.interval * card.easeFactor * 1.3).round();
        }
        card.easeFactor += 0.15;
        card.status = SrsStatus.review;
        card.dueDate = now.add(Duration(days: max(1, card.interval)));
        break;
    }
  }
}
