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
      expect(vocab.otherForms, [(label: 'Traditional', form: '學生')]);

      final korean = VocabItem(
        targetWord: '학생',
        translation: 'student',
        hanja: '學生',
        pos: 'nouns',
      );
      expect(korean.otherForms, [(label: 'Hanja', form: '學生')]);

      final plain = VocabItem(targetWord: '나무', translation: 'tree', pos: 'n');
      expect(plain.otherForms, isEmpty);
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
