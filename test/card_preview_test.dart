import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/srs_card.dart';
import 'package:lingua_srs/models/vocab_item.dart';
import 'package:lingua_srs/services/card_preview.dart';

VocabItem word(String ko, String en, [String pos = 'noun']) =>
    VocabItem(targetWord: ko, translation: en, pos: pos);

void main() {
  group('previewNewCards', () {
    test('lists each new card in word order, KO ➔ EN first', () {
      final noun = word('집', 'house')..cardNativeToTarget.isEnabled = true;
      final verb = word('가다', 'go', 'verb');

      final cards = previewNewCards([noun, verb]);

      expect(cards.map((c) => (c.vocab.targetWord, c.direction)).toList(), [
        ('집', CardDirection.targetToNative),
        ('집', CardDirection.nativeToTarget),
        ('가다', CardDirection.nativeToTarget),
      ]);
    });

    test('leaves out hidden, suspended and started cards', () {
      final hidden = word('물', 'water')..cardTargetToNative.isEnabled = false;
      final suspended = word('불', 'fire')
        ..cardTargetToNative.isSuspended = true;
      final started = word('산', 'mountain')
        ..cardTargetToNative.status = SrsStatus.review;
      final fresh = word('책', 'book');

      final cards = previewNewCards([hidden, suspended, started, fresh]);

      expect(cards.map((c) => c.vocab.targetWord), ['책']);
    });

    test('shows a card shared by two words once', () {
      final first = word('눈', 'eye');
      final second = VocabItem(
        targetWord: '눈',
        translation: 'eye',
        pos: 'noun',
        cardTargetToNative: first.cardTargetToNative,
        cardNativeToTarget: first.cardNativeToTarget,
      );

      expect(previewNewCards([first, second]), hasLength(1));
    });
  });
}
