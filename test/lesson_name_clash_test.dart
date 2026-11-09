import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/ai_discussion_message.dart';
import 'package:lingua_srs/models/lesson.dart';
import 'package:lingua_srs/providers/app_provider.dart';
import 'package:lingua_srs/services/lesson_ai_prompt.dart';
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

  testWidgets('a folder whose names a Mac stored as jamo matches', (
    tester,
  ) async {
    final provider = await loadedProvider(tester);
    // `1단원/과거.md` as macOS can store it (NFD), then as typed (NFC).
    const unit = '1\u1103\u1161\u11ab\u110b\u116f\u11ab';
    const file = '\u1100\u116a\u1100\u1165.md';
    YamlParseResult lesson(String folder, String name) =>
        YamlParserService.parseLessonYaml(
          '---\nvocabulary:\n---\n# 과거\n',
          defaultUnitTitle: folder,
          sourcePath: '$folder/$name',
        );

    await import(tester, provider, [lesson(unit, file)]);
    final asked = await import(tester, provider, [lesson('1단원', '과거.md')]);

    expect(asked, 0);
    final saved = provider.lessons
        .where((lesson) => isSameHierarchyPath(lesson.folderPath, ['1단원']))
        .single;
    expect(saved.fileName, '과거.md');
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

  testWidgets('the removed lesson\'s AI chat joins the kept one\'s', (
    tester,
  ) async {
    final provider = await loadedProvider(tester);
    await import(tester, provider, [file('a.md', 'Lesson 1')]);
    await import(tester, provider, [file('b.md', 'Lesson 1')]);
    final [first, second] = inUnit1(provider);
    second.title = 'Lesson 1';

    Future<void> say(Lesson lesson, String text, int minute) => tester.runAsync(
      () => provider.addAiDiscussionMessage(
        LessonAiPrompt.discussionId(lesson.id),
        AiDiscussionMessage(
          role: 'user',
          content: text,
          createdAt: DateTime.utc(2026, 1, 1, 0, minute),
        ),
      ),
    );
    await say(first, 'first, early', 1);
    await say(second, 'second, middle', 2);
    await say(first, 'first, late', 3);

    await tester.runAsync(
      () => provider.resolveLessonNameClash(
        provider.lessonNameClashes.single,
        LessonClashChoice.keepExisting,
      ),
    );

    expect(inUnit1(provider).single, same(first));
    expect(
      provider
          .getAiDiscussion(LessonAiPrompt.discussionId(first.id))
          .map((message) => message.content),
      ['first, early', 'second, middle', 'first, late'],
    );
    expect(
      provider.getAiDiscussion(LessonAiPrompt.discussionId(second.id)),
      isEmpty,
    );
  });
}
