import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/services/suggested_vocabulary_hints.dart';
import 'package:lingua_srs/services/yaml_parser_service.dart';

Set<String> _known(Iterable<String> words) => {
  for (final word in words) YamlParserService.vocabularyKey(word),
};

List<SuggestedVocabularyHint> _hints(
  List<({String word, String section})> entries,
  Iterable<String> known, {
  String language = 'ko',
}) => SuggestedVocabularyHints.forEntries(
  language: language,
  entries: entries,
  known: _known(known),
);

void main() {
  group('SuggestedVocabularyHints', () {
    test('a noun whose 하다 verb is known is pointed out', () {
      expect(
        _hints(
          [
            (word: '공부', section: 'nouns'),
            (word: '사과', section: 'nouns'),
            (word: '운동', section: 'food'),
          ],
          ['공부하다', '운동하다', '먹다'],
        ),
        [(word: '공부', known: '공부하다'), (word: '운동', known: '운동하다')],
      );
    });

    test('nothing when the 하다 verb is not known', () {
      expect(_hints([(word: '공부', section: 'nouns')], ['공부']), isEmpty);
    });

    test('verbs, adjectives and words ending in 다 are not nouns', () {
      expect(
        _hints(
          [
            (word: '공부', section: 'verbs'),
            (word: '조용', section: 'adjectives'),
            (word: '바다', section: 'nouns'),
          ],
          ['공부하다', '조용하다', '바다하다'],
        ),
        isEmpty,
      );
    });

    test('each word once, matched ignoring spacing', () {
      expect(
        _hints(
          [(word: ' 공부 ', section: 'nouns'), (word: '공부', section: 'nouns')],
          ['공부하다'],
        ),
        [(word: '공부', known: '공부하다')],
      );
    });

    test('other languages get no hints', () {
      expect(
        _hints([(word: '공부', section: 'nouns')], ['공부하다'], language: 'ja'),
        isEmpty,
      );
      expect(
        _hints([(word: '공부', section: 'nouns')], ['공부하다'], language: 'ko-KR'),
        hasLength(1),
      );
    });
  });
}
