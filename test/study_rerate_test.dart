import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/lesson.dart';
import 'package:lingua_srs/models/srs_card.dart';
import 'package:lingua_srs/models/vocab_item.dart';
import 'package:lingua_srs/providers/app_provider.dart';
import 'package:lingua_srs/services/srs_service.dart';
import 'package:lingua_srs/views/study_view.dart';

StudyCardItem itemFor(String word) => StudyCardItem(
  vocab: VocabItem(targetWord: word, translation: word, pos: 'nouns'),
  card: SrsCard(direction: CardDirection.targetToNative),
  lesson: Lesson(title: 'L'),
);

StudyCardItem dupOf(StudyCardItem s) =>
    StudyCardItem(vocab: s.vocab, card: s.card, lesson: s.lesson);

/// Mimics what _rateCard does to the card and history.
ReviewHistoryRecord answer(
  SrsCard card,
  SrsRating rating, {
  required int index,
  bool firstSession = true,
}) {
  final record = ReviewHistoryRecord.capture(
    queueIndex: index,
    card: card,
    rating: rating,
    wasFirstSessionRating: firstSession,
  );
  if (firstSession) SrsService.processReview(card, rating);
  // A repeat (second-pass) review no longer changes the card.
  return record;
}

void reRate(
  ReviewHistoryRecord record,
  SrsRating rating, {
  required List<StudyCardItem> queue,
  required int answered,
  Set<String>? againIds,
  List<ReviewHistoryRecord>? history,
  bool practice = false,
}) => reRateRecord(
  record: record,
  rating: rating,
  practiceOnly: practice,
  history: history ?? [record],
  queue: queue,
  answeredCount: answered,
  againCardIds: againIds ?? <String>{},
  makeDuplicate: dupOf,
);

void main() {
  group('reRateRecord', () {
    test('Good -> Again updates the card and re-queues it ahead', () {
      final a = itemFor('a');
      final queue = [a, itemFor('b'), itemFor('c'), itemFor('d'), itemFor('e')];
      final againIds = <String>{};
      final record = answer(a.card, SrsRating.good, index: 0);

      reRate(record, SrsRating.again,
          queue: queue, answered: 2, againIds: againIds);

      expect(a.card.lapses, 1);
      expect(a.card.interval, 0);
      expect(a.card.status, SrsStatus.learning);
      expect(againIds, {a.card.id});
      expect(queue.length, 6);
      expect(queue[5], same(record.requeuedItem));
      expect(queue[5].card, same(a.card));
      expect(record.ratingGiven, SrsRating.again);
    });

    test('Again -> Good removes the unanswered duplicate', () {
      final a = itemFor('a');
      final dup = dupOf(a);
      final queue = [a, itemFor('b'), itemFor('c'), itemFor('d'), dup];
      final againIds = {a.card.id};
      final record = answer(a.card, SrsRating.again, index: 0)
        ..requeuedItem = dup;

      reRate(record, SrsRating.good,
          queue: queue, answered: 2, againIds: againIds);

      expect(queue.length, 4);
      expect(queue.contains(dup), isFalse);
      expect(againIds, isEmpty);
      expect(record.requeuedItem, isNull);
      expect(a.card.lapses, 0);
      expect(a.card.interval, 1);
      expect(a.card.repetitions, 1);
      expect(a.card.status, SrsStatus.review);
    });

    test('Again -> Good keeps a duplicate that was already answered', () {
      final a = itemFor('a');
      final dup = dupOf(a);
      final queue = [a, itemFor('b'), itemFor('c'), itemFor('d'), dup];
      final record = answer(a.card, SrsRating.again, index: 0)
        ..requeuedItem = dup;

      reRate(record, SrsRating.good,
          queue: queue, answered: 5, againIds: {a.card.id});

      expect(queue.length, 5);
      expect(queue[4], same(dup));
      expect(record.requeuedItem, isNull);
    });

    test('Good -> Easy changes the interval without touching the queue', () {
      final a = itemFor('a');
      final queue = [a, itemFor('b'), itemFor('c')];
      final record = answer(a.card, SrsRating.good, index: 0);

      reRate(record, SrsRating.easy, queue: queue, answered: 1);

      expect(a.card.interval, 4);
      expect(a.card.repetitions, 1);
      expect(a.card.lapses, 0);
      expect(queue.length, 3);
      expect(record.requeuedItem, isNull);
    });

    test('re-rating rolls back to the pre-review state first', () {
      final a = itemFor('a');
      SrsService.processReview(a.card, SrsRating.good);
      SrsService.processReview(a.card, SrsRating.good); // rep 2, interval 6
      final record = answer(a.card, SrsRating.good, index: 0); // interval 15
      expect(a.card.interval, 15);

      reRate(record, SrsRating.hard, queue: [a], answered: 1);

      expect(a.card.repetitions, 3);
      expect(a.card.interval, 7); // (6 * 1.2).round()
      expect(a.card.easeFactor, closeTo(2.35, 1e-9));
    });

    test('re-marking the first review leaves a later repeat record alone', () {
      final a = itemFor('a');
      final dup = dupOf(a);
      // Queue positions: 0 = first pass, 3 = the re-queued repeat (answered).
      final queue = [a, itemFor('b'), itemFor('c'), dup];
      final againIds = {a.card.id};

      final first = answer(a.card, SrsRating.again, index: 0)
        ..requeuedItem = dup;
      final repeat = answer(
        a.card,
        SrsRating.good,
        index: 3,
        firstSession: false,
      );

      reRate(
        first,
        SrsRating.good,
        queue: queue,
        answered: 4,
        againIds: againIds,
        history: [first, repeat],
      );

      // First pass is now a normal Good review.
      expect(a.card.interval, 1);
      expect(a.card.lapses, 0);
      expect(a.card.status, SrsStatus.review);
      expect(first.ratingGiven, SrsRating.good);
      // The already-answered repeat is left exactly as it was.
      expect(repeat.ratingGiven, SrsRating.good);
      expect(queue.length, 4);
      expect(queue[3], same(dup));
      expect(first.requeuedItem, isNull);
      expect(againIds, isEmpty);
    });

    test('re-rating a repeat record leaves the card untouched', () {
      final a = itemFor('a');
      final queue = [
        a,
        itemFor('b'),
        itemFor('c'),
        dupOf(a), // index 3: the repeat being re-rated
        itemFor('e'),
        itemFor('f'),
        itemFor('g'),
      ];
      answer(a.card, SrsRating.again, index: 0); // first pass: Again
      final repeat = answer(
        a.card,
        SrsRating.good,
        index: 3,
        firstSession: false,
      );

      // Everything the first-pass Again left on the card.
      final interval = a.card.interval;
      final lapses = a.card.lapses;
      final status = a.card.status;
      final dueDate = a.card.dueDate;
      final lastRating = a.card.lastRating;
      final mistakeDate = a.card.lastMistakeDate;
      expect(lastRating, SrsRating.again);
      expect(mistakeDate, isNotNull);

      void expectCardUnchanged() {
        expect(a.card.interval, interval);
        expect(a.card.lapses, lapses);
        expect(a.card.status, status);
        expect(a.card.dueDate, dueDate);
        expect(a.card.lastRating, lastRating);
        expect(a.card.lastMistakeDate, mistakeDate);
      }

      final againIds = <String>{};

      // Good -> Again: record and queue change, card does not.
      reRate(
        repeat,
        SrsRating.again,
        queue: queue,
        answered: 4,
        againIds: againIds,
      );
      expect(repeat.ratingGiven, SrsRating.again);
      expect(againIds, {a.card.id});
      expect(queue.length, 8); // re-queued after the 3 unanswered cards
      expectCardUnchanged();

      // Again -> Good: duplicate removed, card still untouched.
      reRate(
        repeat,
        SrsRating.good,
        queue: queue,
        answered: 4,
        againIds: againIds,
      );
      expect(repeat.ratingGiven, SrsRating.good);
      expect(againIds, isEmpty);
      expect(queue.length, 7);
      expectCardUnchanged();
    });

    test('mistakes practice toggles mistakesClearedAt, not SRS state', () {
      final a = itemFor('a');
      final queue = [a, itemFor('b'), itemFor('c'), itemFor('d')];
      final record = ReviewHistoryRecord.capture(
        queueIndex: 0, card: a.card, rating: SrsRating.good);
      a.card.mistakesClearedAt = DateTime.now(); // what Good does in practice

      reRate(record, SrsRating.again,
          queue: queue, answered: 1, practice: true);
      expect(a.card.mistakesClearedAt, isNull);
      expect(a.card.interval, 0);

      reRate(record, SrsRating.good,
          queue: queue, answered: 1, practice: true,
          againIds: {a.card.id});
      expect(a.card.mistakesClearedAt, isNotNull);
    });

    test('at the end of the queue, a lone Again card is not re-queued', () {
      final a = itemFor('a');
      final queue = [a, itemFor('b')];
      final record = answer(a.card, SrsRating.good, index: 0);

      reRate(record, SrsRating.again, queue: queue, answered: 2);

      expect(queue.length, 2);
      expect(record.requeuedItem, isNull);
    });

    test('at the end of the queue, re-queues if other Again cards remain', () {
      final a = itemFor('a');
      final queue = [a, itemFor('b')];
      final record = answer(a.card, SrsRating.good, index: 0);

      reRate(record, SrsRating.again,
          queue: queue, answered: 2, againIds: {'other-card'});

      expect(queue.length, 3);
      expect(queue.last, same(record.requeuedItem));
    });

    test('undo after a re-mark restores the pre-review state', () {
      final a = itemFor('a');
      final original = SrsCard(
        direction: a.card.direction,
        dueDate: a.card.dueDate,
      );
      final record = answer(a.card, SrsRating.good, index: 0);

      reRate(record, SrsRating.again,
          queue: [a, itemFor('b'), itemFor('c'), itemFor('d')], answered: 1);
      record.restore(); // what _undo does

      expect(a.card.interval, original.interval);
      expect(a.card.lapses, 0);
      expect(a.card.status, SrsStatus.isNew);
      expect(a.card.lastRating, isNull);
    });
  });
}