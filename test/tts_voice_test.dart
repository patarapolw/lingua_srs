import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/services/tts_voice.dart';

TtsVoice _voice(String name, String locale) =>
    TtsVoice(name: name, locale: locale, offline: true);

void main() {
  group('TtsVoice locales', () {
    test('reads the language and region of a tag', () {
      expect(TtsVoice.languageOf('zh-TW'), 'zh');
      expect(TtsVoice.regionOf('zh-TW'), 'tw');
      expect(TtsVoice.regionOf('zh_TW'), 'tw');
      expect(TtsVoice.regionOf('zh-Hant-TW'), 'tw');
      expect(TtsVoice.regionOf('zh-Hant'), isNull);
      expect(TtsVoice.regionOf('ko'), isNull);
    });

    test('maps three-letter codes to the two-letter ones', () {
      expect(TtsVoice.languageOf('cmn-TW'), 'zh');
      expect(TtsVoice.languageOf('zho-TWN'), 'zh');
      expect(TtsVoice.regionOf('zho-TWN'), 'tw');
      expect(TtsVoice.languageOf('kor-KOR'), 'ko');
      expect(TtsVoice.regionOf('kor-KOR'), 'kr');
    });

    test('a voice without a region in its locale is placed by its name', () {
      expect(_voice('cmn-tw-x-ctc-local', 'zh').isInRegion('tw'), isTrue);
      expect(_voice('cmn-cn-x-ccc-local', 'zh').isInRegion('tw'), isFalse);
      expect(_voice('cmn-tw-x-ctc-local', 'zh-CN').isInRegion('tw'), isFalse);
    });

    test('reads the plugin voice list, skipping incomplete entries', () {
      final voices = TtsVoice.fromPlugin([
        {'name': 'a', 'locale': 'zh-TW', 'network_required': '0'},
        {'name': 'b', 'locale': 'zh-CN', 'network_required': '1'},
        {'name': 'c'},
        'not a voice',
      ]);
      expect(voices.map((v) => v.name), ['a', 'b']);
      expect(voices.map((v) => v.offline), [true, false]);
      expect(TtsVoice.fromPlugin(null), isEmpty);
    });
  });

  group('TtsVoiceUsed.isSubstitute', () {
    test('false for a voice of the requested region', () {
      final used = TtsVoiceUsed(
        text: 'zh-TW:垃圾',
        requested: 'zh-TW',
        voice: _voice('t', 'zh-TW'),
      );
      expect(used.isSubstitute, isFalse);
    });

    test('true for a voice of another region, or none', () {
      expect(
        TtsVoiceUsed(
          text: 'zh-TW:垃圾',
          requested: 'zh-TW',
          voice: _voice('c', 'zh-CN'),
        ).isSubstitute,
        isTrue,
      );
      expect(
        const TtsVoiceUsed(text: 'zh-TW:垃圾', requested: 'zh-TW').isSubstitute,
        isTrue,
      );
    });

    test('false for any voice of the language when no region is asked', () {
      final used = TtsVoiceUsed(
        text: '세 개',
        requested: 'ko',
        voice: _voice('k', 'ko-KR'),
      );
      expect(used.isSubstitute, isFalse);
    });
  });
}
