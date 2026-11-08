import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/lesson.dart';
import 'package:lingua_srs/models/vocab_item.dart';
import 'package:lingua_srs/providers/app_provider.dart';
import 'package:lingua_srs/views/lesson_detail_view.dart';
import 'package:lingua_srs/views/study_view.dart';

void main() {
  group('nextCategorySelection', () {
    test('a tap selects only that part of speech', () {
      expect(nextCategorySelection({}, 'Nouns'), {'nouns'});
      expect(nextCategorySelection({'nouns', 'verbs'}, 'Verbs'), {'verbs'});
    });

    test('a tap on the only one selected goes back to All', () {
      expect(nextCategorySelection({'nouns'}, 'Nouns'), isEmpty);
    });

    test('adding toggles one part of speech in the selection', () {
      expect(nextCategorySelection({'nouns'}, 'Verbs', add: true), {
        'nouns',
        'verbs',
      });
      expect(
        nextCategorySelection({'nouns', 'verbs'}, 'Nouns', add: true),
        {'verbs'},
      );
      expect(nextCategorySelection({}, 'Nouns', add: true), {'nouns'});
    });
  });

  group('previewQueue', () {
    final lesson = Lesson(title: 'Preview');
    StudyCardItem item(String ko, String pos) {
      final vocab = VocabItem(targetWord: ko, translation: ko, pos: pos);
      return StudyCardItem(
        vocab: vocab,
        card: vocab.cardTargetToNative,
        lesson: lesson,
      );
    }

    final cards = [
      for (var i = 0; i < 6; i++) item('명사$i', 'nouns'),
      for (var i = 0; i < 6; i++) item('동사$i', 'verbs'),
    ];

    test('keeps every card once', () {
      final queue = previewQueue(cards, Random(1));
      expect(queue, hasLength(cards.length));
      expect(queue.toSet(), cards.toSet());
    });

    test('shuffles, mixing parts of speech', () {
      String order(int seed) => previewQueue(
        cards,
        Random(seed),
      ).map((card) => card.vocab.targetWord).join(' ');
      final orders = {for (var seed = 0; seed < 5; seed++) order(seed)};
      expect(orders.length, greaterThan(1));
      // Each round takes a card of every part of speech, so the first two
      // are a noun and a verb.
      final queue = previewQueue(cards, Random(3));
      expect({queue[0].vocab.pos, queue[1].vocab.pos}, {'nouns', 'verbs'});
    });
  });
}
