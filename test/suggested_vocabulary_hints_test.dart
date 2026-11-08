import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/services/suggested_vocabulary_hints.dart';

/// The hints for suggested [words] against [known] ones, as `summary`
/// writes them.
String _hints(
  List<String> words,
  List<String> known, {
  String language = 'ko',
}) => SuggestedVocabularyHints.summary(
  SuggestedVocabularyHints.forEntries(
    language: language,
    entries: [for (final word in words) (word: word, section: '')],
    known: known,
  ),
);

void main() {
  group('related Korean forms', () {
    test('a noun and its 하다, 되다 and 시키다 verbs', () {
      expect(_hints(['공부'], ['공부하다']), '공부 (you have 공부하다)');
      expect(_hints(['공부하다'], ['공부']), '공부하다 (you have 공부)');
      expect(_hints(['공부되다'], ['공부하다']), '공부되다 (you have 공부하다)');
      expect(_hints(['공부시키다'], ['공부']), '공부시키다 (you have 공부)');
    });

    test('스럽다, 롭다, 답다, 있다 and 없다', () {
      expect(_hints(['자연스럽다'], ['자연']), '자연스럽다 (you have 자연)');
      expect(_hints(['자유'], ['자유롭다']), '자유 (you have 자유롭다)');
      expect(_hints(['정답다'], ['정']), '정답다 (you have 정)');
      expect(_hints(['맛'], ['맛있다']), '맛 (you have 맛있다)');
      expect(_hints(['맛없다'], ['맛있다']), '맛없다 (you have 맛있다)');
    });

    test('적 and 히 after a root of 2 syllables or more', () {
      expect(_hints(['경제적'], ['경제']), '경제적 (you have 경제)');
      expect(_hints(['조용히'], ['조용하다']), '조용히 (you have 조용하다)');
      // 목적 is not a form of 목.
      expect(_hints(['목적'], ['목']), isEmpty);
    });

    test('이 only against 하다', () {
      expect(_hints(['깨끗이'], ['깨끗하다']), '깨끗이 (you have 깨끗하다)');
      expect(_hints(['오이'], ['오']), isEmpty);
      expect(_hints(['나이'], ['나다']), isEmpty);
    });

    test('endings too often part of unrelated words are not used', () {
      expect(_hints(['감기'], ['감다']), isEmpty);
      expect(_hints(['가게'], ['가다']), isEmpty);
    });

    test('a bare suffix has no root', () {
      expect(_hints(['하다'], ['되다']), isEmpty);
      expect(_hints(['있다'], ['없다']), isEmpty);
    });

    test('other languages get none', () {
      expect(_hints(['공부'], ['공부하다'], language: 'ja'), isEmpty);
      expect(_hints(['공부'], ['공부하다'], language: 'ko-KR'), isNotEmpty);
    });
  });

  group('only the words are compared', () {
    test('spaces are ignored', () {
      expect(_hints(['공부 하다'], ['공부']), '공부 하다 (you have 공부)');
    });

    test('spelling variants are not taken for the same word', () {
      // Could be homonyms told apart by the note, or by punctuation.
      expect(_hints(['공부(工夫)'], ['공부하다']), isEmpty);
      expect(_hints(['배(ship)'], ['배']), isEmpty);
      expect(_hints(['~하고'], ['하고']), isEmpty);
    });
  });

  group('the list itself', () {
    test('a later word is compared with earlier ones', () {
      expect(
        _hints(['공부', '공부하다', '조용하다', '조용히'], []),
        '공부하다 (also listed: 공부), 조용히 (also listed: 조용하다)',
      );
    });

    test('a word the learner has comes before one in the list', () {
      expect(
        _hints(['공부', '공부하다'], ['공부되다']),
        '공부 (you have 공부되다), 공부하다 (you have 공부되다)',
      );
    });

    test('nothing close, nothing said', () {
      expect(_hints(['배', '포도'], ['사과', '배우다']), isEmpty);
    });
  });
}
