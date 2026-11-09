import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/lesson.dart';
import 'package:lingua_srs/providers/app_provider.dart';
import 'package:lingua_srs/services/yaml_parser_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'secret_storage_mock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(setUpSecretStorage);

  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory storageDirectory;

  setUp(() {
    storageDirectory = Directory.systemTemp.createTempSync(
      'lingua_srs_lesson_name_clash_test_',
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

  Future<AppProvider> loadedProvider(WidgetTester tester) async {
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

  /// A lesson file as folder import reads it, at `unit-1/<file>`.
  YamlParseResult file(String name, String title, {String word = '단어'}) =>
      YamlParserService.parseLessonYaml(
        '---\nvocabulary:\n  nouns:\n    - ko: $word\n      en: word\n---\n'
        '# $title\n\nText of $name.\n',
        defaultUnitTitle: 'Unit 1',
        sourcePath: 'unit-1/$name',
      );

  /// Imports [parsed], answering every clash with [choice] and counting
  /// how many were asked.
  Future<int> import(
    WidgetTester tester,
    AppProvider provider,
    List<YamlParseResult> parsed, {
    LessonClashChoice choice = LessonClashChoice.keepBoth,
  }) async {
    var asked = 0;
    await tester.runAsync(
      () => provider.importParsedLessons(
        parsed,
        onClash: (_) async {
          asked++;
          return choice;
        },
      ),
    );
    return asked;
  }

  List<Lesson> inUnit1(AppProvider provider) => provider.lessons
      .where((lesson) => isSameHierarchyPath(lesson.folderPath, ['Unit 1']))
      .toList();

  testWidgets('the same file imported again updates without asking', (
    tester,
  ) async {
    final provider = await loadedProvider(tester);
    await import(tester, provider, [file('a.md', 'Lesson 1')]);

    final asked = await import(tester, provider, [
      file('a.md', 'Lesson 1 renamed'),
    ]);

    expect(asked, 0);
    expect(inUnit1(provider).single.displayTitle, 'Lesson 1 renamed');
  });

  testWidgets('another file with a taken name asks; keep both renames it', (
    tester,
  ) async {
    final provider = await loadedProvider(tester);
    await import(tester, provider, [file('a.md', 'Lesson 1')]);

    final asked = await import(tester, provider, [file('b.md', 'Lesson 1')]);

    expect(asked, 1);
    expect(inUnit1(provider).map((lesson) => lesson.displayTitle), [
      'Lesson 1',
      'Lesson 1 (2)',
    ]);
    expect(provider.lessonNameClashes, isEmpty);

    // Importing b.md again finds the renamed lesson and keeps its name.
    expect(await import(tester, provider, [file('b.md', 'Lesson 1')]), 0);
    expect(inUnit1(provider).map((lesson) => lesson.displayTitle), [
      'Lesson 1',
      'Lesson 1 (2)',
    ]);
  });

  testWidgets('clashes within one import are asked too', (tester) async {
    final provider = await loadedProvider(tester);

    final asked = await import(tester, provider, [
      file('a.md', 'Lesson 1'),
      file('b.md', 'lesson 1'),
    ]);

    expect(asked, 1);
    expect(inUnit1(provider), hasLength(2));
  });

  testWidgets('the imported file can overwrite the saved lesson', (
    tester,
  ) async {
    final provider = await loadedProvider(tester);
    await import(tester, provider, [file('a.md', 'Lesson 1', word: '하나')]);

    await import(tester, provider, [
      file('b.md', 'Lesson 1', word: '둘'),
    ], choice: LessonClashChoice.keepIncoming);

    final lesson = inUnit1(provider).single;
    expect(lesson.fileName, 'b.md');
    expect(lesson.markdownContent, contains('Text of b.md.'));
    expect(lesson.vocabularies.map((vocab) => vocab.targetWord).toSet(), {
      '하나',
      '둘',
    });
  });

  testWidgets('keeping the saved lesson skips the file, taking its name', (
    tester,
  ) async {
    final provider = await loadedProvider(tester);
    // Saved before file names were kept: no file name.
    await tester.runAsync(
      () => provider.importYaml(
        '---\nvocabulary:\n---\n# Lesson 1\n\nOld text.\n',
        defaultUnitTitle: 'Unit 1',
      ),
    );
    expect(inUnit1(provider).single.fileName, isNull);

    final asked = await import(tester, provider, [
      file('lesson-1.md', 'Lesson 1'),
    ], choice: LessonClashChoice.keepExisting);

    expect(asked, 1);
    final lesson = inUnit1(provider).single;
    expect(lesson.markdownContent, contains('Old text.'));
    expect(lesson.fileName, 'lesson-1.md');
    // Now at the file's virtual path, so the next import does not ask.
    expect(
      await import(tester, provider, [file('lesson-1.md', 'Lesson 1')]),
      0,
    );
  });

  testWidgets('different files sharing a lesson number stay apart', (
    tester,
  ) async {
    final provider = await loadedProvider(tester);

    final asked = await import(tester, provider, [
      file('a.md', 'Lesson 1: Greetings'),
      file('b.md', 'Lesson 1: Numbers'),
    ]);

    expect(asked, 0);
    expect(inUnit1(provider), hasLength(2));
  });

  testWidgets('saved lessons with one name are listed and resolved', (
    tester,
  ) async {
    final provider = await loadedProvider(tester);
    await import(tester, provider, [file('a.md', 'Lesson 1', word: '하나')]);
    await import(tester, provider, [file('b.md', 'Lesson 1', word: '둘')]);
    // As sync could bring it: the second lesson back under the same name.
    final second = inUnit1(provider).last..title = 'Lesson 1';

    final clash = provider.lessonNameClashes.single;
    expect(clash.incoming, same(second));
    expect(clash.renamedTitle, 'Lesson 1 (2)');

    await tester.runAsync(
      () => provider.resolveLessonNameClash(
        clash,
        LessonClashChoice.keepIncoming,
      ),
    );

    final lesson = inUnit1(provider).single;
    expect(lesson, same(second));
    expect(lesson.vocabularies.map((vocab) => vocab.targetWord).toSet(), {
      '하나',
      '둘',
    });
    expect(provider.lessonNameClashes, isEmpty);
  });
}
