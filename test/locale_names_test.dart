import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/services/locale_names.dart';

void main() {
  group('LocaleNames.of', () {
    test('names the language and region', () {
      expect(LocaleNames.of('zh-TW'), 'Chinese (Taiwan)');
      expect(LocaleNames.of('ko-KR'), 'Korean (South Korea)');
      expect(LocaleNames.of('yue-HK'), 'Cantonese (Hong Kong)');
    });

    test('a language alone has no brackets', () {
      expect(LocaleNames.of('ko'), 'Korean');
      expect(LocaleNames.of('ar'), 'Arabic');
    });

    test('names a script, whatever the case of the tag', () {
      expect(LocaleNames.of('zh_hant_tw'), 'Chinese (Traditional, Taiwan)');
    });

    test('shows an unknown code as it is', () {
      expect(LocaleNames.of('xx-QQ'), 'xx (QQ)');
    });
  });
}
