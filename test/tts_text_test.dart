import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/services/tts_text.dart';

void main() {
  group('TtsText.parse', () {
    test('splits a locale prefix off the text', () {
      final tts = TtsText.parse('zh-TW:垃圾');
      expect(tts.locale, 'zh-TW');
      expect(tts.text, '垃圾');
    });

    test('takes a language alone, or with script and region', () {
      expect(TtsText.parse('ko:세 개').locale, 'ko');
      expect(TtsText.parse('ko:세 개').text, '세 개');
      expect(TtsText.parse('zh-Hant-TW:垃圾').locale, 'zh-Hant-TW');
      expect(TtsText.parse('es-419:hola').locale, 'es-419');
    });

    test('normalizes the case and separator of the locale', () {
      expect(TtsText.parse('zh-tw:垃圾').locale, 'zh-TW');
      expect(TtsText.parse('ZH_hant:垃圾').locale, 'zh-Hant');
    });

    test('text without a prefix is all text', () {
      final tts = TtsText.parse('세 개');
      expect(tts.locale, isNull);
      expect(tts.text, '세 개');
    });

    test('a colon followed by a space is text', () {
      for (final text in ['en: hello', 'Note: this', 'fr : oui']) {
        final tts = TtsText.parse(text);
        expect(tts.locale, isNull, reason: text);
        expect(tts.text, text);
      }
    });

    test('a prefix that does not look like a locale is text', () {
      for (final text in ['10:30', 'Note:this', 'a:b', 'zh-TWN:垃圾', ':垃圾']) {
        final tts = TtsText.parse(text);
        expect(tts.locale, isNull, reason: text);
        expect(tts.text, text);
      }
    });

    test('a prefix with nothing after it is text', () {
      final tts = TtsText.parse('zh-TW:');
      expect(tts.locale, isNull);
      expect(tts.text, 'zh-TW:');
    });

    test('only the first prefix is split off', () {
      final tts = TtsText.parse('ko:ja:abc');
      expect(tts.locale, 'ko');
      expect(tts.text, 'ja:abc');
    });
  });
}
