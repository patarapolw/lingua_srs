import 'dart:math';
import '../models/srs_card.dart';

class SrsService {
  /// Applies the SM-2 algorithm to update an SRS card based on user rating.
  static void processReview(SrsCard card, SrsRating rating) {
    final now = DateTime.now();
    card.lastReviewed = now;

    switch (rating) {
      case SrsRating.again:
        card.repetitions = 0;
        card.interval = 1;
        card.easeFactor = max(1.3, card.easeFactor - 0.2);
        card.status = SrsStatus.learning;
        card.dueDate = now.add(const Duration(days: 1));
        break;

      case SrsRating.hard:
        card.repetitions += 1;
        card.interval = card.interval <= 1 ? 2 : (card.interval * 1.2).round();
        card.easeFactor = max(1.3, card.easeFactor - 0.15);
        card.status = SrsStatus.review;
        card.dueDate = now.add(Duration(days: card.interval));
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
