import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/services/yaml_parser_service.dart';

const _yaml = '''vocabulary:
  nouns:
    - ko: "배"
      en: "pear"
      examples:
        - ko: "**배**가 달아요."
          en: "The pear is sweet."
    - ko: "사과"
      en: "apple"
    - ko: "포도"
      en: "grape"
  verbs:
    - ko: "먹다"
      en: "to eat"
  adjectives:
    - ko: "달다"
      en: "sweet"
''';

/// [known] words are `word`, `word = meaning` or `word = meaning = reading`;
/// a word without a meaning duplicates any written the same.
VocabularyYamlFilter _filter(String yaml, Iterable<String> known) =>
    YamlParserService.withoutKnownVocabulary(yaml, [
      for (final word in known)
        (
          word: word.split('=').first.trim(),
          meaning: word.split('=').skip(1).firstOrNull?.trim() ?? '',
          reading: word.split('=').skip(2).firstOrNull?.trim() ?? '',
        ),
    ]);

List<String> _words(String yaml) =>
    YamlParserService.parseLessonYaml(yaml).lesson.vocabularies
        .map((v) => v.targetWord)
        .toList();

void main() {
  group('withoutKnownVocabulary', () {
    test('keeps everything when no word is known', () {
      final result = _filter(_yaml, const []);

      expect(result.yaml, _yaml);
      expect(result.kept, ['배', '사과', '포도', '먹다', '달다']);
      expect(result.removed, isEmpty);
    });

    test('leaves out known words, with their examples and notes', () {
      final result = _filter(_yaml, ['배', '포도']);

      expect(result.removed, ['배', '포도']);
      expect(result.kept, ['사과', '먹다', '달다']);
      expect(result.keptEntries, [
        (word: '사과', section: 'nouns'),
        (word: '먹다', section: 'verbs'),
        (word: '달다', section: 'adjectives'),
      ]);
      expect(result.yaml, isNot(contains('pear')));
      expect(result.yaml, isNot(contains('grape')));
      expect(result.yaml, contains('  nouns:\n    - ko: "사과"\n'));
      expect(_words(result.yaml), ['사과', '먹다', '달다']);
    });

    test('a part of speech with no words left goes too', () {
      final result = _filter(_yaml, ['먹다', '달다']);

      expect(result.yaml, isNot(contains('verbs:')));
      expect(result.yaml, isNot(contains('adjectives:')));
      expect(result.yaml, endsWith('en: "grape"\n'));
      expect(_words(result.yaml), ['배', '사과', '포도']);
    });

    test('a word listed twice is kept once', () {
      const yaml = '''vocabulary:
  nouns:
    - ko: "배"
      en: "pear"
  adjectives:
    - ko: "배 "
      en: "a pear"
''';
      final result = _filter(yaml, const []);

      expect(result.kept, ['배']);
      expect(result.removed, ['배']);
      expect(_words(result.yaml), ['배']);
      expect(result.yaml, isNot(contains('adjectives:')));
    });

    test('ignores case and spacing when matching', () {
      const yaml =
          'vocabulary:\n  nouns:\n    - ko: "Hello  World"\n'
          '      en: "x"\n    - ko: "배"\n      en: "pear"\n';
      final result = _filter(yaml, ['hello world']);

      expect(result.removed, ['Hello  World']);
      expect(_words(result.yaml), ['배']);
    });

    test('every word known leaves no entries', () {
      final result = _filter(_yaml, ['배', '사과', '포도', '먹다', '달다']);

      expect(result.kept, isEmpty);
      expect(result.removed, hasLength(5));
      expect(result.yaml.trim(), 'vocabulary:');
    });

    test('the last entry without a final newline goes too', () {
      const yaml =
          'vocabulary:\n  nouns:\n    - ko: 배\n      en: pear\n'
          '    - ko: 차\n      en: tea';
      final result = _filter(yaml, ['차']);

      expect(
        result.yaml,
        'vocabulary:\n  nouns:\n    - ko: 배\n      en: pear\n',
      );
    });

    test('flow-style lists and unreadable YAML are left as they are', () {
      const flow = 'vocabulary:\n  nouns: [{ko: 배, en: pear}]\n';
      expect(_filter(flow, ['배']).yaml, flow);
      expect(_filter(flow, ['배']).removed, isEmpty);

      const broken = 'vocabulary: [oops';
      expect(_filter(broken, ['배']).yaml, broken);
    });
  });

  group('words written the same', () {
    const pear = 'vocabulary:\n  nouns:\n    - ko: "배"\n      en: "pear"\n';
    const ship = 'vocabulary:\n  nouns:\n    - ko: "배"\n      en: "ship"\n';

    test('with a meaning in common are duplicates', () {
      final result = _filter(pear, ['배 = a pear, Korean pear']);

      expect(result.removed, ['배']);
      expect(result.possibleDuplicates, isEmpty);
    });

    test('with no meaning in common are kept as possible duplicates', () {
      final result = _filter(ship, ['배 = pear']);

      expect(result.kept, ['배']);
      expect(result.removed, isEmpty);
      expect(result.yaml, ship);
      expect(result.possibleDuplicates, [
        (word: '배', meaning: 'ship', otherMeaning: 'pear', inList: false),
      ]);
    });

    test('a missing meaning is taken as the same', () {
      expect(_filter(ship, ['배']).removed, ['배']);
      expect(
        _filter('vocabulary:\n  nouns:\n    - ko: 배\n', ['배 = pear']).removed,
        ['배'],
      );
    });

    test('"to be", "a" and punctuation do not tell meanings apart', () {
      const pretty =
          'vocabulary:\n  adjectives:\n    - ko: 예쁘다\n      en: Pretty!\n';
      expect(_filter(pretty, ['예쁘다 = to be pretty']).removed, ['예쁘다']);
    });

    test('different readings are different words', () {
      const hanja =
          'vocabulary:\n  nouns:\n    - ko: "사기"\n      hanja: "詐欺"\n'
          '      en: "fraud"\n';
      // Another word: kept, and not a possible duplicate either.
      final other = _filter(hanja, ['사기 = morale = 士氣']);
      expect(other.kept, ['사기']);
      expect(other.possibleDuplicates, isEmpty);

      // The same reading, or none to compare, goes by the meaning.
      expect(_filter(hanja, ['사기 = fraud = 詐欺']).removed, ['사기']);
      expect(_filter(hanja, ['사기 = morale']).possibleDuplicates, hasLength(1));
    });

    test('in the same list', () {
      const yaml = '''vocabulary:
  nouns:
    - ko: "배"
      en: "pear"
    - ko: "배"
      en: "ship"
    - ko: "배"
      en: "pear (fruit)"
''';
      final result = _filter(yaml, const []);

      expect(result.kept, ['배', '배']);
      expect(result.removed, ['배']);
      expect(result.possibleDuplicates, [
        (word: '배', meaning: 'ship', otherMeaning: 'pear', inList: true),
      ]);
    });

    test('a word the learner has is named before one in the list', () {
      const yaml = '''vocabulary:
  nouns:
    - ko: "배"
      en: "ship"
    - ko: "배"
      en: "belly"
''';
      final result = _filter(yaml, ['배 = pear']);

      expect(result.possibleDuplicates.map((d) => (d.otherMeaning, d.inList)), [
        ('pear', false),
        ('pear', false),
      ]);
    });
  });
}
