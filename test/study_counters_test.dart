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

    test('Hard, Good and Easy all count as right on the first pass', () {
      final history = [
        record(itemFor('a'), SrsRating.hard, index: 0),
        record(itemFor('b'), SrsRating.good, index: 1),
        record(itemFor('c'), SrsRating.easy, index: 2),
      ];

      expect(firstPassRightCount(history), 3);
      expect(firstPassWrongCount(history), 0);
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
}