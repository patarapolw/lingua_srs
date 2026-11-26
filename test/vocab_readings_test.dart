import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/lesson.dart';
import 'package:lingua_srs/models/sentence.dart';
import 'package:lingua_srs/models/vocab_item.dart';
import 'package:lingua_srs/providers/app_provider.dart';
import 'package:lingua_srs/services/audio_service.dart';
import 'package:lingua_srs/services/lesson_ai_prompt.dart';
import 'package:lingua_srs/services/lesson_export_service.dart';
import 'package:lingua_srs/services/lesson_file_update.dart';
import 'package:lingua_srs/services/markdown_archive_service.dart';
import 'package:lingua_srs/services/tts_voice.dart';
import 'package:lingua_srs/services/yaml_parser_service.dart';
import 'package:lingua_srs/views/study_view.dart';
import 'package:lingua_srs/widgets/vocab_forms.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'secret_storage_mock.dart';

/// A study screen must not touch real audio plugins.
class _FakeAudioService extends ChangeNotifier implements AudioService {
  @override
  TtsVoiceUsed? get lastVoice => null;
  @override
  bool get isPlaying => false;
  @override
  String? get currentlyPlayingKey => null;
  @override
  bool get usesOfflineTts => true;
  @override
  void prefetchAudios(List<String?> urls) {}
  @override
  String getTtsUrl(String text, {String? language}) => '';
  @override
  Future<void> stop() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

const _mandarinYaml = '''
---
target: zh-CN
vocabulary:
  nouns:
    - zh: 学生
      pinyin: xuésheng
      simplified: 学生
      traditional: 學生
      en: student
---
# Lesson
''';

/// 誰 has two readings, and 台灣 two Traditional forms, one of them the
/// word itself.
const _variantsYaml = '''
---
target: zh-TW
vocabulary:
  pronouns:
    - zh: 誰
      pinyin: [shéi, shuí]
      simplified: 谁
      en: who
  nouns:
    - zh: 台灣
      pinyin: Táiwān
      traditional: [臺灣, 台灣]
      en: Taiwan
---
# Lesson
''';

const _koreanYaml = '''
---
vocabulary:
  nouns:
    - ko: 학생
      hanja: 學生
      en: student
    - ko: 나무
      en: tree
---
# Lesson
''';

/// [vocab]'s other forms as text, `Traditional: 臺灣 | 台灣`: a record
/// compares its list of forms by identity, not by what is in it.
List<String> _otherForms(VocabItem vocab) => [
  for (final other in vocab.otherForms)
    '${other.label}: ${other.forms.join(' | ')}',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(setUpSecretStorage);

  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory storageDirectory;

  setUp(() {
    storageDirectory = Directory.systemTemp.createTempSync(
      'lingua_srs_vocab_readings_test_',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (call) async {
          if (call.method == 'getApplicationSupportDirectory') {
            return storageDirectory.path;
          }
          throw MissingPluginException('Unexpected method: ${call.method}');
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    if (storageDirectory.existsSync()) {
      await storageDirectory.delete(recursive: true);
    }
  });

  group('lesson YAML', () {
    test('reads pinyin, simplified and traditional of a Mandarin word', () {
      final parsed = YamlParserService.parseLessonYaml(_mandarinYaml);
      final vocab = parsed.lesson.vocabularies.single;

      expect(vocab.targetWord, '学生');
      expect(vocab.translation, 'student');
      expect(vocab.reading, 'xuésheng');
      expect(vocab.simplified, '学生');
      expect(vocab.traditional, '學生');
      expect(vocab.hanja, isEmpty);
    });

    test('reading is another name for pinyin, and the first one wins', () {
      final parsed = YamlParserService.parseLessonYaml('''
vocabulary:
  nouns:
    - zh: 行
      reading: xíng
      pinyin: háng
      en: to walk
''');

      expect(parsed.lesson.vocabularies.single.reading, 'xíng');
    });

    test('reads the Hanja of a Korean word, and none where there is none', () {
      final parsed = YamlParserService.parseLessonYaml(_koreanYaml);
      final [student, tree] = parsed.lesson.vocabularies;

      expect(student.targetWord, '학생');
      expect(student.hanja, '學生');
      expect(tree.hanja, isEmpty);
      expect(tree.reading, isEmpty);
    });

    test('keeps the region of target: over the language of the entry key', () {
      for (final target in ['zh-CN', 'zh-TW', 'zh-Hant']) {
        final parsed = YamlParserService.parseLessonYaml('''
target: $target
vocabulary:
  nouns:
    - zh: 學生
      en: student
''');
        expect(parsed.lesson.targetLanguage, target);
        expect(parsed.lesson.targetLanguageCode, 'zh');
      }
    });

    test('drops a region that says nothing more than the language', () {
      String languageOf(String target, String key) =>
          YamlParserService.parseLessonYaml('''
target: $target
vocabulary:
  nouns:
    - $key: word
      en: word
''').lesson.targetLanguage;

      // Whether the entries are keyed by the language or by `target:`.
      for (final key in ['ko', 'target']) {
        expect(languageOf('ko-KR', key), 'ko', reason: key);
        expect(languageOf('ko_kr', key), 'ko', reason: key);
      }
      expect(languageOf('ja-JP', 'ja'), 'ja');
      expect(languageOf('ja-JP', 'target'), 'ja');
      expect(languageOf('th-TH', 'target'), 'th');
      expect(languageOf('de-DE', 'de'), 'de');
      // A region that tells a variant apart stays.
      expect(languageOf('de-AT', 'de'), 'de-AT');
      expect(languageOf('pt-BR', 'pt'), 'pt-BR');
      expect(languageOf('en-GB', 'target'), 'en-GB');
      expect(languageOf('zh-CN', 'zh'), 'zh-CN');
    });

    test('dropping the region does not change the id a word gets', () {
      String idOf(String target) => YamlParserService.parseLessonYaml('''
target: $target
vocabulary:
  nouns:
    - target: 단어
      en: word
''').lesson.vocabularies.single.id;

      // As before this change: the id is made from `target:` as written.
      expect(idOf('ko-KR'), isNot(idOf('ko')));
    });

    test('an entry key still decides the language when it is another one', () {
      final parsed = YamlParserService.parseLessonYaml('''
target: ko
vocabulary:
  nouns:
    - zh: 學生
      en: student
''');
      expect(parsed.lesson.targetLanguage, 'zh');
    });

    test('the region does not change the id a word gets', () {
      String idOf(String header) => YamlParserService.parseLessonYaml('''
${header}vocabulary:
  nouns:
    - zh: 學生
      en: student
''').lesson.vocabularies.single.id;

      // The same word in a zh-TW lesson and in one with no target shares
      // progress, as it did before the region was kept.
      expect(idOf('target: zh-TW\n'), idOf(''));
    });
  });

  group('VocabItem', () {
    test('saves and loads its reading and forms', () {
      final vocab = VocabItem(
        targetWord: '学生',
        translation: 'student',
        reading: 'xuésheng',
        simplified: '学生',
        traditional: '學生',
        hanja: '學生',
        pos: 'nouns',
      );
      final loaded = VocabItem.fromJson(
        Map<String, dynamic>.from(
          jsonDecode(jsonEncode(vocab.toJson())) as Map,
        ),
      );

      expect(loaded.reading, 'xuésheng');
      expect(loaded.simplified, '学生');
      expect(loaded.traditional, '學生');
      expect(loaded.hanja, '學生');
    });

    test('a word without them is saved as before and loads empty', () {
      final json = VocabItem(
        targetWord: '나무',
        translation: 'tree',
        pos: 'nouns',
      ).toJson();

      for (final key in ['reading', 'simplified', 'traditional', 'hanja']) {
        expect(json.containsKey(key), isFalse, reason: key);
      }
      final loaded = VocabItem.fromJson(json);
      expect(loaded.reading, isEmpty);
      expect(loaded.simplified, isEmpty);
      expect(loaded.traditional, isEmpty);
      expect(loaded.hanja, isEmpty);
    });

    test('otherForms leaves out the form the word is written in', () {
      final vocab = VocabItem(
        targetWord: '学生',
        translation: 'student',
        simplified: '学生',
        traditional: '學生',
        pos: 'nouns',
      );
      expect(_otherForms(vocab), ['Traditional: 學生']);

      final korean = VocabItem(
        targetWord: '학생',
        translation: 'student',
        hanja: '學生',
        pos: 'nouns',
      );
      expect(_otherForms(korean), ['Hanja: 學生']);

      final plain = VocabItem(targetWord: '나무', translation: 'tree', pos: 'n');
      expect(plain.otherForms, isEmpty);
    });

    test('variantsOf splits alternatives at a slash, semicolon or 、', () {
      expect(VocabItem.variantsOf('shéi / shuí'), ['shéi', 'shuí']);
      expect(VocabItem.variantsOf('臺灣／台灣'), ['臺灣', '台灣']);
      expect(VocabItem.variantsOf('きょう、こんにち'), ['きょう', 'こんにち']);
      expect(VocabItem.variantsOf('a; b；c'), ['a', 'b', 'c']);
      expect(VocabItem.variantsOf('xuésheng'), ['xuésheng']);
      // Spaces inside a reading are kept, and empty or repeated ones go.
      expect(VocabItem.variantsOf(' nǐ hǎo // nǐ hǎo '), ['nǐ hǎo']);
      expect(VocabItem.variantsOf('  '), isEmpty);
    });

    test('a Korean word can have several Hanja forms', () {
      final country = YamlParserService.parseLessonYaml(
        'vocabulary:\n  nouns:\n    - ko: 국\n      hanja: [國, 国]\n'
        '      en: country\n',
      ).lesson.vocabularies.single;

      expect(country.hanja, '國 / 国');
      expect(_otherForms(country), ['Hanja: 國 | 国']);
      // The Hangul word is not drawn; each Hanja form is.
      expect(CharacterZoom.zoomForms(country).map((f) => f.form), ['國', '国']);
    });

    test('readings and otherForms list every alternative', () {
      final who = VocabItem(
        targetWord: '誰',
        translation: 'who',
        reading: 'shéi / shuí',
        pos: 'pronouns',
      );
      expect(who.readings, ['shéi', 'shuí']);

      // A variant that is the word itself is left out, and a form with no
      // other variant is left out altogether.
      final taiwan = VocabItem(
        targetWord: '台灣',
        translation: 'Taiwan',
        simplified: '台湾',
        traditional: '臺灣 / 台灣',
        pos: 'nouns',
      );
      expect(_otherForms(taiwan), ['Simplified: 台湾', 'Traditional: 臺灣']);
      taiwan.simplified = '台灣';
      taiwan.traditional = '台灣';
      expect(taiwan.otherForms, isEmpty);
    });
  });

  group('several readings and forms', () {
    test('a YAML list is read as alternatives, a string as written', () {
      final parsed = YamlParserService.parseLessonYaml(_variantsYaml);
      final [who, taiwan] = parsed.lesson.vocabularies;

      expect(who.reading, 'shéi / shuí');
      expect(who.readings, ['shéi', 'shuí']);
      expect(taiwan.reading, 'Táiwān');
      expect(taiwan.traditional, '臺灣 / 台灣');

      final kept = YamlParserService.parseLessonYaml(
        'vocabulary:\n  pronouns:\n    - zh: 誰\n      pinyin: shéi、shuí\n'
        '      en: who\n',
      ).lesson.vocabularies.single;
      expect(kept.reading, 'shéi、shuí');
      expect(kept.readings, ['shéi', 'shuí']);
    });

    test('the example in docs/lesson-format.md reads as alternatives', () {
      final doc = File('docs/lesson-format.md')
          .readAsStringSync()
          .replaceAll('\r\n', '\n');
      final block = RegExp(
        '```yaml\n(.*?)```',
        dotAll: true,
      ).allMatches(doc).map((m) => m[1]!).firstWhere((b) => b.contains('誰'));
      final [who, taiwan] = YamlParserService.parseLessonYaml(block)
          .lesson
          .vocabularies;

      expect(who.readings, ['shéi', 'shuí']);
      expect(_otherForms(taiwan), ['Traditional: 臺灣']);
    });

    test('export writes a list, and reimports it', () {
      final parsed = YamlParserService.parseLessonYaml(_variantsYaml);
      final markdown = MarkdownArchiveService.readMarkdownFiles(
        LessonExportService.createZip([parsed.lesson], parsed.sentences),
      ).single.contents;

      expect(markdown, contains('"pinyin":["shéi","shuí"]'));
      expect(markdown, contains('"traditional":["臺灣","台灣"]'));
      expect(markdown, contains('"pinyin":"Táiwān"'));

      final again = YamlParserService.parseLessonYaml(markdown);
      final [who, taiwan] = again.lesson.vocabularies;
      expect(who.reading, 'shéi / shuí');
      expect(taiwan.traditional, '臺灣 / 台灣');
    });

    test('writing back writes alternatives typed in the app as a list', () {
      final parsed = YamlParserService.parseLessonYaml(_variantsYaml);
      final [who, taiwan] = parsed.lesson.vocabularies;
      who.reading = 'shéi/shuí/shúi';
      taiwan.reading = 'Táiwān';

      final update = LessonFileUpdate.plan(_variantsYaml, parsed.lesson, {
        for (final sentence in parsed.sentences) sentence.id: sentence,
      })!;

      expect(update.changed, 1);
      final [whoAgain, _] = YamlParserService.parseLessonYaml(update.text)
          .lesson
          .vocabularies;
      expect(whoAgain.readings, ['shéi', 'shuí', 'shúi']);
      expect(update.text, isNot(contains('shéi/shuí')));
    });
  });

  group('kanji and variants', () {
    const yaml = '''
---
target: ja
vocabulary:
  nouns:
    - ja: すし
      kanji: [寿司, 鮨]
      en: sushi
    - ja: 寿司
      reading: すし
      variant: 鮨
      en: sushi (in kanji)
---
# Lesson
''';

    test('are read from a lesson file, and shown as other forms', () {
      final [kana, kanji] = YamlParserService.parseLessonYaml(yaml)
          .lesson
          .vocabularies;

      expect(kana.kanji, '寿司 / 鮨');
      expect(_otherForms(kana), ['Kanji: 寿司 | 鮨']);
      expect(CharacterZoom.zoomForms(kana).map((f) => f.form), ['寿司', '鮨']);
      expect(kanji.variants, '鮨');
      expect(_otherForms(kanji), ['Also written: 鮨']);

      final english = VocabItem(
        targetWord: 'color',
        translation: '색',
        variants: 'colour',
        pos: 'nouns',
      );
      expect(_otherForms(english), ['Also written: colour']);
      expect(CharacterZoom.canZoom(english), isFalse);
    });

    test('are saved and loaded with the word and its source', () {
      final kana = YamlParserService.parseLessonYaml(yaml)
          .lesson
          .vocabularies
          .first;
      final loaded = VocabItem.fromJson(
        jsonDecode(jsonEncode(kana.toJson())) as Map<String, dynamic>,
      );

      expect(loaded.kanji, '寿司 / 鮨');
      expect(loaded.source!.kanji, '寿司 / 鮨');
      expect(loaded.variants, isEmpty);
    });

    test('are exported, and written back under their keys', () {
      final parsed = YamlParserService.parseLessonYaml(yaml);
      final markdown = MarkdownArchiveService.readMarkdownFiles(
        LessonExportService.createZip([parsed.lesson], parsed.sentences),
      ).single.contents;
      expect(markdown, contains('"kanji":["寿司","鮨"]'));
      expect(markdown, contains('"variants":"鮨"'));

      final [kana, kanji] = parsed.lesson.vocabularies;
      kana.variants = 'スシ';
      kanji.variants = '鮓 / 鮨';
      final update = LessonFileUpdate.plan(yaml, parsed.lesson, {
        for (final sentence in parsed.sentences) sentence.id: sentence,
      })!;
      expect(update.changed, 2);
      // A new key is written as `variants`, an old one under its own name.
      expect(update.text, contains('variants: スシ'));
      expect(update.text, isNot(contains('variant: 鮨')));
      final [kanaAgain, kanjiAgain] = YamlParserService.parseLessonYaml(
        update.text,
      ).lesson.vocabularies;
      expect(kanaAgain.variants, 'スシ');
      expect(kanjiAgain.variants, '鮓 / 鮨');
    });

    test('are read from a Vocabulary section', () {
      final japanese = YamlParserService.parseVocabularySection('''
- すし (寿司) — sushi
- 寿司 (すし) (also: 鮨) — sushi (in kanji)
''', targetLanguage: 'ja');
      final [kana, kanji] = japanese.words;
      expect(kana.forms, {'kanji': '寿司'});
      expect(kanji.reading, 'すし');
      expect(kanji.forms, {'variants': '鮨'});

      final english = YamlParserService.parseVocabularySection('''
- color (variant: colour) (also used for paint) — 색
''', targetLanguage: 'en');
      final word = english.words.single;
      expect(word.forms, {'variants': 'colour'});
      expect(word.notes, ['also used for paint']);
    });
  });

  group('export', () {
    String exported(YamlParseResult parsed) =>
        MarkdownArchiveService.readMarkdownFiles(
          LessonExportService.createZip([parsed.lesson], parsed.sentences),
        ).single.contents;

    test('a Mandarin lesson exports pinyin and both forms, and reimports', () {
      final parsed = YamlParserService.parseLessonYaml(_mandarinYaml);
      final markdown = exported(parsed);

      expect(markdown, contains('"pinyin":"xuésheng"'));
      expect(markdown, contains('"traditional":"學生"'));
      expect(markdown, isNot(contains('"hanja"')));

      final again = YamlParserService.parseLessonYaml(markdown);
      final vocab = again.lesson.vocabularies.single;
      expect(again.lesson.targetLanguage, 'zh-CN');
      expect(vocab.reading, 'xuésheng');
      expect(vocab.simplified, '学生');
      expect(vocab.traditional, '學生');
    });

    test('a Korean lesson exports Hanja, and reimports it', () {
      final parsed = YamlParserService.parseLessonYaml(_koreanYaml);
      final markdown = exported(parsed);

      expect(markdown, contains('"hanja":"學生"'));
      expect(markdown, isNot(contains('"pinyin"')));
      expect(markdown, isNot(contains('"reading"')));

      final again = YamlParserService.parseLessonYaml(markdown);
      expect(again.lesson.vocabularies.first.hanja, '學生');
      expect(again.lesson.vocabularies.last.hanja, isEmpty);
    });
  });

  group('AI vocabulary suggestions', () {
    test('a Chinese lesson is asked for pinyin, keyed by zh', () {
      final prompt = LessonAiPrompt.vocabularyYamlInstructions(
        Lesson(title: 'L', targetLanguage: 'zh-TW'),
      );

      expect(prompt, contains('    - zh: "..."\n      pinyin: "..."\n'));
      expect(prompt, contains('traditional characters'));
      expect(prompt, isNot(contains('zh-TW:')));
      expect(prompt, isNot(contains('hanja')));
    });

    test('a mainland Chinese lesson is asked for simplified characters', () {
      for (final target in ['zh', 'zh-CN']) {
        final prompt = LessonAiPrompt.vocabularyYamlInstructions(
          Lesson(title: 'L', targetLanguage: target),
        );
        expect(prompt, contains('simplified characters'), reason: target);
      }
    });

    test('a Korean lesson is asked for the Hanja of Sino-Korean words', () {
      final prompt = LessonAiPrompt.vocabularyYamlInstructions(
        Lesson(title: 'L'),
      );

      expect(prompt, contains('    - ko: "..."\n      hanja: "..."\n'));
      expect(prompt, isNot(contains('pinyin')));
    });
  });

  group('reimport', () {
    testWidgets('updates the reading and forms of a word already imported', (
      tester,
    ) async {
      final provider = await _loadedProvider(tester);
      const before =
          '---\ntarget: zh-CN\nvocabulary:\n  nouns:\n'
          '    - zh: 学生\n      en: student\n---\n# Lesson\n';
      final lesson = (await tester.runAsync(
        () => provider.importYaml(before),
      ))!;
      expect(lesson.vocabularies.single.reading, isEmpty);

      await tester.runAsync(() => provider.importYaml(_mandarinYaml));

      final vocab = provider.lessons.single.vocabularies.single;
      expect(vocab.reading, 'xuésheng');
      expect(vocab.traditional, '學生');
    });
  });

  group('reimport merge', () {
    testWidgets('keeps a reading edited in the app while the file is as it '
        'was, and takes one the file changed', (tester) async {
      final provider = await _loadedProvider(tester);
      final lesson = (await tester.runAsync(
        () => provider.importYaml(_mandarinYaml),
      ))!;
      // Edited in the app.
      lesson.vocabularies.single.reading = 'xué sheng';

      await tester.runAsync(() => provider.importYaml(_mandarinYaml));
      expect(provider.lessons.single.vocabularies.single.reading, 'xué sheng');

      // Only the file changed its traditional form: that is taken, and the
      // app's reading stays.
      await tester.runAsync(
        () => provider.importYaml(_mandarinYaml.replaceFirst('學生', '學生們')),
      );
      final vocab = provider.lessons.single.vocabularies.single;
      expect(vocab.traditional, '學生們');
      expect(vocab.reading, 'xué sheng');
    });
  });

  group('writing words back to the file', () {
    Map<String, Sentence> byId(YamlParseResult parsed) => {
      for (final sentence in parsed.sentences) sentence.id: sentence,
    };

    test('needs nothing for a file the app agrees with', () {
      for (final yaml in [_mandarinYaml, _koreanYaml]) {
        final parsed = YamlParserService.parseLessonYaml(yaml);
        expect(
          LessonFileUpdate.plan(yaml, parsed.lesson, byId(parsed)),
          isNull,
        );
      }
    });

    test('writes Hanja added in the app, and a changed one under its key', () {
      final parsed = YamlParserService.parseLessonYaml(_koreanYaml);
      final [student, tree] = parsed.lesson.vocabularies;
      student.hanja = '學生 (edited)';
      tree.hanja = '木';

      final update = LessonFileUpdate.plan(
        _koreanYaml,
        parsed.lesson,
        byId(parsed),
      )!;

      expect(update.changed, 2);
      final [first, second] = YamlParserService.parseLessonYaml(update.text)
          .lesson
          .vocabularies;
      expect(first.hanja, '學生 (edited)');
      expect(second.hanja, '木');
      expect(second.targetWord, '나무');
    });

    test('writes a reading under the key the entry has, pinyin if none', () {
      const yaml = '''
---
target: zh-TW
vocabulary:
  nouns:
    - zh: 學生
      reading: xuesheng
      en: student
    - zh: 老師
      en: teacher
---
# Lesson
''';
      final parsed = YamlParserService.parseLessonYaml(yaml);
      final [student, teacher] = parsed.lesson.vocabularies;
      student.reading = 'xuésheng';
      teacher.reading = 'lǎoshī';

      final text = LessonFileUpdate.plan(
        yaml,
        parsed.lesson,
        byId(parsed),
      )!.text;

      // The value may be written with or without quotes.
      expect(text, contains(RegExp('reading: ["\']?xuésheng')));
      expect(text, contains(RegExp('pinyin: ["\']?lǎoshī')));
      expect(text, isNot(contains('xuesheng')));
    });

    test('keeps the quotes of the value it replaces, or of the word', () {
      const yaml = '''
---
target: zh-CN
vocabulary:
  nouns:
    - zh: "这"
      en: "this"
      pinyin: "zhe4"
    - zh: '我'
      en: 'I'
    - zh: 你
      en: you
---
# Lesson
''';
      final parsed = YamlParserService.parseLessonYaml(yaml);
      final [zhe, wo, ni] = parsed.lesson.vocabularies;
      zhe.reading = 'zhè';
      wo.reading = 'wǒ';
      ni.reading = 'nǐ';
      zhe.translation = 'this one';

      final text = LessonFileUpdate.plan(
        yaml,
        parsed.lesson,
        byId(parsed),
      )!.text;

      expect(text, contains('pinyin: "zhè"'));
      expect(text, contains('en: "this one"'));
      expect(text, contains("pinyin: 'wǒ'"));
      expect(text, contains('pinyin: nǐ'));
    });
  });

  group('back of the card', () {
    Future<void> study(WidgetTester tester, String yaml) async {
      final provider = await _loadedProvider(tester);
      final lesson = (await tester.runAsync(() => provider.importYaml(yaml)))!;
      for (final vocab in lesson.vocabularies) {
        vocab.cardNativeToTarget.isEnabled = false;
      }
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AppProvider>.value(value: provider),
            ChangeNotifierProvider<AudioService>(
              create: (_) => _FakeAudioService(),
            ),
          ],
          child: MaterialApp(home: StudyView(lessonId: lesson.id)),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    Future<void> reveal(WidgetTester tester) async {
      await tester.tap(find.textContaining('Show Answer'));
      await tester.pumpAndSettle();
    }

    testWidgets('shows pinyin and the other form, only once revealed', (
      tester,
    ) async {
      await study(tester, _mandarinYaml);

      expect(find.byKey(const ValueKey('vocab-reading')), findsNothing);
      expect(find.byKey(const ValueKey('vocab-other-forms')), findsNothing);

      await reveal(tester);

      expect(find.text('xuésheng'), findsOneWidget);
      // The simplified form is the word itself, so only the other is named.
      expect(find.text('Traditional: 學生'), findsOneWidget);
      expect(find.textContaining('Simplified'), findsNothing);
    });

    testWidgets('shows the Hanja of a Korean word', (tester) async {
      await study(
        tester,
        '---\nvocabulary:\n  nouns:\n    - ko: 학생\n      hanja: 學生\n'
        '      en: student\n---\n# Lesson\n',
      );
      await reveal(tester);

      expect(find.text('Hanja: 學生'), findsOneWidget);
      expect(find.byKey(const ValueKey('vocab-reading')), findsNothing);
    });

    testWidgets('tapping the word zooms into it and its other forms', (
      tester,
    ) async {
      await study(tester, _mandarinYaml);
      await reveal(tester);

      await tester.tap(find.byKey(const ValueKey('vocab-zoom-word')));
      await tester.pumpAndSettle();

      final zoom = find.byKey(const ValueKey('character-zoom'));
      expect(zoom, findsOneWidget);
      expect(
        find.descendant(of: zoom, matching: find.text('学生')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: zoom, matching: find.text('學生')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: zoom, matching: find.text('Traditional')),
        findsOneWidget,
      );
    });

    testWidgets('a Korean word zooms into its Hanja, not its Hangul', (
      tester,
    ) async {
      await study(
        tester,
        '---\nvocabulary:\n  nouns:\n    - ko: 학생\n      hanja: 學生\n'
        '      en: student\n---\n# Lesson\n',
      );
      await reveal(tester);

      await tester.tap(find.byKey(const ValueKey('vocab-zoom-word')));
      await tester.pumpAndSettle();

      final zoom = find.byKey(const ValueKey('character-zoom'));
      expect(
        find.descendant(of: zoom, matching: find.text('學生')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: zoom, matching: find.text('Hanja')),
        findsOneWidget,
      );
      // The Hangul is only the heading, not drawn large.
      expect(
        find.descendant(of: zoom, matching: find.text('학생')),
        findsOneWidget,
      );
    });

    testWidgets('a Korean word written in Hanja zooms into itself', (
      tester,
    ) async {
      await study(
        tester,
        '---\nvocabulary:\n  nouns:\n    - ko: 學生\n      en: student\n'
        '---\n# Lesson\n',
      );
      await reveal(tester);

      await tester.tap(find.byKey(const ValueKey('vocab-zoom-word')));
      await tester.pumpAndSettle();

      final zoom = find.byKey(const ValueKey('character-zoom'));
      expect(
        find.descendant(of: zoom, matching: find.text('學生')),
        findsOneWidget,
      );
    });

    testWidgets('a Hangul word without Hanja has no zoom', (tester) async {
      await study(
        tester,
        '---\nvocabulary:\n  nouns:\n    - ko: 나무\n      en: tree\n---\n'
        '# Lesson\n',
      );
      await reveal(tester);

      expect(find.byKey(const ValueKey('vocab-zoom-word')), findsNothing);
    });

    testWidgets('shows every reading and variant, split by a slash', (
      tester,
    ) async {
      await study(
        tester,
        '---\ntarget: zh-TW\nvocabulary:\n  pronouns:\n    - zh: 誰\n'
        '      pinyin: [shéi, shuí]\n      simplified: 谁\n      en: who\n'
        '---\n# Lesson\n',
      );
      await reveal(tester);

      expect(find.text('shéi / shuí'), findsOneWidget);
      expect(find.text('Simplified: 谁'), findsOneWidget);
      // A screen reader hears the alternatives as such.
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('vocab-reading')))
            .semanticsLabel,
        'Read as shéi or shuí',
      );
    });

    testWidgets('zooms into each variant on its own', (tester) async {
      await study(
        tester,
        '---\ntarget: zh-CN\nvocabulary:\n  nouns:\n    - zh: 台\n'
        '      traditional: [臺, 颱, 檯]\n      en: platform\n---\n# Lesson\n',
      );
      await reveal(tester);

      expect(find.text('Traditional: 臺 / 颱 / 檯'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('vocab-zoom-word')));
      await tester.pumpAndSettle();

      final zoom = find.byKey(const ValueKey('character-zoom'));
      for (final form in ['台', '臺', '颱', '檯']) {
        expect(
          find.descendant(of: zoom, matching: find.text(form)),
          findsOneWidget,
          reason: form,
        );
      }
      expect(
        find.descendant(of: zoom, matching: find.text('Traditional')),
        findsNWidgets(3),
      );
    });

    testWidgets('shows neither line for a word without them', (tester) async {
      await study(
        tester,
        '---\nvocabulary:\n  nouns:\n    - ko: 나무\n      en: tree\n---\n'
        '# Lesson\n',
      );
      await reveal(tester);

      expect(find.byKey(const ValueKey('vocab-reading')), findsNothing);
      expect(find.byKey(const ValueKey('vocab-other-forms')), findsNothing);
    });
  });
}

Future<AppProvider> _loadedProvider(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({
    'lingua_srs_windows_legacy_migration_complete': true,
  });
  final provider = AppProvider();
  addTearDown(provider.dispose);
  for (var i = 0; i < 100 && provider.isLoading; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(provider.isLoading, isFalse, reason: 'provider never loaded');
  return provider;
}
