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

    test('a prefix with nothing after it keeps its locale', () {
      final tts = TtsText.parse('zh-TW:');
      expect(tts.locale, 'zh-TW');
      expect(tts.text, isEmpty);
    });

    test('a prefix needs no text in front of it', () {
      final tts = TtsText.parse('垃圾 zh-TW:垃圾');
      expect(tts.locale, isNull);
      expect(tts.text, '垃圾 zh-TW:垃圾');
      expect(TtsText.parse('  zh-TW:垃圾').locale, 'zh-TW');
    });

    test('a prefix of an unknown language is dropped', () {
      final tts = TtsText.parse('xx:垃圾');
      expect(tts.locale, isNull);
      expect(tts.text, '垃圾');
      expect(TtsText.parse('xyz-TW:').text, isEmpty);
    });

    test('only the first prefix is split off', () {
      final tts = TtsText.parse('ko:ja:abc');
      expect(tts.locale, 'ko');
      expect(tts.text, 'ja:abc');
    });
  });

  group('TtsText.speechOf', () {
    test('the TTS text when set, else the word', () {
      expect(TtsText.speechOf('세 개', '셋'), '세 개');
      expect(TtsText.speechOf(null, '셋'), '셋');
      expect(TtsText.speechOf('  ', '셋'), '셋');
    });

    test('a prefix alone says the word in that locale', () {
      expect(TtsText.speechOf('zh-TW:', '垃圾'), 'zh-TW:垃圾');
    });

    test('an unknown prefix is ignored', () {
      expect(TtsText.speechOf('xx:', '垃圾'), '垃圾');
      expect(TtsText.speechOf('xx:樂色', '垃圾'), '樂色');
    });

    test('text that only looks like a prefix is said as written', () {
      expect(TtsText.speechOf('ko: 세 개', '셋'), 'ko: 세 개');
    });
  });

  group('TtsText.clean', () {
    test('blank TTS text is saved as none', () {
      expect(TtsText.clean('   '), isNull);
      expect(TtsText.clean(null), isNull);
    });

    test('a prefix alone, known or not, is saved', () {
      expect(TtsText.clean('zh-TW:'), 'zh-TW:');
      expect(TtsText.clean('xx: '), 'xx:');
    });

    test('trims the text', () {
      expect(TtsText.clean(' zh-TW:垃圾 '), 'zh-TW:垃圾');
      expect(TtsText.clean('세 개'), '세 개');
    });
  });

  group('TtsText.withLocale', () {
    test('adds a prefix', () {
      expect(TtsText.withLocale('垃圾', 'zh-TW'), 'zh-TW:垃圾');
      expect(TtsText.withLocale('', 'zh-TW'), 'zh-TW:');
      expect(TtsText.withLocale(' 垃圾', 'zh-TW'), 'zh-TW:垃圾');
    });

    test('replaces an existing prefix, known or not', () {
      expect(TtsText.withLocale('zh-CN:垃圾', 'zh-TW'), 'zh-TW:垃圾');
      expect(TtsText.withLocale('ko:', 'ja-JP'), 'ja-JP:');
      expect(TtsText.withLocale('xx:垃圾', 'zh-TW'), 'zh-TW:垃圾');
    });

    test('removes the prefix for the default language', () {
      expect(TtsText.withLocale('zh-TW:垃圾', null), '垃圾');
    });

    test('a colon that is text is kept', () {
      expect(TtsText.withLocale('ko: 세 개', 'ko'), 'ko:ko: 세 개');
    });
  });
}
