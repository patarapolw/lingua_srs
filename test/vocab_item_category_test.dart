import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/vocab_item.dart';

VocabItem wordIn(String pos, {List<String>? sectionPath}) => VocabItem(
  targetWord: '먹다',
  translation: 'to eat',
  pos: pos,
  sectionPath: sectionPath,
);

void main() {
  group('VocabItem.isVerbOrAdjective', () {
    test('is true when the category says verb or adjective', () {
      for (final category in [
        'verb',
        'verbs',
        'Verbs',
        ' Adjectives ',
        'adjective',
        'passive verbs',
        'irregular verbs',
        'Verbs (-하다)',
        'adverbs and verbs',
      ]) {
        expect(VocabItem.isVerbOrAdjective(category), isTrue, reason: category);
      }
    });

    test('is false for the other parts of speech and for categories', () {
      for (final category in [
        'nouns',
        'numbers',
        'food',
        'general',
        'daily life',
        '',
      ]) {
        expect(
          VocabItem.isVerbOrAdjective(category),
          isFalse,
          reason: category,
        );
      }
    });

    test('is false for adverbs and verbal nouns, which have verb in them', () {
      for (final category in [
        'adverbs',
        'Adverbs',
        'adverb',
        'adverbial phrases',
        'verbal nouns',
        'Verbal noun',
      ]) {
        expect(
          VocabItem.isVerbOrAdjective(category),
          isFalse,
          reason: category,
        );
      }
    });
  });

  group('VocabItem card directions', () {
    test('a verb or adjective is reviewed from the meaning to the word', () {
      for (final pos in ['verbs', 'adjectives', 'passive verbs']) {
        final word = wordIn(pos);

        expect(word.cardTargetToNative.isEnabled, isFalse, reason: pos);
        expect(word.cardNativeToTarget.isEnabled, isTrue, reason: pos);
      }
    });

    test('an adverb is reviewed from the word to the meaning, like a noun', () {
      for (final pos in ['adverbs', 'nouns']) {
        final word = wordIn(pos);

        expect(word.cardTargetToNative.isEnabled, isTrue, reason: pos);
        expect(word.cardNativeToTarget.isEnabled, isFalse, reason: pos);
      }
    });
  });

  group('VocabItem.categoryLabels', () {
    test('is the part of speech when there are no sections', () {
      expect(wordIn('verbs').categoryLabels, ['verbs']);
    });

    test('lists the part of speech and the sections once', () {
      expect(
        wordIn('verbs', sectionPath: ['verbs', 'passive verbs']).categoryLabels,
        ['verbs', 'passive verbs'],
      );
      expect(
        wordIn('food', sectionPath: ['daily life', 'food']).categoryLabels,
        ['food', 'daily life'],
      );
    });

    test('leaves out blank labels', () {
      expect(wordIn('').categoryLabels, isEmpty);
      expect(wordIn('', sectionPath: ['  ', 'verbs']).categoryLabels, [
        'verbs',
      ]);
    });
  });
}
