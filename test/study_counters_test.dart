import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/lesson.dart';
import 'package:lingua_srs/models/srs_card.dart';
import 'package:lingua_srs/models/vocab_item.dart';
import 'package:lingua_srs/providers/app_provider.dart';
import 'package:lingua_srs/views/study_view.dart';

StudyCardItem itemFor(String word) => StudyCardItem(
  vocab: VocabItem(targetWord: word, translation: word, pos: 'nouns'),
  card: SrsCard(direction: CardDirection.targetToNative),
  lesson: Lesson(title: 'L'),
);

/// A history entry; [firstSession] false means "second pass of a card".
ReviewHistoryRecord record(
  StudyCardItem item,
  SrsRating rating, {
  required int index,
  bool firstSession = true,
}) => ReviewHistoryRecord.capture(
  queueIndex: index,
  card: item.card,
  rating: rating,
  wasFirstSessionRating: firstSession,
);

void main() {
  group('first-pass counters', () {
    test('empty history is 0 / 0', () {
      expect(firstPassRightCount([]), 0);
      expect(firstPassWrongCount([]), 0);
    });

    test('Again then a Good repeat counts the card once, as wrong', () {
      final a = itemFor('a');
      final history = [
        record(a, SrsRating.again, index: 0),
        record(a, SrsRating.good, index: 3, firstSession: false),
      ];

      expect(firstPassRightCount(history), 0);
      expect(firstPassWrongCount(history), 1);
    });

    test('Again then an Again repeat is still one wrong', () {
      final a = itemFor('a');
      final history = [
        record(a, SrsRating.again, index: 0),
        record(a, SrsRating.again, index: 3, firstSession: false),
      ];

      expect(firstPassRightCount(history), 0);
      expect(firstPassWrongCount(history), 1);
    });

    test('Good and Easy count as right on the first pass', () {
      final history = [
        record(itemFor('a'), SrsRating.good, index: 0),
        record(itemFor('b'), SrsRating.easy, index: 1),
      ];

      expect(firstPassRightCount(history), 2);
      expect(firstPassWrongCount(history), 0);
    });

    test('Again and Hard both count as wrong on the first pass', () {
      final history = [
        record(itemFor('a'), SrsRating.again, index: 0),
        record(itemFor('b'), SrsRating.hard, index: 1),
        record(itemFor('c'), SrsRating.good, index: 2),
      ];

      expect(firstPassRightCount(history), 1); // c
      expect(firstPassWrongCount(history), 2); // a, b
    });

    test('a Hard card answered Good on a repeat is still one wrong', () {
      final a = itemFor('a');
      final history = [
        record(a, SrsRating.hard, index: 0),
        record(a, SrsRating.good, index: 3, firstSession: false),
      ];

      expect(firstPassRightCount(history), 0);
      expect(firstPassWrongCount(history), 1);
    });

    test('mixed session', () {
      final a = itemFor('a');
      final b = itemFor('b');
      final history = [
        record(a, SrsRating.again, index: 0),
        record(b, SrsRating.good, index: 1),
        record(a, SrsRating.good, index: 4, firstSession: false),
      ];

      expect(firstPassRightCount(history), 1); // b
      expect(firstPassWrongCount(history), 1); // a
    });
  });

  group('distinctCardCount', () {
    test('a re-queued duplicate does not add a card', () {
      final a = itemFor('a');
      final b = itemFor('b');
      final duplicateOfA = StudyCardItem(
        vocab: a.vocab,
        card: a.card, // same card object, so same id
        lesson: a.lesson,
      );

      expect(distinctCardCount([a, b]), 2);
      expect(distinctCardCount([a, b, duplicateOfA]), 2);
    });

    test('empty queue is 0', () {
      expect(distinctCardCount([]), 0);
    });
  });

  group('distinctProgress', () {
    StudyCardItem dupOf(StudyCardItem s) =>
        StudyCardItem(vocab: s.vocab, card: s.card, lesson: s.lesson);

    test('advances once per card, not per queue position', () {
      final a = itemFor('a');
      final b = itemFor('b');
      final c = itemFor('c');
      final queue = [a, b, dupOf(a), c];

      expect(distinctProgress(queue, 0), 1);
      expect(distinctProgress(queue, 1), 2);
      expect(distinctProgress(queue, 2), 2); // repeat of a: no inflation
      expect(distinctProgress(queue, 3), 3);
      expect(distinctCardCount(queue), 3);
    });

    test('a card repeated several times is still one card', () {
      final a = itemFor('a');
      final b = itemFor('b');
      final queue = [a, b, dupOf(a), dupOf(a)];

      expect(distinctProgress(queue, 3), 2);
      expect(distinctCardCount(queue), 2);
    });

    test('an index past the end is clamped', () {
      final queue = [itemFor('a'), itemFor('b')];
      expect(distinctProgress(queue, 99), 2);
    });
  });

  group('last-answer counters (mistakes practice)', () {
    test('empty history is 0 / 0', () {
      expect(lastAnswerRightCount([]), 0);
      expect(lastAnswerWrongCount([]), 0);
    });

    test('Again is wrong until the card is answered Good later', () {
      final a = itemFor('a');
      final afterAgain = [record(a, SrsRating.again, index: 0)];
      expect(lastAnswerRightCount(afterAgain), 0);
      expect(lastAnswerWrongCount(afterAgain), 1);

      final afterGood = [
        ...afterAgain,
        record(a, SrsRating.good, index: 3, firstSession: false),
      ];
      expect(lastAnswerRightCount(afterGood), 1);
      expect(lastAnswerWrongCount(afterGood), 0);
    });

    test('a later Again undoes an earlier Good', () {
      final a = itemFor('a');
      final history = [
        record(a, SrsRating.good, index: 0),
        record(a, SrsRating.again, index: 3, firstSession: false),
      ];

      expect(lastAnswerRightCount(history), 0);
      expect(lastAnswerWrongCount(history), 1);
    });

    test('counts every card once, even when repeated', () {
      final a = itemFor('a');
      final b = itemFor('b');
      final history = [
        record(a, SrsRating.again, index: 0),
        record(b, SrsRating.good, index: 1),
        record(a, SrsRating.again, index: 4, firstSession: false),
        record(a, SrsRating.good, index: 6, firstSession: false),
      ];

      expect(lastAnswerRightCount(history), 2);
      expect(lastAnswerWrongCount(history), 0);
    });

    test('re-rating an earlier position does not override a later answer', () {
      final a = itemFor('a');
      final first = record(a, SrsRating.again, index: 0);
      final repeat = record(a, SrsRating.again, index: 5, firstSession: false);
      final history = [first, repeat];

      // Going back to position 0 and changing it to Good ...
      first.ratingGiven = SrsRating.good;

      // ... the repeat at position 5 is still the latest answer.
      expect(lastAnswerRightCount(history), 0);
      expect(lastAnswerWrongCount(history), 1);
    });

    test('history order does not matter, only queue position', () {
      final a = itemFor('a');
      final late = record(a, SrsRating.good, index: 5, firstSession: false);
      final early = record(a, SrsRating.again, index: 0);

      expect(lastAnswerRightCount([late, early]), 1);
      expect(lastAnswerWrongCount([late, early]), 0);
    });

    test('latestRatings maps card id to its latest rating', () {
      final a = itemFor('a');
      final b = itemFor('b');
      final ratings = latestRatings([
        record(a, SrsRating.again, index: 0),
        record(b, SrsRating.good, index: 1),
        record(a, SrsRating.good, index: 4, firstSession: false),
      ]);

      expect(ratings, {a.card.id: SrsRating.good, b.card.id: SrsRating.good});
    });
  });
}
