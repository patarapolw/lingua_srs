import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/services/korean_pronunciation_service.dart';

void main() {
  const tense = '\u0348';
  const tie = '\u0361';
  const unreleased = '\u031A';
  final rr = KoreanPronunciationService.romanize;
  final ipa = KoreanPronunciationService.toIpa;

  group('romanize', () {
    const cases = {
      '한국어': 'hangugeo', // liaison
      '학교': 'hakgyo', // rule tensification is not written
      '좋아요': 'joayo', // silent ㅎ
      '국물': 'gungmul', // nasalisation
      '없어요': 'eopseoyo', // double final splits
      '같이': 'gachi', // palatalisation
      '읽다': 'ikda',
      '읽고': 'ilgo',
      '감사합니다': 'gamsahamnida',
      '입니다': 'imnida',
      '신라': 'silla',
      '설날': 'seollal',
      '종로': 'jongno',
      '강아지': 'gangaji', // ng does not move
      '있어': 'isseo', // spelled ㅆ is kept
      '값이': 'gapsi',
      '놓고': 'noko',
      '많지': 'manchi',
      '축하': 'chuka',
      '앉히다': 'anchida',
      '닫히다': 'dachida',
      '밖': 'bak',
      '꽃': 'kkot',
      '여덟': 'yeodeol',
      '라면': 'ramyeon',
      '우리': 'uri',
      '의사': 'uisa',
    };
    cases.forEach((hangul, expected) {
      test('$hangul -> $expected', () => expect(rr(hangul), expected));
    });

    test('keeps non-Hangul text and punctuation', () {
      expect(rr('저는 학생이에요. Hello 123'), 'jeoneun haksaengieyo. Hello 123');
    });

    test('strips markdown emphasis first', () {
      expect(rr('**학생**이에요'), 'haksaengieyo');
    });

    test('does not apply sound changes across spaces', () {
      expect(rr('집 에서'), 'jip eseo');
    });

    test('empty string', () => expect(rr(''), ''));
  });

  group('toIpa', () {
    final cases = {
      '한국어': 'han.ɡu.ɡʌ',
      '학교': 'hak$unreleased.k${tense}jo',
      '같이': 'ka.t$tieɕʰi',
      '좋아요': 't$tieɕo.a.jo',
      '국물': 'kuŋ.mul',
      '감사합니다': 'kam.sa.ham.ni.da',
      '읽다': 'ik$unreleased.t${tense}a',
      '한글': 'han.ɡɯl',
      '바다': 'pa.da',
      '시장': 'ɕi.d$tieʑaŋ',
      '신라': 'ɕil.la',
      '사랑': 'sa.ɾaŋ',
    };
    cases.forEach((hangul, expected) {
      test('$hangul -> $expected', () => expect(ipa(hangul), expected));
    });
  });

  test('bracketed text is still pronounced, unlike in speech', () {
    // Brackets are skipped when speaking, but the pronunciation line shows
    // everything the sentence shows.
    expect(rr('학교(한국어)'), 'hakgyo(hangugeo)');
  });

  test('containsHangul', () {
    expect(KoreanPronunciationService.containsHangul('abc 123'), isFalse);
    expect(KoreanPronunciationService.containsHangul('a배'), isTrue);
  });
}
