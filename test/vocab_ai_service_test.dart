import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/vocab_item.dart';
import 'package:lingua_srs/models/vocab_merge_record.dart';
import 'package:lingua_srs/services/vocab_ai_service.dart';

VocabGroup vocabGroup(String id, String ko, String en, {int reviews = 0}) =>
    VocabGroup(
      id: id,
      entry: VocabItem(id: id, targetWord: ko, translation: en, pos: 'adjectives'),
      reviews: reviews,
    )..lessonTitles.add('Lesson');

void main() {
  group('VocabSimilarity', () {
    test('normalizes "to be" and articles', () {
      expect(VocabSimilarity.normalizeTranslation('To be beautiful'), 'beautiful');
      expect(VocabSimilarity.normalizeTranslation('to eat'), 'eat');
      expect(VocabSimilarity.normalizeTranslation('a pear (fruit)'), 'pear');
      expect(VocabSimilarity.normalizeTranslation('to be'), 'to be');
    });

    test('candidate groups need the same target and different ids', () {
      final groups = VocabSimilarity.findCandidateGroups([
        vocabGroup('a', '아름답다', 'beautiful'),
        vocabGroup('b', '아름답다', 'to be beautiful'),
        vocabGroup('c', '배', 'pear'),
      ]);
      expect(groups, hasLength(1));
      expect(groups.single.items.map((g) => g.id), ['a', 'b']);
    });
  });

  group('VocabAiPrompts.parseMergeSuggestions', () {
    final groups = VocabSimilarity.findCandidateGroups([
      vocabGroup('a', '아름답다', 'beautiful'),
      vocabGroup('b', '아름답다', 'to be beautiful'),
    ]);

    test('accepts valid suggestions, also inside a code fence', () {
      const reply = '```json\n{"merges":[{"group":1,"keep":"a","merge":["b"],"reason":"same"}]}\n```';
      final result = VocabAiPrompts.parseMergeSuggestions(reply, groups);
      expect(result.single.keepId, 'a');
      expect(result.single.mergeIds, ['b']);
      expect(result.single.reason, 'same');
    });

    test('drops unknown ids, self merges and unknown groups', () {
      const reply = '{"merges":['
          '{"group":1,"keep":"a","merge":["a","zzz"]},'
          '{"group":9,"keep":"a","merge":["b"]},'
          '{"group":1,"keep":"nope","merge":["b"]}]}';
      expect(VocabAiPrompts.parseMergeSuggestions(reply, groups), isEmpty);
    });

    test('does not reuse an id in two suggestions', () {
      const reply = '{"merges":['
          '{"group":1,"keep":"a","merge":["b"]},'
          '{"group":1,"keep":"b","merge":["a"]}]}';
      expect(VocabAiPrompts.parseMergeSuggestions(reply, groups), hasLength(1));
    });

    test('rejects non-JSON replies', () {
      expect(() => VocabAiPrompts.parseMergeSuggestions('nope', groups),
          throwsFormatException);
    });
  });

  test('withSurvivor keeps the most reviewed entry', () {
    const s = VocabMergeSuggestion(keepId: 'a', mergeIds: ['b']);
    final changed = s.withSurvivor({'a': 1, 'b': 5});
    expect(changed.keepId, 'b');
    expect(changed.mergeIds, ['a']);
    expect(s.withSurvivor({'a': 5, 'b': 5}).keepId, 'a');
  });

  group('VocabAiPrompts.parseHint', () {
    test('cleans quotes and spaces', () {
      expect(VocabAiPrompts.parseHint('{"hint":"  \\"body  part\\" "}'), 'body part');
    });
    test('rejects an empty hint', () {
      expect(() => VocabAiPrompts.parseHint('{"hint":"  "}'), throwsFormatException);
    });
  });
}