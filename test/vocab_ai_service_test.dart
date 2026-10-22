import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/vocab_item.dart';
import 'package:lingua_srs/models/vocab_merge_record.dart';
import 'package:lingua_srs/services/vocab_ai_service.dart';

VocabGroup vg(
  String id,
  String ko,
  String en, {
  int reviews = 0,
  String notes = '',
}) => VocabGroup(
  id: id,
  entry: VocabItem(
    id: id,
    targetWord: ko,
    translation: en,
    pos: 'adjectives',
    notes: notes,
  ),
  reviews: reviews,
)..lessonTitles.add('Lesson');

void main() {
  group('VocabSimilarity', () {
    test('normalizes "to be" and articles', () {
      expect(VocabSimilarity.normalizeTranslation('be'), 'be');
      expect(
        VocabSimilarity.normalizeTranslation('to be a teacher'),
        'teacher',
      );
      expect(
        VocabSimilarity.normalizeTranslation('To be beautiful'),
        'beautiful',
      );
      expect(VocabSimilarity.normalizeTranslation('to eat'), 'eat');
      expect(VocabSimilarity.normalizeTranslation('a pear (fruit)'), 'pear');
      expect(VocabSimilarity.normalizeTranslation('to be'), 'to be');
    });

    test('candidate groups need the same target and different ids', () {
      final groups = VocabSimilarity.findCandidateGroups([
        vg('a', '아름답다', 'beautiful'),
        vg('b', '아름답다', 'to be beautiful'),
        vg('c', '배', 'pear'),
      ]);
      expect(groups, hasLength(1));
      expect(groups.single.items.map((g) => g.id), ['a', 'b']);
    });
  });

  group('merge prompt and parser (numbered entries)', () {
    final groups = VocabSimilarity.findCandidateGroups([
      vg('auto-aaa', '아름답다', 'beautiful'),
      vg('auto-bbb', '아름답다', 'to be beautiful'),
      vg('auto-ccc', '배', 'pear'),
      vg('auto-ddd', '배', 'stomach'),
    ]); // entries 1,2 are group 1; entries 3,4 are group 2

    test('prompt numbers entries across groups and never sends ids', () {
      final user = VocabAiPrompts.mergeMessages(groups)[1].content;
      expect(user, contains('1|adjectives|beautiful'));
      expect(user, contains('2|adjectives|to be beautiful'));
      expect(user, contains('3|adjectives|pear'));
      expect(user, isNot(contains('auto-')));
    });

    test('notes are cut to one short line', () {
      final long = [
        vg('x', '크다', 'big', notes: 'line one\nline two ${'z' * 200}'),
        vg('y', '크다', 'large'),
      ];
      final user = VocabAiPrompts.mergeMessages(
        VocabSimilarity.findCandidateGroups(long),
      )[1].content;
      final line = RegExp(r'1\|adjectives\|big\|[^"]*')
          .firstMatch(user)!
          .group(0)!;
      expect(line.length, lessThan(100));
      expect(line, isNot(contains(r'\n')));
    });

    test('maps numbers back to ids, also inside a code fence', () {
      const reply =
          '```json\n{"merges":[{"keep":1,"merge":[2],"reason":"same"}]}\n```';
      final result = VocabAiPrompts.parseMergeSuggestions(reply, groups);
      expect(result.single.keepId, 'auto-aaa');
      expect(result.single.mergeIds, ['auto-bbb']);
      expect(result.single.reason, 'same');
    });

    test('accepts numbers sent as strings or whole doubles', () {
      final result = VocabAiPrompts.parseMergeSuggestions(
        '{"merges":[{"keep":"3","merge":[4.0]}]}',
        groups,
      );
      expect(result.single.keepId, 'auto-ccc');
      expect(result.single.mergeIds, ['auto-ddd']);
    });

    test('rejects numbers from another group, out of range, or self', () {
      const reply =
          '{"merges":['
          '{"keep":1,"merge":[3]},' // other group
          '{"keep":9,"merge":[1]},' // out of range
          '{"keep":1,"merge":[1]},' // itself
          '{"keep":1.5,"merge":[2]}]}'; // not an integer
      expect(VocabAiPrompts.parseMergeSuggestions(reply, groups), isEmpty);
    });

    test('does not reuse an entry in two suggestions', () {
      const reply =
          '{"merges":[{"keep":1,"merge":[2]},{"keep":2,"merge":[1]}]}';
      expect(VocabAiPrompts.parseMergeSuggestions(reply, groups), hasLength(1));
    });

    test(
      'a reply cut off mid-string is a FormatException (the reported bug)',
      () {
        const cut = '{"merges":[{"keep":1,"merge":[2],"reason":"sam';
        expect(
          () => VocabAiPrompts.parseMergeSuggestions(cut, groups),
          throwsFormatException,
        );
      },
    );
  });

  test('withSurvivor keeps the most reviewed entry', () {
    const s = VocabMergeSuggestion(keepId: 'a', mergeIds: ['b']);
    final changed = s.withSurvivor({'a': 1, 'b': 5});
    expect(changed.keepId, 'b');
    expect(changed.mergeIds, ['a']);
    expect(s.withSurvivor({'a': 5, 'b': 5}).keepId, 'a');
  });

  group('similar meanings', () {
    final target = VocabItem(
      targetWord: '크다',
      translation: 'big',
      pos: 'adjectives',
    );

    test('pool: same POS, different Korean form, other id', () {
      final pool = VocabSimilarity.similarPool(target, [
        vg('a', '넓다', 'wide'),
        vg('b', '크다', 'to be big'), // same Korean form: a merge candidate
        VocabGroup(
          id: 'c',
          entry: VocabItem(
            id: 'c',
            targetWord: '배',
            translation: 'pear',
            pos: 'nouns',
          ),
          reviews: 0,
        ),
        vg(target.id, '크다', 'big'), // itself
      ]);
      expect(pool.map((g) => g.id), ['a']);
    });

    test('shortlist keeps everything under the limit, else the closest', () {
      final pool = [
        vg('a', '넓다', 'wide'),
        vg('b', '거대하다', 'big and huge'),
        vg('c', '작다', 'small'),
        vg('d', '크게', 'big'),
      ];
      expect(VocabSimilarity.shortlist(target, pool, limit: 10), pool);
      final top = VocabSimilarity.shortlist(target, pool, limit: 2);
      expect(top.map((g) => g.id).toSet(), {'b', 'd'});
    });

    test('prompt numbers the pool and never sends ids', () {
      final pool = [
        vg('auto-aaa', '넓다', 'wide'),
        vg('auto-bbb', '작다', 'small'),
      ];
      final prompt = VocabAiPrompts.enKoPrompt(target, const [], pool);
      final user = prompt.messages[1].content;
      expect(user, contains('1|넓다|wide'));
      expect(user, contains('2|작다|small'));
      expect(user, isNot(contains('auto-')));
      expect(prompt.ids, ['auto-aaa', 'auto-bbb']);
    });

    test('parse maps numbers back to ids and cleans hints', () {
      final result = VocabAiPrompts.parseSimilarResult(
        '{"hint":" \\"General size\\" ","similar":['
        '{"n":2,"hint":"area or width"},{"n":2,"hint":"dup"},'
        '{"n":9,"hint":"out of range"},{"n":1}]}',
        ['id-1', 'id-2'],
      );
      expect(result.hint, 'General size');
      expect(result.similar.map((s) => s.id), ['id-2', 'id-1']);
      expect(result.similar.first.hint, 'area or width');
      expect(result.similar.last.hint, '');
    });

    test('parse caps the list and tolerates an empty answer', () {
      final ids = [for (var i = 1; i <= 12; i++) 'id-$i'];
      final many =
          '{"hint":"","similar":[${[for (var i = 1; i <= 12; i++) '{"n":$i,"hint":"h"}'].join(',')}]}';
      expect(
        VocabAiPrompts.parseSimilarResult(many, ids).similar,
        hasLength(8),
      );
      final none = VocabAiPrompts.parseSimilarResult('{}', ids);
      expect(none.hint, '');
      expect(none.similar, isEmpty);
    });

    test('same-form pool: same Korean spelling, any POS, other id', () {
      final noun = VocabItem(
        id: 'n',
        targetWord: '배',
        translation: 'pear',
        pos: 'nouns',
      );
      final pool = VocabSimilarity.sameFormPool(noun, [
        VocabGroup(
          id: 'm',
          entry: VocabItem(
            id: 'm',
            targetWord: ' 배 ',
            translation: 'ship',
            pos: 'verbs',
          ),
          reviews: 0,
        ),
        vg('x', '크다', 'big'),
        vg('n', '배', 'pear'), // itself
      ]);
      expect(pool.map((g) => g.id), ['m']);
    });

    test('KO-EN prompt is tiny: no Korean lines, no ids', () {
      final noun = VocabItem(
        id: 'n',
        targetWord: '배',
        translation: 'pear',
        pos: 'nouns',
      );
      final others = [
        VocabGroup(
          id: 'auto-secret-id',
          entry: VocabItem(
            id: 'auto-secret-id',
            targetWord: '배',
            translation: 'stomach',
            pos: 'nouns',
          ),
          reviews: 0,
        ),
      ];
      final prompt = VocabAiPrompts.koEnPrompt(noun, others);
      final user = prompt.messages[1].content;
      expect(user, contains('1|nouns|stomach'));
      expect(user, isNot(contains('auto-')));
      expect(prompt.ids, ['auto-secret-id']);

      final bigPool = [
        for (var i = 0; i < 300; i++) vg('id$i', '단어$i', 'word $i'),
      ];
      final enKo = VocabAiPrompts.enKoPrompt(
        noun,
        const [],
        bigPool,
      ).messages[1].content;
      expect(user.length * 10, lessThan(enKo.length));
    });
  });
}
