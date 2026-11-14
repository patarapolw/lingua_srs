import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/ai_discussion_message.dart';
import 'package:lingua_srs/models/lesson.dart';
import 'package:lingua_srs/models/vocab_item.dart';
import 'package:lingua_srs/providers/app_provider.dart';
import 'package:lingua_srs/services/lesson_ai_prompt.dart';
import 'package:lingua_srs/services/sync_records.dart';
import 'package:lingua_srs/services/yaml_parser_service.dart';
import 'package:lingua_srs/views/lesson_list_view.dart';
import 'package:provider/provider.dart';
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

  /// A provider, loaded from empty storage, or with [fresh] false from what
  /// an earlier one saved (as the app does when it starts again).
  Future<AppProvider> loadedProvider(
    WidgetTester tester, {
    bool fresh = true,
  }) async {
    if (fresh) {
      SharedPreferences.setMockInitialValues({
        'lingua_srs_windows_legacy_migration_complete': true,
      });
    }
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

  testWidgets('lessons and folders can be renamed from the lesson list', (
    tester,
  ) async {
    final provider = await loadedProvider(tester);
    await import(tester, provider, [file('a.md', 'Lesson 1')]);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppProvider>.value(
        value: provider,
        child: const MaterialApp(home: LessonListView()),
      ),
    );
    await tester.pumpAndSettle();

    final lessonMenu = find.descendant(
      of: find.widgetWithText(ListTile, 'Lesson 1'),
      matching: find.byType(PopupMenuButton<String>),
    );
    await tester.tap(lessonMenu);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename Lesson'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Renamed Lesson');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(provider.lessons.single.displayTitle, 'Renamed Lesson');

    await tester.tap(find.byTooltip('Manage Unit 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename folder'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Custom Unit');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(provider.lessons.single.folderPath, ['Custom Unit']);
  });

  testWidgets('renaming an imported folder keeps its source on re-import', (
    tester,
  ) async {
    final provider = await loadedProvider(tester);
    await import(tester, provider, [file('a.md', 'Lesson 1')]);
    final lesson = provider.lessons.single;

    await tester.runAsync(
      () => provider.renameLessonGroup(['Unit 1'], 'Custom Unit'),
    );
    final asked = await import(tester, provider, [
      file('a.md', 'Lesson 1 updated', word: '새 단어'),
    ]);

    expect(asked, 0);
    expect(provider.lessons, hasLength(1));
    expect(provider.lessons.single, same(lesson));
    expect(lesson.folderPath, ['Custom Unit']);
    expect(lesson.displayTitle, 'Lesson 1 updated');
  });

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

  group('lessons follow the paths of unchanged files', () {
    /// A file the import skipped as unchanged, at `unit-1/<name>`.
    Lesson skipped(String name, String title) =>
        YamlParserService.lessonFileInfo(
          '---\nvocabulary:\n---\n# $title\n',
          sourcePath: 'unit-1/$name',
          defaultUnitTitle: 'Unit 1',
        )!;

    Future<Lesson> legacy(
      WidgetTester tester,
      AppProvider provider,
      String title,
    ) async => (await tester.runAsync(
      () => provider.importYaml(
        '---\nvocabulary:\n---\n# $title\n',
        defaultUnitTitle: 'Unit 1',
      ),
    ))!;

    testWidgets('a lesson from before file paths takes its file\'s', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      final lesson = await legacy(tester, provider, 'Lesson 1');
      expect(lesson.fileName, isNull);

      final changed = (await tester.runAsync(
        () => provider.adoptFilePaths([skipped('lesson-1.md', 'Lesson 1')]),
      ))!;

      expect(changed, 1);
      expect(lesson.fileName, 'lesson-1.md');
      expect(lesson.fileFolder, 'unit-1');
      expect(lesson.virtualPath, ['unit-1', 'lesson-1.md']);
      // A second time changes nothing.
      expect(
        await tester.runAsync(
          () => provider.adoptFilePaths([skipped('lesson-1.md', 'Lesson 1')]),
        ),
        0,
      );
    });

    testWidgets('a lesson with that file name takes its folder names', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      await import(tester, provider, [file('a.md', 'Lesson 1')]);
      final lesson = inUnit1(provider).single..fileFolder = null;

      await tester.runAsync(
        () => provider.adoptFilePaths([skipped('a.md', 'Renamed heading')]),
      );

      expect(lesson.fileFolder, 'unit-1');
      expect(lesson.displayTitle, 'Lesson 1');
    });

    testWidgets('nothing is guessed when the match is not certain', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      // Two lessons the file could be (as an older version could keep them
      // side by side): neither takes it.
      final first = Lesson(title: 'Lesson 3: Food', unitTitle: 'Unit 1');
      final second = Lesson(title: 'Lesson 3: Drinks', unitTitle: 'Unit 1');
      provider.lessons.addAll([first, second]);
      // A lesson that already has another file keeps it.
      await import(tester, provider, [file('kept.md', 'Lesson 4')]);

      final changed = (await tester.runAsync(
        () => provider.adoptFilePaths([
          skipped('lesson-3.md', 'Lesson 3: Snacks'),
          skipped('other.md', 'Lesson 4'),
          skipped('nowhere.md', 'Lesson 9'),
        ]),
      ))!;

      expect(changed, 0);
      expect(first.fileName, isNull);
      expect(second.fileName, isNull);
      expect(
        inUnit1(provider)
            .firstWhere((l) => l.displayTitle == 'Lesson 4')
            .fileName,
        'kept.md',
      );
    });
  });

  group('saved lessons from one file', () {
    /// A copy of the lesson from `unit-1/a.md` as another device has it:
    /// another id, with [text] and the word [word].
    Map<SyncRecordKey, Map<String, dynamic>> pulledCopy(
      String text,
      String word,
    ) {
      final copy = Lesson(
        id: 'pulled',
        title: 'Lesson 1',
        unitTitle: 'Unit 1',
        fileName: 'a.md',
        fileFolder: 'unit-1',
        vocabularies: [
          VocabItem(targetWord: word, translation: 'two', pos: 'nouns'),
        ],
      );
      return {
        const SyncRecordKey(SyncKinds.lesson, 'pulled'): copy.toJson(),
        const SyncRecordKey(SyncKinds.lessonMarkdown, 'pulled'): {
          'markdown': text,
        },
      };
    }

    testWidgets('a pulled copy with the same text merges, with its chat', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      await import(tester, provider, [file('a.md', 'Lesson 1', word: '하나')]);
      final saved = inUnit1(provider).single;
      await tester.runAsync(
        () => provider.addAiDiscussionMessage(
          LessonAiPrompt.discussionId('pulled'),
          const AiDiscussionMessage(role: 'user', content: 'from the copy'),
        ),
      );

      await tester.runAsync(
        () => provider.apply(
          'other-device',
          pulledCopy(saved.markdownContent, '둘'),
        ),
      );

      final lesson = inUnit1(provider).single;
      expect(lesson, same(saved));
      expect(lesson.vocabularies.map((vocab) => vocab.targetWord).toSet(), {
        '하나',
        '둘',
      });
      expect(
        provider
            .getAiDiscussion(LessonAiPrompt.discussionId(saved.id))
            .map((message) => message.content),
        ['from the copy'],
      );
      expect(provider.lessonNameClashes, isEmpty);
    });

    testWidgets('a pulled copy with other text is left to sort out', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      await import(tester, provider, [file('a.md', 'Lesson 1', word: '하나')]);
      final saved = inUnit1(provider).single;

      await tester.runAsync(
        () => provider.apply(
          'other-device',
          pulledCopy('# Lesson 1\n\nEdited elsewhere.', '둘'),
        ),
      );

      // Nothing merged, so neither text is lost.
      expect(inUnit1(provider), hasLength(2));
      final clash = provider.lessonNameClashes.single;
      expect(clash.existing, same(saved));
      expect(clash.incoming.id, 'pulled');
      expect(clash.sameFile, isTrue);
      expect(clash.incoming.markdownContent, contains('Edited elsewhere.'));

      // Keeping both: the second lets go of the file and is renamed.
      await tester.runAsync(
        () =>
            provider.resolveLessonNameClash(clash, LessonClashChoice.keepBoth),
      );
      expect(clash.incoming.fileName, isNull);
      expect(clash.incoming.displayTitle, 'Lesson 1 (2)');
      expect(saved.fileName, 'a.md');
      expect(provider.lessonNameClashes, isEmpty);
    });

    testWidgets('lists a pair from one file even with different names', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      await import(tester, provider, [file('a.md', 'Lesson 1')]);
      provider.lessons.add(
        Lesson(
          title: 'Retitled',
          unitTitle: 'Unit 1',
          fileName: 'a.md',
          markdownContent: '# Retitled\n\nOther text.',
        ),
      );

      final clash = provider.lessonNameClashes.single;
      expect(clash.sameFile, isTrue);
      // Different names: keep both only lets go of the file.
      expect(clash.renamedTitle, 'Retitled');
      await tester.runAsync(
        () =>
            provider.resolveLessonNameClash(clash, LessonClashChoice.keepBoth),
      );
      expect(clash.incoming.displayTitle, 'Retitled');
      expect(clash.incoming.fileName, isNull);
      expect(provider.lessonNameClashes, isEmpty);
    });

    testWidgets('on start, merges copies only when no text is lost', (
      tester,
    ) async {
      final first = await loadedProvider(tester);
      await import(tester, first, [file('a.md', 'Lesson 1', word: '하나')]);
      await import(tester, first, [file('b.md', 'Lesson 2', word: '셋')]);
      final a = inUnit1(first).firstWhere((l) => l.fileName == 'a.md');
      final b = inUnit1(first).firstWhere((l) => l.fileName == 'b.md');
      first.lessons.addAll([
        // a.md again, with no text: merges.
        Lesson(
          title: 'Lesson 1',
          unitTitle: 'Unit 1',
          fileName: 'a.md',
          vocabularies: [
            VocabItem(targetWord: '둘', translation: 'two', pos: 'nouns'),
          ],
        ),
        // b.md again, with other text: kept, to sort out.
        Lesson(
          title: 'Lesson 2',
          unitTitle: 'Unit 1',
          fileName: 'b.md',
          markdownContent: '# Lesson 2\n\nOther text.',
        ),
      ]);
      await tester.runAsync(first.saveState);

      final started = await loadedProvider(tester, fresh: false);

      final lessons = inUnit1(started);
      expect(lessons.where((l) => l.fileName == 'a.md'), hasLength(1));
      final merged = lessons.singleWhere((l) => l.fileName == 'a.md');
      expect(merged.id, a.id);
      expect(merged.vocabularies.map((v) => v.targetWord).toSet(), {'하나', '둘'});
      expect(lessons.where((l) => l.fileName == 'b.md'), hasLength(2));
      final clash = started.lessonNameClashes.single;
      expect(clash.existing.id, b.id);
      expect(clash.sameFile, isTrue);
    });

    testWidgets('Sort out in the lesson list settles the pair', (tester) async {
      final provider = await loadedProvider(tester);
      await import(tester, provider, [file('a.md', 'Lesson 1', word: '하나')]);
      final saved = inUnit1(provider).single;
      await tester.runAsync(
        () => provider.apply(
          'other-device',
          pulledCopy('# Lesson 1\n\nEdited elsewhere.', '둘'),
        ),
      );
      await tester.pumpWidget(
        ChangeNotifierProvider<AppProvider>.value(
          value: provider,
          child: MaterialApp(
            home: Scaffold(
              body: LessonNameClashBanner(
                count: provider.lessonNameClashes.length,
              ),
            ),
          ),
        ),
      );
      expect(
        find.text(
          'A lesson has the same name or file as another in its folder.',
        ),
        findsOneWidget,
      );

      await tester.tap(find.text('Sort out'));
      await tester.pumpAndSettle();
      expect(find.text('Two lessons from one file'), findsOneWidget);
      await tester.tap(find.text('First lesson'));
      await tester.pump();
      // Keeping the first drops the copy's text, and the dialog says so.
      expect(
        find.textContaining('The second lesson’s text is not kept.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Continue'));
      for (var i = 0; i < 20 && provider.lessonNameClashes.isNotEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pumpAndSettle();

      expect(provider.lessonNameClashes, isEmpty);
      expect(find.text('Two lessons from one file'), findsNothing);
      expect(inUnit1(provider).single, same(saved));
      expect(saved.markdownContent, isNot(contains('Edited elsewhere.')));
    });
  });
}
