import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/vocab_item.dart';
import 'package:lingua_srs/models/vocab_merge_record.dart';
import 'package:lingua_srs/services/vocab_pool_search.dart';

VocabGroup vg(
  String id,
  String ko,
  String en, {
  String pos = 'nouns',
  String notes = '',
}) => VocabGroup(
  id: id,
  entry: VocabItem(
    id: id,
    targetWord: ko,
    translation: en,
    pos: pos,
    notes: notes,
  ),
  reviews: 0,
)..lessonTitles.add('L');

List<String> ids(List<VocabGroup> groups) => [for (final g in groups) g.id];

void main() {
  final eat = vg('eat', '먹다', 'to eat', pos: 'verbs');
  final drink = vg('drink', '마시다', 'to drink', pos: 'verbs');
  final apple = vg('apple', '사과', 'apple');
  final apology = vg('apology', '사과', 'apology');
  final beautiful = vg('beautiful', '아름답다', 'beautiful', pos: 'adjectives');
  final pool = [eat, drink, apple, apology, beautiful];

  group('VocabPoolSearch.search without a query', () {
    test('lists every word sorted by target, then by meaning', () {
      expect(ids(VocabPoolSearch.search('', pool)), [
        'drink',
        'eat',
        'apology',
        'apple',
        'beautiful',
      ]);
    });

    test('a blank query counts as no query', () {
      expect(VocabPoolSearch.search('   ', pool), hasLength(pool.length));
    });

    test('does not reorder or change the list it is given', () {
      final before = ids(pool);
      VocabPoolSearch.search('', pool);
      expect(ids(pool), before);
    });

    test('an empty pool gives an empty result', () {
      expect(VocabPoolSearch.search('', const []), isEmpty);
    });
  });

  group('VocabPoolSearch.search with Korean', () {
    test('finds a word by its Korean form', () {
      expect(ids(VocabPoolSearch.search('먹다', pool)), ['eat']);
    });

    test('finds a word by a conjugated form of it', () {
      expect(ids(VocabPoolSearch.search('아름답고', pool)), ['beautiful']);
    });

    test('words sharing a Korean form are all returned', () {
      expect(
        ids(VocabPoolSearch.search('사과', pool)),
        unorderedEquals(['apple', 'apology']),
      );
    });

    test('a Korean word that nothing has gives no result', () {
      expect(VocabPoolSearch.search('학교', pool), isEmpty);
    });
  });

  group('VocabPoolSearch.search with English', () {
    test('finds a word by its meaning', () {
      expect(ids(VocabPoolSearch.search('eat', pool)), ['eat']);
    });

    test('ignores case and surrounding spaces', () {
      expect(ids(VocabPoolSearch.search('  EAT ', pool)), ['eat']);
    });

    test('ranks the same meaning, then a longer one, then notes only', () {
      final longer = vg('longer', '예쁘다', 'very beautiful', pos: 'adjectives');
      final notesOnly = vg(
        'notes',
        '좋다',
        'nice',
        pos: 'adjectives',
        notes: 'beautiful',
      );
      final hits = VocabPoolSearch.search('beautiful', [
        notesOnly,
        longer,
        beautiful,
        eat,
      ]);
      expect(ids(hits), ['beautiful', 'longer', 'notes']);
    });

    test('an English word that nothing has gives no result', () {
      expect(VocabPoolSearch.search('school', pool), isEmpty);
    });
  });

  group('VocabPoolSearch.search options', () {
    test('keeps only the part of speech asked for', () {
      expect(ids(VocabPoolSearch.search('', pool, pos: 'verbs')), [
        'drink',
        'eat',
      ]);
    });

    test('the part of speech ignores case and spaces', () {
      expect(ids(VocabPoolSearch.search('', pool, pos: ' Verbs ')), [
        'drink',
        'eat',
      ]);
    });

    test('combines a query with a part of speech', () {
      expect(VocabPoolSearch.search('먹다', pool, pos: 'nouns'), isEmpty);
      expect(ids(VocabPoolSearch.search('먹다', pool, pos: 'verbs')), ['eat']);
    });

    test('limit cuts the result', () {
      expect(ids(VocabPoolSearch.search('', pool, limit: 2)), ['drink', 'eat']);
    });

    test('a limit above the size changes nothing', () {
      expect(VocabPoolSearch.search('', pool, limit: 99), hasLength(5));
    });
  });

  group('VocabPoolSearch.posOptions', () {
    test('lists each part of speech once, sorted', () {
      expect(VocabPoolSearch.posOptions(pool), [
        'adjectives',
        'nouns',
        'verbs',
      ]);
    });

    test('merges spellings that differ in case or spaces', () {
      final more = [vg('x', '집', 'house', pos: ' Nouns '), apple];
      expect(VocabPoolSearch.posOptions(more), ['Nouns']);
    });

    test('leaves out words without one', () {
      expect(
        VocabPoolSearch.posOptions([vg('x', '집', 'house', pos: '')]),
        isEmpty,
      );
    });
  });
}
