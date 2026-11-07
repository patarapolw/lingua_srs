import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/services/study_queue_order.dart';

void main() {
  group('newCardLeadIn', () {
    test('a day starts with 10 reviews before new cards', () {
      expect(reviewsBeforeNewCards, 10);
      expect(newCardLeadIn(0), 10);
    });

    test("today's reviews count toward the lead-in", () {
      expect(newCardLeadIn(4), 6);
      expect(newCardLeadIn(10), 0);
      expect(newCardLeadIn(25), 0);
    });
  });

  group('mixNewCardsIntoReviews', () {
    List<String> reviews(int count) => [for (var i = 0; i < count; i++) 'r$i'];
    List<String> newCards(int count) => [for (var i = 0; i < count; i++) 'n$i'];

    test('no new card before the lead-in is done', () {
      final mixed = mixNewCardsIntoReviews(
        reviews: reviews(30),
        newCards: newCards(5),
        leadIn: 10,
      );

      expect(mixed.take(10), reviews(10));
      expect(mixed[10], 'n0');
    });

    test('new cards are spread evenly through the rest, in order', () {
      final mixed = mixNewCardsIntoReviews(
        reviews: reviews(30),
        newCards: newCards(5),
        leadIn: 10,
      );

      expect(mixed, hasLength(35));
      expect(mixed.where((id) => id.startsWith('n')), newCards(5));
      expect(mixed.where((id) => id.startsWith('r')), reviews(30));
      final positions = [for (var i = 0; i < 5; i++) mixed.indexOf('n$i')];
      // 20 reviews after the lead-in, one new card every 4 of them.
      expect(positions, [10, 15, 20, 25, 30]);
    });

    test('with no lead-in a new card comes first', () {
      final mixed = mixNewCardsIntoReviews(
        reviews: reviews(4),
        newCards: newCards(2),
        leadIn: 0,
      );

      expect(mixed, ['n0', 'r0', 'r1', 'n1', 'r2', 'r3']);
    });

    test('fewer reviews than the lead-in: reviews first, then new cards', () {
      final mixed = mixNewCardsIntoReviews(
        reviews: reviews(3),
        newCards: newCards(2),
        leadIn: 10,
      );

      expect(mixed, ['r0', 'r1', 'r2', 'n0', 'n1']);
    });

    test('more new cards than reviews left: they share the gaps', () {
      final mixed = mixNewCardsIntoReviews(
        reviews: reviews(2),
        newCards: newCards(4),
        leadIn: 0,
      );

      expect(mixed, ['n0', 'n1', 'r0', 'n2', 'n3', 'r1']);
    });

    test('nothing to mix in keeps the reviews as they are', () {
      expect(
        mixNewCardsIntoReviews(
          reviews: reviews(3),
          newCards: <String>[],
          leadIn: 10,
        ),
        reviews(3),
      );
      expect(
        mixNewCardsIntoReviews(
          reviews: <String>[],
          newCards: newCards(3),
          leadIn: 10,
        ),
        newCards(3),
      );
    });
  });

  group('interleaveByGroup', () {
    test('keeps every item once', () {
      final items = [for (var i = 0; i < 20; i++) i];
      final result = interleaveByGroup(items, (i) => '${i % 3}', Random(1));

      expect(result, unorderedEquals(items));
    });

    test('each round takes one item from every group', () {
      final items = [
        for (var i = 0; i < 4; i++) 'a$i',
        for (var i = 0; i < 4; i++) 'b$i',
      ];
      final result = interleaveByGroup(items, (s) => s[0], Random(2));

      for (var round = 0; round < 4; round++) {
        final pair = result.sublist(round * 2, round * 2 + 2);
        expect(pair.map((s) => s[0]).toSet(), {'a', 'b'});
      }
    });
  });
}
