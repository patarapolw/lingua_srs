import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/srs_card.dart';
import 'package:lingua_srs/services/srs_service.dart';
import 'package:lingua_srs/views/study_view.dart';

void expectSameState(SrsCard actual, SrsCard expected) {
  expect(actual.interval, expected.interval);
  expect(actual.repetitions, expected.repetitions);
  expect(actual.easeFactor, expected.easeFactor);
  expect(actual.dueDate, expected.dueDate);
  expect(actual.lastReviewed, expected.lastReviewed);
  expect(actual.status, expected.status);
  expect(actual.lapses, expected.lapses);
  expect(actual.lastMistakeDate, expected.lastMistakeDate);
  expect(actual.lastRating, expected.lastRating);
  expect(actual.mistakesClearedAt, expected.mistakesClearedAt);
}

SrsCard cloneOf(SrsCard c) => SrsCard(
  id: c.id,
  direction: c.direction,
  interval: c.interval,
  repetitions: c.repetitions,
  easeFactor: c.easeFactor,
  dueDate: c.dueDate,
  lastReviewed: c.lastReviewed,
  status: c.status,
  lapses: c.lapses,
  lastMistakeDate: c.lastMistakeDate,
  lastRating: c.lastRating,
  mistakesClearedAt: c.mistakesClearedAt,
);

void main() {
  group('ReviewHistoryRecord undo snapshot', () {
    for (final rating in SrsRating.values) {
      test('restores a new card after ${rating.name}', () {
        final card = SrsCard(direction: CardDirection.targetToNative);
        final before = cloneOf(card);

        final record = ReviewHistoryRecord.capture(
          queueIndex: 0,
          card: card,
          rating: rating,
        );
        SrsService.processReview(card, rating); // mutates in place
        record.restore();

        expectSameState(card, before);
      });
    }

    test('restores lapses, lastMistakeDate and lastRating after Again', () {
      final card = SrsCard(direction: CardDirection.targetToNative);
      SrsService.processReview(card, SrsRating.good);
      SrsService.processReview(card, SrsRating.good);
      final before = cloneOf(card);

      final record = ReviewHistoryRecord.capture(
        queueIndex: 2,
        card: card,
        rating: SrsRating.again,
      );
      SrsService.processReview(card, SrsRating.again);
      expect(card.lapses, before.lapses + 1); // sanity: review did mutate

      record.restore();
      expectSameState(card, before);
    });

    test('undoing several reviews in reverse order restores the original', () {
      final card = SrsCard(direction: CardDirection.targetToNative);
      final original = cloneOf(card);
      final records = <ReviewHistoryRecord>[];

      for (final rating in [SrsRating.good, SrsRating.again, SrsRating.easy]) {
        records.add(
          ReviewHistoryRecord.capture(
            queueIndex: records.length,
            card: card,
            rating: rating,
          ),
        );
        SrsService.processReview(card, rating);
      }

      for (final record in records.reversed) {
        record.restore();
      }
      expectSameState(card, original);
    });
  });
}
