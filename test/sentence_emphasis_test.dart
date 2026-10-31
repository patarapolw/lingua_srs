import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/lesson.dart';
import 'package:lingua_srs/models/sentence.dart';
import 'package:lingua_srs/models/vocab_item.dart';
import 'package:lingua_srs/providers/app_provider.dart';
import 'package:lingua_srs/services/yaml_parser_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _sharedSentenceYaml = '''
---
vocabulary:
  nouns:
    - ko: 배
      en: pear
      examples:
        - ko: "**배**와 사과를 먹어요"
          en: "I eat a **pear** and an apple"
    - ko: 사과
      en: apple
      examples:
        - ko: "배와 **사과**를 먹어요"
          en: "I eat a pear and an **apple**"
---
# Fruit
''';

/// Keeps a Windows run from importing the developer's real LinguaSRS data.
const _freshStore = <String, Object>{
  'lingua_srs_windows_legacy_migration_complete': true,
};

Future<AppProvider> _loadedProvider() async {
  final provider = AppProvider();
  while (provider.isLoading) {
    await Future<void>.delayed(Duration.zero);
  }
  return provider;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final storageDirectory = Directory.systemTemp.createTempSync(
    'lingua_srs_emphasis_test_',
  );
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(pathProviderChannel, (call) async {
        if (call.method == 'getApplicationSupportDirectory') {
          return storageDirectory.path;
        }
        throw MissingPluginException('Unexpected method: ${call.method}');
      });
  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    await storageDirectory.delete(recursive: true);
  });

  group('Sentence emphasis helpers', () {
    test('stripEmphasis removes only ** markers', () {
      expect(Sentence.stripEmphasis('저는 **배**를 **먹어요**'), '저는 배를 먹어요');
      expect(Sentence.stripEmphasis('a__b__c'), 'a__b__c');
      expect(Sentence.stripEmphasis('no markers'), 'no markers');
    });

    test('hasEmphasis needs a complete segment', () {
      expect(Sentence.hasEmphasis('저는 **배**를'), isTrue);
      expect(Sentence.hasEmphasis('저는 **배를'), isFalse);
      expect(Sentence.hasEmphasis('저는 배를'), isFalse);
      expect(Sentence.hasEmphasis('저는 ****를'), isFalse);
    });

    test('emphasisRanges and markEmphasis are inverses', () {
      final ranges = Sentence.emphasisRanges('**ab**cd**e**');
      expect(ranges.map((r) => (r.start, r.end)), [(0, 2), (4, 5)]);
      expect(Sentence.markEmphasis('abcde', ranges), '**ab**cd**e**');
    });

    test('carryEmphasis keeps what an edit did not touch', () {
      const marked = '저는 **배**를 먹어요';
      expect(Sentence.carryEmphasis(marked, '저는 배를 먹어요'), marked);
      expect(Sentence.carryEmphasis(marked, '저는 배를 먹었어요'), '저는 **배**를 먹었어요');
      expect(
        Sentence.carryEmphasis(marked, '오늘 저는 배를 먹어요'),
        '오늘 저는 **배**를 먹어요',
      );
    });

    test('carryEmphasis drops a segment the edit touched', () {
      expect(Sentence.carryEmphasis('저는 **배**를 먹어요', '저는 사과를 먹어요'), isNull);
      expect(
        Sentence.carryEmphasis('**배**와 **사과**를 먹어요', '귤과 사과를 먹어요'),
        '귤과 **사과**를 먹어요',
      );
      expect(Sentence.carryEmphasis('a**bc**d', ''), isNull);
    });

    test('text typed next to a segment is not emphasized', () {
      expect(Sentence.carryEmphasis('a**bc**d', 'abcXd'), 'a**bc**Xd');
      expect(Sentence.carryEmphasis('a**bc**d', 'aXbcd'), 'aX**bc**d');
    });

    test('clozeOf blanks every ** segment', () {
      expect(Sentence.clozeOf('**배**와 **사과**를'), '(___)와 (___)를');
    });
  });

  group('VocabItem emphasis', () {
    final sentence = Sentence(
      id: 's1',
      targetText: '배와 사과를 먹어요',
      translationText: 'I eat a pear and an apple',
    );
    final pear = VocabItem(
      targetWord: '배',
      translation: 'pear',
      pos: 'nouns',
      sentenceIds: ['s1'],
      sentenceEmphasis: {
        's1': const SentenceEmphasis(
          target: '**배**와 사과를 먹어요',
          translation: 'I eat a **pear** and an apple',
        ),
      },
    );
    final apple = VocabItem(
      targetWord: '사과',
      translation: 'apple',
      pos: 'nouns',
      sentenceIds: ['s1'],
      sentenceEmphasis: {
        's1': const SentenceEmphasis(
          target: '배와 **사과**를 먹어요',
          translation: 'I eat a pear and an **apple**',
        ),
      },
    );

    test('two words mark different parts of one sentence', () {
      expect(pear.targetTextFor(sentence), '**배**와 사과를 먹어요');
      expect(apple.targetTextFor(sentence), '배와 **사과**를 먹어요');
      expect(pear.clozeFor(sentence), '(___)와 사과를 먹어요');
      expect(apple.clozeFor(sentence), '배와 (___)를 먹어요');
      expect(
        apple.translationTextFor(sentence),
        'I eat a pear and an **apple**',
      );
    });

    test('a word without marking shows the plain sentence', () {
      final other = VocabItem(
        targetWord: '먹다',
        translation: 'eat',
        pos: 'verbs',
      );
      expect(other.targetTextFor(sentence), '배와 사과를 먹어요');
      expect(other.clozeFor(sentence), '배와 사과를 (___)');
    });

    test('emphasis is carried when the sentence text changes', () {
      final edited = Sentence(
        id: 's1',
        targetText: '배와 사과를 먹었어요',
        translationText: 'I eat a pear and an apple',
      );
      expect(pear.targetTextFor(edited), '**배**와 사과를 먹었어요');
    });

    test('emphasis survives JSON, and old data has none', () {
      final back = VocabItem.fromJson(pear.toJson());
      expect(back.sentenceEmphasis['s1'], pear.sentenceEmphasis['s1']);
      final old = VocabItem.fromJson({'targetWord': 'x', 'translation': 'y'});
      expect(old.sentenceEmphasis, isEmpty);
    });
  });

  group('Importing examples', () {
    test('an example without ** fails and names the sentence', () {
      const yaml = '''
---
vocabulary:
  nouns:
    - ko: 배
      en: pear
      examples:
        - ko: "저는 배를 먹어요"
          en: "I eat a pear"
---
# L
''';
      expect(
        () => YamlParserService.parseLessonYaml(yaml),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf(contains('저는 배를 먹어요'), contains('**')),
          ),
        ),
      );
    });

    test('plain YAML without ** fails the same way', () {
      const yaml = '''
vocabulary:
  nouns:
    - ko: 배
      en: pear
      examples:
        - ko: "저는 배를 먹어요"
          en: "I eat a pear"
''';
      expect(
        () => YamlParserService.parseLessonYaml(yaml),
        throwsFormatException,
      );
    });

    test('an unclosed ** is not emphasis', () {
      const yaml = '''
vocabulary:
  nouns:
    - ko: 배
      en: pear
      examples:
        - ko: "저는 **배를 먹어요"
          en: "I eat a pear"
''';
      expect(
        () => YamlParserService.parseLessonYaml(yaml),
        throwsFormatException,
      );
    });

    test('the parsed sentence is plain and the word keeps its marking', () {
      final parsed = YamlParserService.parseLessonYaml(_sharedSentenceYaml);
      final pear = parsed.lesson.vocabularies.first;
      final sentence = parsed.sentences.first;
      expect(sentence.targetText, '배와 사과를 먹어요');
      expect(sentence.translationText, 'I eat a pear and an apple');
      expect(pear.sentenceEmphasis[sentence.id]?.target, '**배**와 사과를 먹어요');
    });

    test('a translation without ** is allowed', () {
      const yaml = '''
vocabulary:
  nouns:
    - ko: 배
      en: pear
      examples:
        - ko: "저는 **배**를 먹어요"
          en: "I eat a pear"
''';
      final parsed = YamlParserService.parseLessonYaml(yaml);
      expect(parsed.sentences.single.translationText, 'I eat a pear');
    });
  });

  group('Sentence pool and words', () {
    late AppProvider provider;

    setUp(() async {
      SharedPreferences.setMockInitialValues(_freshStore);
      provider = await _loadedProvider();
    });
    tearDown(() => provider.dispose());

    Future<(VocabItem, VocabItem, Sentence)> importShared() async {
      final lesson = await provider.importYaml(_sharedSentenceYaml);
      final pear = lesson.vocabularies.firstWhere((v) => v.targetWord == '배');
      final apple = lesson.vocabularies.firstWhere((v) => v.targetWord == '사과');
      return (pear, apple, provider.sentences.single);
    }

    test(
      'words importing one sentence share it and keep their own **',
      () async {
        final (pear, apple, sentence) = await importShared();

        expect(sentence.targetText, '배와 사과를 먹어요');
        expect(pear.sentenceIds, [sentence.id]);
        expect(apple.sentenceIds, [sentence.id]);
        expect(pear.targetTextFor(sentence), '**배**와 사과를 먹어요');
        expect(apple.targetTextFor(sentence), '배와 **사과**를 먹어요');
        expect(pear.sentenceEmphasis.keys, [sentence.id]);
        expect(apple.sentenceEmphasis.keys, [sentence.id]);
      },
    );

    test(
      'editing the text keeps each word\'s emphasis where it fits',
      () async {
        final (pear, apple, sentence) = await importShared();

        sentence.targetText = '배와 사과를 먹었어요';
        await provider.updateSentenceInPool(sentence);

        expect(pear.sentenceEmphasis[sentence.id]?.target, '**배**와 사과를 먹었어요');
        expect(apple.sentenceEmphasis[sentence.id]?.target, '배와 **사과**를 먹었어요');
      },
    );

    test('an edit through a word\'s emphasis is suggested again', () async {
      final (pear, apple, sentence) = await importShared();

      sentence.targetText = '배와 귤을 먹어요';
      await provider.updateSentenceInPool(sentence);

      expect(pear.sentenceEmphasis[sentence.id]?.target, '**배**와 귤을 먹어요');
      // 사과 is gone from the text: nothing to emphasize for that word.
      expect(
        Sentence.hasEmphasis(apple.sentenceEmphasis[sentence.id]!.target),
        isFalse,
      );
    });

    test('adding a sentence with ** keeps the pool plain', () async {
      final added = await provider.addSentenceToPool(
        Sentence(
          targetText: '저는 **배**를 먹어요',
          translationText: 'I eat a **pear**',
        ),
      );
      expect(added.targetText, '저는 배를 먹어요');
      expect(added.translationText, 'I eat a pear');
    });

    test('re-importing a lesson updates a word\'s emphasis', () async {
      final (pear, _, sentence) = await importShared();
      expect(pear.targetTextFor(sentence), '**배**와 사과를 먹어요');

      await provider.importYaml(
        _sharedSentenceYaml.replaceFirst(
          '"**배**와 사과를 먹어요"',
          '"**배**와 사과를 **먹어요**"',
        ),
      );
      final again = provider.lessons.single.vocabularies.firstWhere(
        (v) => v.targetWord == '배',
      );
      expect(provider.sentences, hasLength(1));
      expect(
        again.targetTextFor(provider.sentences.single),
        '**배**와 사과를 **먹어요**',
      );
    });

    test('importing an example without ** fails and imports nothing', () async {
      await expectLater(
        provider.importYaml(
          '---\nvocabulary:\n  nouns:\n    - ko: 배\n      en: pear\n'
          '      examples:\n        - ko: "배를 먹어요"\n          en: "x"\n'
          '---\n# L\n',
        ),
        throwsFormatException,
      );
      expect(provider.lessons, isEmpty);
      expect(provider.sentences, isEmpty);
    });
  });

  group('Saved data from before per-word emphasis', () {
    test('each word takes its marking and the pool turns plain', () async {
      final shared = Sentence(
        id: 'shared',
        targetText: '**배**와 사과를 먹어요',
        translationText: 'I eat a **pear** and an apple',
      );
      final lesson = Lesson(
        id: 'lesson',
        title: 'Fruit',
        vocabularies: [
          VocabItem(
            targetWord: '배',
            translation: 'pear',
            pos: 'nouns',
            sentenceIds: ['shared'],
          ),
          VocabItem(
            targetWord: '사과',
            translation: 'apple',
            pos: 'nouns',
            sentenceIds: ['shared'],
          ),
        ],
      );
      SharedPreferences.setMockInitialValues({
        ..._freshStore,
        'lingua_srs_lessons': jsonEncode([lesson.toJson()]),
        'lingua_srs_sentences': jsonEncode([shared.toJson()]),
      });

      final provider = await _loadedProvider();
      addTearDown(provider.dispose);

      final sentence = provider.sentences.single;
      expect(sentence.targetText, '배와 사과를 먹어요');
      expect(sentence.translationText, 'I eat a pear and an apple');
      final words = provider.lessons.single.vocabularies;
      for (final word in words) {
        expect(
          word.sentenceEmphasis['shared']?.target,
          '**배**와 사과를 먹어요',
          reason: 'both start from the marking the sentence had',
        );
      }

      // Saved once: loading again changes nothing.
      final again = await _loadedProvider();
      addTearDown(again.dispose);
      expect(again.sentences.single.targetText, '배와 사과를 먹어요');
      expect(
        again.lessons.single.vocabularies.first.sentenceEmphasis['shared'],
        isNotNull,
      );
    });

    Future<AppProvider> loadWith(
      List<Sentence> sentences,
      List<VocabItem> vocabularies,
    ) async {
      SharedPreferences.setMockInitialValues({
        ..._freshStore,
        'lingua_srs_lessons': jsonEncode([
          Lesson(id: 'lesson', title: 'L', vocabularies: vocabularies).toJson(),
        ]),
        'lingua_srs_sentences': jsonEncode([
          for (final sentence in sentences) sentence.toJson(),
        ]),
      });
      final provider = await _loadedProvider();
      addTearDown(provider.dispose);
      return provider;
    }

    test('three copies of a sentence keep every word linked', () async {
      // The pool keeps the first copy, then swaps it for the third, which has a
      // recording: the second copy has to follow to the third, not the first.
      final provider = await loadWith(
        [
          Sentence(id: 'a', targetText: '사과를 먹어요', translationText: 'x'),
          Sentence(id: 'b', targetText: '사과를 먹어요', translationText: 'x'),
          Sentence(
            id: 'c',
            targetText: '사과를 먹어요',
            translationText: 'x',
            audioUrl: 'https://example.com/c.mp3',
          ),
        ],
        [
          VocabItem(
            targetWord: '사과',
            translation: 'apple',
            pos: 'nouns',
            sentenceIds: ['a'],
          ),
          VocabItem(
            targetWord: '먹다',
            translation: 'eat',
            pos: 'verbs',
            sentenceIds: ['b'],
          ),
        ],
      );

      expect(provider.sentences.map((s) => s.id), ['c']);
      for (final word in provider.lessons.single.vocabularies) {
        expect(word.sentenceIds, ['c'], reason: word.targetWord);
      }
    });

    test('an id a word lists twice is kept once', () async {
      final provider = await loadWith(
        [Sentence(id: 'a', targetText: '사과를 먹어요', translationText: 'x')],
        [
          VocabItem(
            targetWord: '사과',
            translation: 'apple',
            pos: 'nouns',
            sentenceIds: ['a', 'a'],
          ),
        ],
      );

      expect(provider.lessons.single.vocabularies.single.sentenceIds, ['a']);
    });
  });
}
