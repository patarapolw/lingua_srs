import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/vocab_item.dart';
import 'package:lingua_srs/models/vocab_merge_record.dart';
import 'package:lingua_srs/services/vocab_picker_search.dart';

VocabGroup vg(String id, String ko, String en, {String pos = 'adjectives'}) =>
    VocabGroup(
      id: id,
      entry: VocabItem(id: id, targetWord: ko, translation: en, pos: pos),
      reviews: 0,
    )..lessonTitles.add('L');

void main() {
  final current = vg('cur', '아름답다', 'beautiful');
  final pool = [
    current,
    vg('same', '아름답다', 'to be beautiful'), // same Korean and same meaning
    vg('variant', '아름답고', 'pretty'), // variant Korean only
    vg('meaning', '예쁘다', 'beautiful'), // same meaning, other Korean
    vg('related', '귀엽다', 'cute and beautiful'), // shares a whole word
    vg('other', '크다', 'big'),
  ];

  group('VocabPickerSearch.suggest', () {
    test('ranks same Korean, variants, same meaning, related meaning', () {
      final hits = VocabPickerSearch.suggest(current, pool);
      expect(hits.map((h) => h.group.id), [
        'same',
        'variant',
        'meaning',
        'related',
      ]);
    });

    test('explains each suggestion', () {
      final byId = {
        for (final h in VocabPickerSearch.suggest(current, pool)) h.group.id: h,
      };
      expect(byId['same']!.matches, {
        PickerMatch.sameKorean,
        PickerMatch.sameMeaning,
      });
      expect(byId['variant']!.matches, {PickerMatch.similarKorean});
      expect(byId['meaning']!.matches, {PickerMatch.sameMeaning});
      expect(byId['related']!.matches, {PickerMatch.similarMeaning});
    });

    test('never suggests itself or unrelated words', () {
      final ids = VocabPickerSearch.suggest(
        current,
        pool,
      ).map((h) => h.group.id);
      expect(ids, isNot(contains('cur')));
      expect(ids, isNot(contains('other')));
    });

    test('respects the limit', () {
      expect(VocabPickerSearch.suggest(current, pool, limit: 2), hasLength(2));
    });

    test('a prefix-level English match alone is not a suggestion', () {
      final cur = vg('a', '크다', 'huge');
      final hits = VocabPickerSearch.suggest(cur, [
        cur,
        vg('b', '거대하다', 'hug'),
      ]);
      expect(hits, isEmpty);
    });
  });

  group('VocabPickerSearch.search', () {
    List<String> ids(String q) => VocabPickerSearch.search(
      q,
      current,
      pool,
    ).map((h) => h.group.id).toList();

    test('an empty query returns nothing', () => expect(ids('  '), isEmpty));

    test('exact Korean form first', () {
      expect(ids('예쁘다').first, 'meaning');
    });

    test('typing the start of a Korean word finds same and variant forms', () {
      expect(ids('아름'), ['same', 'variant']);
    });

    test(
      'a conjugated Korean query finds the dictionary form and variants',
      () {
        final found = ids('아름답습니다');
        expect(found, containsAll(['same', 'variant']));
        expect(found, isNot(contains('meaning')));
      },
    );

    test('English query searches meanings', () {
      expect(ids('pretty'), ['variant']);
      expect(ids('beautiful'), containsAll(['same', 'meaning', 'related']));
    });

    test('mixed Korean and English queries use both', () {
      expect(ids('예쁘다 beautiful'), contains('meaning'));
    });

    test('the old substring match on the label still works', () {
      expect(ids('ful'), containsAll(['same', 'meaning', 'related']));
    });

    test('never returns the current vocabulary', () {
      expect(ids('아름답다'), isNot(contains('cur')));
    });

    test('respects the limit', () {
      expect(
        VocabPickerSearch.search('beautiful', current, pool, limit: 1),
        hasLength(1),
      );
    });
  });
}
