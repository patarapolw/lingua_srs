import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/lesson.dart';
import 'package:lingua_srs/models/sentence.dart';
import 'package:lingua_srs/models/srs_card.dart';
import 'package:lingua_srs/models/vocab_item.dart';
import 'package:lingua_srs/providers/app_provider.dart';
import 'package:lingua_srs/services/storage_service.dart';
import 'package:lingua_srs/services/yaml_parser_service.dart';
import 'package:lingua_srs/views/yaml_import_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'secret_storage_mock.dart';

/// Importing a lesson file again after its words were edited in the app
/// (#187) or in the file (#186), and writing the app's words back to it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(setUpSecretStorage);

  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory storageDirectory;

  setUp(() {
    storageDirectory = Directory.systemTemp.createTempSync(
      'lingua_srs_reimport_word_edits_test_',
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

  Future<AppProvider> loadedProvider(
    WidgetTester tester, {
    Map<String, Object> saved = const {},
  }) async {
    SharedPreferences.setMockInitialValues({
      'lingua_srs_windows_legacy_migration_complete': true,
      ...saved,
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

  /// The text of `unit-1/lesson-1.md` with [vocabulary] under `verbs:`.
  String lessonFile(String vocabulary, {String text = 'Text.'}) =>
      '---\nvocabulary:\n  verbs:\n$vocabulary---\n# Lesson 1\n\n$text\n';

  const go = '''
    - ko: 가다
      en: to go
      examples:
        - ko: 학교에 **가요**
          en: I **go** to school
        - ko: 집에 **가요**
          en: I go home
''';

  Future<Lesson> import(
    WidgetTester tester,
    AppProvider provider,
    String contents, {
    String path = 'unit-1/lesson-1.md',
  }) async {
    final lessons = await tester.runAsync(
      () => provider.importParsedLessons([
        YamlParserService.parseLessonYaml(
          contents,
          defaultUnitTitle: 'Unit 1',
          sourcePath: path,
        ),
      ]),
    );
    return lessons!.single;
  }

  List<String> examplesOf(AppProvider provider, VocabItem vocab) => [
    for (final sentence in provider.getSentencesForVocab(vocab))
      vocab.targetTextFor(sentence),
  ];

  group('a word edited in the app (#187)', () {
    testWidgets('keeps its word and translation when the file is imported '
        'again with other changes', (tester) async {
      final provider = await loadedProvider(tester);
      final lesson = await import(tester, provider, lessonFile(go));
      final word = lesson.vocabularies.single;
      word.cardTargetToNative.repetitions = 4;
      word.translation = 'go';
      await tester.runAsync(() => provider.updateVocab(word));

      await import(tester, provider, lessonFile(go, text: 'New text.'));

      expect(lesson.markdownContent, contains('New text.'));
      expect(lesson.vocabularies, hasLength(1));
      expect(word.targetWord, '가다');
      expect(word.translation, 'go');
      expect(word.cardTargetToNative.repetitions, 4);
    });

    testWidgets('takes what the file changed in the other field', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      final lesson = await import(tester, provider, lessonFile(go));
      final word = lesson.vocabularies.single..translation = 'go';
      await tester.runAsync(() => provider.updateVocab(word));

      await import(
        tester,
        provider,
        lessonFile(go.replaceFirst('ko: 가다', 'ko: 갔다')),
      );

      expect(lesson.vocabularies, hasLength(1));
      expect(word.targetWord, '갔다');
      expect(word.translation, 'go');
    });

    testWidgets('keeps the app\'s edit when the file changed the same field', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      final lesson = await import(tester, provider, lessonFile(go));
      final word = lesson.vocabularies.single..translation = 'go';
      await tester.runAsync(() => provider.updateVocab(word));

      await import(
        tester,
        provider,
        lessonFile(go.replaceFirst('en: to go', 'en: to go, to leave')),
      );

      expect(lesson.vocabularies, hasLength(1));
      expect(word.translation, 'go');
      // The file's wording is what it is compared with next time.
      expect(word.source!.translation, 'to go, to leave');
    });

    testWidgets('keeps examples removed and edited in the app, and adds no '
        'stray sentence to the pool', (tester) async {
      final provider = await loadedProvider(tester);
      final lesson = await import(tester, provider, lessonFile(go));
      final word = lesson.vocabularies.single;
      final home = provider
          .getSentencesForVocab(word)
          .firstWhere((sentence) => sentence.targetText == '집에 가요');
      word.sentenceIds.remove(home.id);
      final school = provider.getSentencesForVocab(word).single;
      school.targetText = '학교에 가요!';
      await tester.runAsync(() => provider.updateSentenceInPool(school));
      final poolSize = provider.sentences.length;

      await import(tester, provider, lessonFile(go, text: 'New text.'));

      expect(examplesOf(provider, word), ['학교에 **가요**!']);
      expect(provider.sentences, hasLength(poolSize));
    });

    testWidgets('takes examples the file adds and removes, keeping the '
        'app\'s own', (tester) async {
      final provider = await loadedProvider(tester);
      final lesson = await import(tester, provider, lessonFile(go));
      final word = lesson.vocabularies.single;
      final own = await tester.runAsync(
        () => provider.addSentenceToPool(
          Sentence(targetText: '같이 가요', translationText: "Let's go"),
        ),
      );
      word.sentenceIds.add(own!.id);

      await import(
        tester,
        provider,
        lessonFile(
          go
              .replaceFirst(
                '        - ko: 집에 **가요**\n          en: I go home\n',
                '',
              )
              .replaceFirst(
                '      examples:\n',
                '      examples:\n        - ko: 어디 **가요**?\n'
                    '          en: Where are you going?\n',
              ),
        ),
      );

      expect(examplesOf(provider, word), ['학교에 **가요**', '같이 가요', '어디 **가요**?']);
    });

    testWidgets('takes a new marking of an example from the file', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      final lesson = await import(tester, provider, lessonFile(go));
      final word = lesson.vocabularies.single;

      await import(
        tester,
        provider,
        lessonFile(go.replaceFirst('학교에 **가요**', '"**학교에** 가요"')),
      );

      expect(examplesOf(provider, word), ['**학교에** 가요', '집에 **가요**']);
    });

    testWidgets('a word saved before the file\'s values were kept stays as '
        'edited when its entry reads as it did', (tester) async {
      // Saved by an earlier version: the id made from the word and its
      // translation as imported, and no record of what the file said.
      final imported = YamlParserService.parseLessonYaml(
        lessonFile(go),
        defaultUnitTitle: 'Unit 1',
        sourcePath: 'unit-1/lesson-1.md',
      );
      final saved = imported.lesson.vocabularies.single
        ..source = null
        ..translation = 'go';
      final provider = await loadedProvider(
        tester,
        saved: {
          'lingua_srs_lessons': jsonEncode([imported.lesson.toJson()]),
          'lingua_srs_sentences': jsonEncode([
            for (final sentence in imported.sentences) sentence.toJson(),
          ]),
        },
      );
      expect(provider.lessons.single.vocabularies.single.source, isNull);

      final lesson = await import(
        tester,
        provider,
        lessonFile(go, text: 'New text.'),
      );

      final word = lesson.vocabularies.single;
      expect(word.id, saved.id);
      expect(word.translation, 'go');
      expect(word.source!.translation, 'to go');
    });

    testWidgets('so does one whose id was linked to the same word in another '
        'lesson', (tester) async {
      // Sharing progress with another lesson's word marks the id as
      // explicit, though it is still the one made from this entry.
      final imported = YamlParserService.parseLessonYaml(
        lessonFile(go),
        defaultUnitTitle: 'Unit 1',
        sourcePath: 'unit-1/lesson-1.md',
      );
      final saved = imported.lesson.vocabularies.single
        ..source = null
        ..idIsExplicit = true
        ..translation = 'go';
      final provider = await loadedProvider(
        tester,
        saved: {
          'lingua_srs_lessons': jsonEncode([imported.lesson.toJson()]),
          'lingua_srs_sentences': jsonEncode([
            for (final sentence in imported.sentences) sentence.toJson(),
          ]),
        },
      );

      final lesson = await import(
        tester,
        provider,
        lessonFile(go, text: 'New text.'),
      );

      final word = lesson.vocabularies.single;
      expect(word.id, saved.id);
      expect(word.translation, 'go');
      expect(word.source!.translation, 'to go');
    });
  });

  group('an entry edited in the file (#186)', () {
    const words = '''
    - ko: 가다
      en: to go
    - ko: 오다
      en: to come
''';

    testWidgets('a reworded translation updates the word, with its progress', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      final lesson = await import(tester, provider, lessonFile(words));
      final word = lesson.vocabularies.first;
      word.cardTargetToNative
        ..repetitions = 4
        ..status = SrsStatus.review;

      await import(
        tester,
        provider,
        lessonFile(words.replaceFirst('en: to go', 'en: go')),
      );

      expect(lesson.vocabularies, hasLength(2));
      expect(lesson.vocabularies.first, same(word));
      expect(word.translation, 'go');
      expect(word.cardTargetToNative.repetitions, 4);
    });

    testWidgets('a typo fixed in the word updates the word', (tester) async {
      final provider = await loadedProvider(tester);
      final lesson = await import(
        tester,
        provider,
        lessonFile(words.replaceFirst('ko: 오다', 'ko: 오디')),
      );
      final word = lesson.vocabularies.last;

      await import(tester, provider, lessonFile(words));

      expect(lesson.vocabularies, hasLength(2));
      expect(word.targetWord, '오다');
    });

    testWidgets('another word with the same translation is a new word', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      final lesson = await import(tester, provider, lessonFile(words));

      await import(
        tester,
        provider,
        lessonFile(words.replaceFirst('ko: 가다', 'ko: 떠나다')),
      );

      expect(lesson.vocabularies.map((vocab) => vocab.targetWord), [
        '가다',
        '오다',
        '떠나다',
      ]);
    });

    testWidgets('two entries that could both be the edit are new words', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      final lesson = await import(tester, provider, lessonFile(words));

      await import(
        tester,
        provider,
        lessonFile('''
    - ko: 가다
      en: go
    - ko: 가다
      en: leave
    - ko: 오다
      en: to come
'''),
      );

      expect(lesson.vocabularies, hasLength(4));
    });

    testWidgets('an id added to an entry keeps it the same word', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      final lesson = await import(tester, provider, lessonFile(words));
      final word = lesson.vocabularies.first;

      await import(
        tester,
        provider,
        lessonFile(words.replaceFirst('- ko: 가다', '- id: go\n      ko: 가다')),
      );

      expect(lesson.vocabularies, hasLength(2));
      expect(word.id, 'go');
      expect(word.idIsExplicit, isTrue);
    });

    testWidgets('a word added in the app is never taken for an edited entry', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      final lesson = await import(tester, provider, lessonFile(words));
      final own = VocabItem(targetWord: '배', translation: 'pear', pos: 'verbs');
      await tester.runAsync(() => provider.addVocabToLesson(lesson.id, own));

      await import(
        tester,
        provider,
        lessonFile('$words    - ko: 배\n      en: boat\n'),
      );

      expect(own.translation, 'pear');
      expect(lesson.vocabularies, hasLength(4));
    });
  });

  group('writing the app\'s words back to the folder', () {
    late Directory folder;

    setUp(() {
      folder = Directory.systemTemp.createTempSync('lingua_srs_lessons_');
      Directory('${folder.path}/unit-1').createSync();
    });

    tearDown(() => folder.deleteSync(recursive: true));

    String hash(String text) => sha256.convert(utf8.encode(text)).toString();

    /// [path] with `/` between folders: a scan on Windows gives `\`.
    String slashes(String path) => path.replaceAll('\\', '/');

    LessonFileRef save(String contents) {
      final file = File('${folder.path}/unit-1/lesson-1.md')
        ..writeAsStringSync(contents);
      return LessonFileRef(
        filePath: file.path,
        path: 'unit-1/lesson-1.md',
        sourceKey: markdownSourceKey(file.path),
        sourceHash: hash(contents),
      );
    }

    testWidgets('writes edits, keeps the text, and the file is unchanged at '
        'the next scan', (tester) async {
      final provider = await loadedProvider(tester);
      final contents = lessonFile(go, text: 'Text.\n\n---\n\nMore text.');
      final ref = save(contents);
      final lesson = await import(tester, provider, contents);
      final word = lesson.vocabularies.single..translation = 'go';
      await tester.runAsync(() => provider.updateVocab(word));

      final dry = await tester.runAsync(
        () => writeLessonFiles(provider, [ref], dryRun: true),
      );
      expect(dry!.files, 1);
      expect(File(ref.filePath).readAsStringSync(), contents);

      final result = await tester.runAsync(
        () => writeLessonFiles(provider, [ref]),
      );

      expect(result!.files, 1);
      expect(result.words, 1);
      expect(result.errors, isEmpty);
      final written = File(ref.filePath).readAsStringSync();
      expect(written, contents.replaceFirst('en: to go', 'en: go'));
      expect(word.source!.translation, 'go');
      final sources = await tester.runAsync(
        StorageService.loadImportedMarkdownSources,
      );
      expect(sources![ref.sourceKey], hash(written));

      // Imported again as written: the same word, nothing more to write.
      await import(tester, provider, written);
      expect(lesson.vocabularies.single, same(word));
      final again = await tester.runAsync(
        () => writeLessonFiles(provider, [
          LessonFileRef(
            filePath: ref.filePath,
            path: ref.path,
            sourceKey: ref.sourceKey,
            sourceHash: hash(written),
          ),
        ], dryRun: true),
      );
      expect(again!.files, 0);
    });

    testWidgets('leaves a file edited since the scan alone', (tester) async {
      final provider = await loadedProvider(tester);
      final contents = lessonFile(go);
      final ref = save(contents);
      final lesson = await import(tester, provider, contents);
      lesson.vocabularies.single.translation = 'go';
      final edited = contents.replaceFirst('Text.', 'Edited since.');
      File(ref.filePath).writeAsStringSync(edited);

      final result = await tester.runAsync(
        () => writeLessonFiles(provider, [ref]),
      );

      expect(result!.files, 0);
      expect(File(ref.filePath).readAsStringSync(), edited);
    });

    testWidgets('a folder scan lists unchanged files and where imported '
        'ones are', (tester) async {
      final contents = lessonFile(go);
      final ref = save(contents);
      final other = File(
        '${folder.path}/unit-1/lesson-2.md',
      )..writeAsStringSync(lessonFile(go).replaceFirst('Lesson 1', 'Lesson 2'));

      final scan = parseMarkdownFiles(
        [ref.filePath, other.path],
        [folder.path],
        {ref.sourceKey: ref.sourceHash},
      );

      expect(scan.unchangedFiles.single.filePath, ref.filePath);
      expect(scan.unchangedFiles.single.path, 'unit-1/lesson-1.md');
      expect(scan.unchangedFiles.single.sourceHash, ref.sourceHash);
      expect(scan.imports.single.fileRef!.filePath, other.path);
      expect(scan.imports.single.fileRef!.path, 'unit-1/lesson-2.md');
    });

    testWidgets('a folder scan does not look into node_modules or hidden '
        'folders', (tester) async {
      final lesson = save(lessonFile(go));
      for (final path in [
        'node_modules/vitepress/README.md',
        'unit-1/node_modules/dep/CHANGELOG.md',
        '.vitepress/cache/notes.md',
        '.git/description.md',
        'unit-1/.draft.md',
      ]) {
        File('${folder.path}/$path')
          ..createSync(recursive: true)
          ..writeAsStringSync('# Not a lesson\n');
      }
      File('${folder.path}/index.md').writeAsStringSync('# Home\n');

      final found = await tester.runAsync(() => markdownFilesUnder(folder));

      expect(found!.map(slashes).toSet(), {
        slashes(lesson.filePath),
        slashes('${folder.path}/index.md'),
      });
      // A folder that was picked is looked into whatever it is called.
      final hidden = await tester.runAsync(
        () => markdownFilesUnder(Directory('${folder.path}/.vitepress')),
      );
      expect(hidden!.map(slashes), [
        slashes('${folder.path}/.vitepress/cache/notes.md'),
      ]);
    });

    testWidgets('a folder scan returns Markdown files in stable path order', (
      tester,
    ) async {
      for (final path in [
        'z.md',
        'a-folder/lesson.md',
        'm.md',
        'a-folder/a.md',
        'a.md',
      ]) {
        File('${folder.path}/$path')
          ..createSync(recursive: true)
          ..writeAsStringSync('# Lesson\n');
      }

      final found = await tester.runAsync(() => markdownFilesUnder(folder));

      expect(
        found!
            .map(
              (path) =>
                  path.substring(folder.path.length + 1).replaceAll('\\', '/'),
            )
            .toList(),
        ['a-folder/a.md', 'a-folder/lesson.md', 'a.md', 'm.md', 'z.md'],
      );
    });

    testWidgets('a folder scan finds files with Hangul or % in their '
        'names', (tester) async {
      final names = ['09-conjugate-이다.md', '23-ㅎ-irregulars.md', '100%.md'];
      for (final name in names) {
        File('${folder.path}/unit-1/$name')
          ..createSync(recursive: true)
          ..writeAsStringSync('# Lesson\n');
      }

      final found = await tester.runAsync(() => markdownFilesUnder(folder));

      expect({
        for (final path in found!) path.split(RegExp(r'[/\\]')).last,
      }, names.toSet());
    });

    testWidgets('a file whose lesson was deleted is offered again though '
        'it has not changed (#185)', (tester) async {
      final provider = await loadedProvider(tester);
      final contents = lessonFile(go);
      final ref = save(contents);
      final lesson = await import(tester, provider, contents);
      MarkdownDirectoryResult scan([Set<String> reimport = const {}]) =>
          parseMarkdownFiles([ref.filePath], [folder.path], {
            ref.sourceKey: ref.sourceHash,
          }, reimport: reimport);

      final first = scan();
      expect(first.unchanged, 1);
      expect(first.unchangedKeys, [ref.sourceKey]);
      expect(provider.hasLessonForFile(first.unchangedLessons.single), isTrue);

      await tester.runAsync(() => provider.deleteLesson(lesson.id));
      expect(provider.hasLessonForFile(first.unchangedLessons.single), isFalse);

      final again = scan({ref.sourceKey});
      expect(again.unchanged, 0);
      expect(again.imports.single.preview.lesson.displayTitle, 'Lesson 1');
    });

    testWidgets('leaves a file with no saved lesson alone', (tester) async {
      final provider = await loadedProvider(tester);
      final contents = lessonFile(go);
      final ref = save(contents);

      final result = await tester.runAsync(
        () => writeLessonFiles(provider, [ref]),
      );

      expect(result!.files, 0);
      expect(File(ref.filePath).readAsStringSync(), contents);
    });
  });
}
