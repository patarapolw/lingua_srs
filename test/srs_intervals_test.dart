import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/srs_card.dart';
import 'package:lingua_srs/services/srs_service.dart';
import 'package:lingua_srs/views/lesson_detail_view.dart';

SrsCard cardWith({
  int interval = 0,
  int repetitions = 0,
  double easeFactor = 2.5,
  SrsStatus status = SrsStatus.review,
}) => SrsCard(
  direction: CardDirection.targetToNative,
  interval: interval,
  repetitions: repetitions,
  easeFactor: easeFactor,
  status: status,
);

/// The interval in days a rating gives, on a copy of [card].
int daysFor(SrsCard card, SrsRating rating) {
  final copy = cardWith(
    interval: card.interval,
    repetitions: card.repetitions,
    easeFactor: card.easeFactor,
    status: card.status,
  );
  SrsService.processReview(copy, rating);
  return copy.interval;
}

void main() {
  group('Good vs Easy', () {
    test('Easy is longer than Good after repeated Hard (interval 0)', () {
      // Hard used to leave interval 0 with repetitions growing, which made
      // Good and Easy both round to the 1 day minimum.
      final card = cardWith(interval: 0, repetitions: 3);

      final good = daysFor(card, SrsRating.good);
      final easy = daysFor(card, SrsRating.easy);

      expect(good, 1);
      expect(easy, greaterThan(good));
      expect(easy, greaterThanOrEqualTo(2));
    });

    test('Easy is longer than Good when both round to 3 days', () {
      // 1 * 2.5 = 2.5 -> 3 and 1 * 2.5 * 1.3 = 3.25 -> 3.
      final card = cardWith(interval: 1, repetitions: 2);

      expect(daysFor(card, SrsRating.good), 3);
      expect(daysFor(card, SrsRating.easy), 4);
    });

    test('Easy is at worst 2 days and beats Good for any history', () {
      for (var repetitions = 0; repetitions < 8; repetitions++) {
        for (final interval in [0, 1, 2, 3, 6, 15, 40, 200]) {
          for (final ease in [1.3, 1.8, 2.5, 3.1]) {
            final card = cardWith(
              interval: interval,
              repetitions: repetitions,
              easeFactor: ease,
            );
            final good = daysFor(card, SrsRating.good);
            final easy = daysFor(card, SrsRating.easy);
            final reason = 'reps $repetitions, interval $interval, ease $ease';

            expect(good, greaterThanOrEqualTo(1), reason: reason);
            expect(easy, greaterThanOrEqualTo(2), reason: reason);
            expect(easy, greaterThan(good), reason: reason);
          }
        }
      }
    });

    test('the due date follows the interval', () {
      final card = cardWith(interval: 0, repetitions: 3);
      SrsService.processReview(card, SrsRating.easy);

      expect(card.dueDate.difference(card.lastReviewed!).inDays, card.interval);
    });

    test('first reviews are unchanged: Good 1 d, Easy 4 d', () {
      final good = SrsCard(direction: CardDirection.targetToNative);
      final easy = SrsCard(direction: CardDirection.targetToNative);

      SrsService.processReview(good, SrsRating.good);
      SrsService.processReview(easy, SrsRating.easy);

      expect(good.interval, 1);
      expect(easy.interval, 4);
    });
  });

  group('Hard', () {
    test('is always shown as 12 h', () {
      for (final interval in [0, 1, 6, 15, 90]) {
        final card = cardWith(interval: interval, repetitions: 3);

        final shown = SrsService.previewInterval(card, SrsRating.hard);

        expect(shown, const Duration(hours: 12), reason: 'interval $interval');
        expect(SrsService.formatDuration(shown), '12h');
      }
    });

    test('also comes back in 12 h on a mature card', () {
      final card = cardWith(interval: 30, repetitions: 5);
      SrsService.processReview(card, SrsRating.hard);

      expect(card.dueDate.difference(card.lastReviewed!), SrsService.hardDelay);
      expect(card.status, SrsStatus.review);
    });

    test('keeps a hidden interval shorter than Good', () {
      for (var repetitions = 0; repetitions < 8; repetitions++) {
        for (final interval in [0, 1, 2, 3, 6, 15, 40, 200]) {
          final card = cardWith(interval: interval, repetitions: repetitions);
          final good = daysFor(card, SrsRating.good);
          final hard = daysFor(card, SrsRating.hard);
          final reason = 'reps $repetitions, interval $interval';

          expect(hard, greaterThanOrEqualTo(1), reason: reason);
          if (good > 1) {
            expect(hard, lessThan(good), reason: reason);
          } else {
            expect(hard, 1, reason: reason);
          }
        }
      }
    });

    test('hidden interval grows by 1.2x on a mature card', () {
      final card = cardWith(interval: 6, repetitions: 2);
      SrsService.processReview(card, SrsRating.hard);

      expect(card.interval, 7); // (6 * 1.2).round(), below Good's 15
      expect(card.repetitions, 3);
      expect(card.easeFactor, closeTo(2.35, 1e-9));
    });

    test('a new card rated Hard has a hidden interval of 1 day', () {
      final card = SrsCard(direction: CardDirection.targetToNative);
      SrsService.processReview(card, SrsRating.hard);

      expect(card.interval, 1);
      expect(card.dueDate.difference(card.lastReviewed!).inHours, 12);
    });

    test('the next Good builds on the hidden interval', () {
      final card = cardWith(interval: 10, repetitions: 4);
      SrsService.processReview(card, SrsRating.hard);
      final hidden = card.interval;
      final ease = card.easeFactor;

      SrsService.processReview(card, SrsRating.good);

      expect(card.interval, (hidden * ease).round());
    });

    test('previewing leaves the card untouched', () {
      final card = cardWith(interval: 10, repetitions: 4);
      final due = card.dueDate;

      SrsService.previewInterval(card, SrsRating.hard);

      expect(card.interval, 10);
      expect(card.repetitions, 4);
      expect(card.easeFactor, 2.5);
      expect(card.dueDate, due);
    });

    test('status label shows 12h, not the hidden interval', () {
      final card = cardWith(interval: 10, repetitions: 4);
      SrsService.processReview(card, SrsRating.hard);

      expect(cardStatusLabel(card), isNot('${card.interval}d'));
      expect(cardStatusLabel(card), matches(RegExp(r'^1[12]h$')));
    });
  });
}
