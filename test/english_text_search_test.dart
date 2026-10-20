import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/vocab_item.dart';
import 'package:lingua_srs/models/vocab_merge_record.dart';
import 'package:lingua_srs/services/english_text_search.dart';

VocabGroup g(
  String id,
  String ko,
  String en, {
  String pos = 'adjectives',
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

void main() {
  group('EnglishTextSearch.tokens', () {
    test('drops stop words, markdown and case', () {
      expect(EnglishTextSearch.tokens('To be BIG'), {'big'});
      expect(EnglishTextSearch.tokens('**big** <b>and</b> huge'), {
        'big',
        'huge',
      });
    });

    test('keeps stop words when nothing else is left', () {
      expect(EnglishTextSearch.tokens('to be'), {'to', 'be'});
    });

    test('light stemming', () {
      expect(EnglishTextSearch.stem('walked'), 'walk');
      expect(EnglishTextSearch.stem('houses'), 'house');
      expect(EnglishTextSearch.stem('running'), 'runn');
      expect(EnglishTextSearch.stem('glass'), 'glass');
      expect(EnglishTextSearch.stem('is'), 'is');
    });
  });

  group('EnglishTextSearch.score', () {
    int s(String q, String t, {String notes = ''}) =>
        EnglishTextSearch.score(q, translation: t, notes: notes);

    test('orders exact > all words > prefix > partial > notes > none', () {
      expect(s('big', 'to be big'), 100);
      expect(s('big', 'big and huge'), 60);
      expect(s('hug', 'huge'), 40);
      expect(s('big house', 'big'), 25);
      expect(s('size', 'large', notes: 'general size'), 10);
      expect(s('size', 'large', notes: 'size and shape'), 10);
      expect(s('pear', 'big'), 0);
    });

    test('an empty query matches nothing', () {
      expect(s('', 'big'), 0);
      expect(s('   ', 'big'), 0);
    });

    test('running matches run by prefix', () {
      expect(s('run', 'running'), 40);
    });
  });

  group('EnglishTextSearch.search', () {
    final pool = [
      g('a', '크다', 'big'),
      g('b', '거대하다', 'to be huge or big'),
      g('c', '넓다', 'wide'),
      g('d', '큰', 'big', pos: 'nouns'),
      g('e', '대단하다', 'great', notes: 'very big'),
    ];

    test('ranks by score, then label', () {
      final hits = EnglishTextSearch.search('big', pool);
      expect(hits.map((h) => h.group.id), ['a', 'd', 'b', 'e']);
    });

    test('can filter by POS and exclude an id', () {
      expect(
        EnglishTextSearch.search(
          'big',
          pool,
          pos: 'Adjectives',
          excludeId: 'a',
        ).map((h) => h.group.id),
        ['b', 'e'],
      );
    });

    test('respects the limit', () {
      expect(EnglishTextSearch.search('big', pool, limit: 2), hasLength(2));
    });
  });
}
