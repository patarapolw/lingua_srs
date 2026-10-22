import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/services/korean_text_search.dart';

void main() {
  group('KoreanTextSearch.areVariants', () {
    bool v(String a, String b) => KoreanTextSearch.areVariants(a, b);

    test('identical forms', () {
      expect(v('아름답다', '아름답다'), isTrue);
      expect(v('  아름답다 ', '아름답다'), isTrue);
    });

    test('dictionary form and conjugated forms', () {
      expect(v('아름답다', '아름답고'), isTrue);
      expect(v('먹다', '먹었습니다'), isTrue);
      expect(v('공부하다', '공부해요'), isTrue);
      expect(v('크다', '크고'), isTrue);
      expect(v('가다', '가고'), isTrue);
    });

    test('is symmetric', () {
      expect(v('먹었습니다', '먹다'), isTrue);
      expect(v('아름답고', '아름답다'), isTrue);
    });

    test('nouns with particles', () {
      expect(v('사과', '사과를'), isTrue);
      expect(v('학교', '학교에'), isTrue);
    });

    test('ㅂ-irregular attributive forms (needs the optional gap fix)', () {
      expect(v('아름답다', '아름다운'), isTrue);
      expect(v('춥다', '추운'), isTrue);
    });

    test('different words are not variants', () {
      expect(v('크다', '작다'), isFalse);
      expect(v('배', '배우다'), isFalse);
      expect(v('가다', '가방'), isFalse);
      expect(v('아이', '아'), isFalse);
    });

    test('phrases need the same number of words', () {
      expect(v('잘 지내다', '잘 지내고'), isTrue);
      expect(v('잘 지내다', '지내다'), isFalse);
    });

    test('empty input is never a variant', () {
      expect(v('', ''), isFalse);
      expect(v('', '크다'), isFalse);
    });
  });
}
