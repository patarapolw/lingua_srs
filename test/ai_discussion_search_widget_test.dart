import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/ai_discussion_message.dart';
import 'package:lingua_srs/models/lesson.dart';
import 'package:lingua_srs/models/vocab_item.dart';
import 'package:lingua_srs/providers/app_provider.dart';
import 'package:lingua_srs/services/audio_service.dart';
import 'package:lingua_srs/services/lesson_ai_prompt.dart';
import 'package:lingua_srs/services/storage_service.dart';
import 'package:lingua_srs/views/ai_discussion_dialog.dart';
import 'package:lingua_srs/views/recent_ai_discussions_view.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Neither screen under test may touch real audio plugins.
class _FakeAudioService extends ChangeNotifier implements AudioService {
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

final _base = DateTime(2026, 1, 10, 12);

AiDiscussionMessage _msg(String role, String content, int minutes) =>
    AiDiscussionMessage(
      role: role,
      content: content,
      createdAt: _base.add(Duration(minutes: minutes)),
    );

VocabItem _word(String id, String ko, String en) =>
    VocabItem(id: id, targetWord: ko, translation: en, pos: 'nouns');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory storageDirectory;

  setUp(() {
    storageDirectory = Directory.systemTemp.createTempSync(
      'lingua_srs_ai_discussion_widget_test_',
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

  /// A provider holding three words and the given saved discussions.
  Future<(AppProvider, Lesson)> loadedProvider(
    WidgetTester tester, {
    Map<String, List<AiDiscussionMessage>> discussions = const {},
  }) async {
    SharedPreferences.setMockInitialValues({
      'lingua_srs_windows_legacy_migration_complete': true,
      'lingua_srs_lessons': '[]',
      'lingua_srs_sentences': '[]',
    });
    await tester.runAsync(() => StorageService.saveAiDiscussions(discussions));
    final provider = AppProvider();
    addTearDown(provider.dispose);
    for (var i = 0; i < 100 && provider.isLoading; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(
      provider.isLoading,
      isFalse,
      reason: 'provider never finished loading',
    );
    final lesson = Lesson(
      title: 'Words',
      vocabularies: [
        _word('v-apple', '사과', 'apple'),
        _word('v-twin', '애플', 'apple'),
        _word('v-eat', '먹다', 'to eat'),
        _word('v-school', '학교', 'school'),
      ],
    );
    provider.lessons
      ..clear()
      ..add(lesson);
    return (provider, lesson);
  }

  Future<void> pumpWith(
    WidgetTester tester,
    AppProvider provider,
    Widget home,
  ) async {
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
        child: MaterialApp(home: home),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  /// A discussion's title in the list. Plain find.text would also match the
  /// search box once its text equals the title.
  Finder title(String text) =>
      find.descendant(of: find.byType(ListTile), matching: find.text(text));

  group('Recent discussions search', () {
    final discussions = {
      'v-apple:no-sentence': [
        _msg('user', 'What is the nuance of this word?', 11),
        _msg('assistant', 'It also means the fruit.', 12),
      ],
      'v-eat:no-sentence': [
        _msg('user', 'Is there a polite form?', 30),
        _msg('assistant', 'Yes, the honorific form is 드시다.', 31),
      ],
      'v-school:no-sentence': [_msg('user', 'How do I use it?', 20)],
    };

    Future<AppProvider> open(WidgetTester tester) async {
      final (provider, _) = await loadedProvider(
        tester,
        discussions: discussions,
      );
      await pumpWith(tester, provider, const RecentAiDiscussionsView());
      return provider;
    }

    Future<void> search(WidgetTester tester, String text) async {
      await tester.enterText(find.byType(TextField), text);
      await tester.pump();
    }

    testWidgets('lists every saved discussion, newest first', (tester) async {
      await open(tester);

      final eat = tester.getTopLeft(title('먹다')).dy;
      final school = tester.getTopLeft(title('학교')).dy;
      final apple = tester.getTopLeft(title('사과')).dy;
      expect(eat, lessThan(school));
      expect(school, lessThan(apple));
    });

    testWidgets('has a search box', (tester) async {
      await open(tester);

      expect(find.byType(TextField), findsOneWidget);
      expect(find.byIcon(Icons.search), findsOneWidget);
    });

    testWidgets('filters by the Korean word', (tester) async {
      await open(tester);

      await search(tester, '사과');

      expect(title('사과'), findsOneWidget);
      expect(title('먹다'), findsNothing);
      expect(title('학교'), findsNothing);
    });

    testWidgets('filters by the meaning in English', (tester) async {
      await open(tester);

      await search(tester, 'school');

      expect(title('학교'), findsOneWidget);
      expect(title('사과'), findsNothing);
      expect(title('먹다'), findsNothing);
    });

    testWidgets('finds words that were only said in an answer', (tester) async {
      await open(tester);

      await search(tester, 'honorific');

      expect(title('먹다'), findsOneWidget);
      expect(title('사과'), findsNothing);
      expect(title('학교'), findsNothing);
    });

    testWidgets('says when nothing matches', (tester) async {
      await open(tester);

      await search(tester, 'zebra');

      expect(find.text('No discussions match "zebra".'), findsOneWidget);
      expect(title('사과'), findsNothing);
    });

    testWidgets('the clear button brings every discussion back', (
      tester,
    ) async {
      await open(tester);
      await search(tester, 'zebra');
      expect(find.byTooltip('Clear search'), findsOneWidget);

      await tester.tap(find.byTooltip('Clear search'));
      await tester.pump();

      expect(title('사과'), findsOneWidget);
      expect(title('먹다'), findsOneWidget);
      expect(title('학교'), findsOneWidget);
      expect(find.byTooltip('Clear search'), findsNothing);
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, isEmpty);
    });

    testWidgets('has no clear button while the box is empty', (tester) async {
      await open(tester);

      expect(find.byTooltip('Clear search'), findsNothing);
    });

    testWidgets('tapping a result opens its discussion', (tester) async {
      await open(tester);
      await search(tester, '사과');

      await tester.tap(title('사과'));
      await tester.pumpAndSettle();

      expect(find.byType(AiDiscussionDialog), findsOneWidget);
      expect(find.text('Ask AI'), findsOneWidget);
    });

    testWidgets('a deleted word still shows its discussion', (tester) async {
      final (provider, _) = await loadedProvider(
        tester,
        discussions: {
          'gone:no-sentence': [_msg('user', 'Remember this?', 1)],
        },
      );
      await pumpWith(tester, provider, const RecentAiDiscussionsView());

      expect(find.text('AI discussion'), findsOneWidget);

      await search(tester, 'remember');
      expect(find.text('AI discussion'), findsOneWidget);
    });

    testWidgets('with nothing saved there is no search box', (tester) async {
      final (provider, _) = await loadedProvider(tester);
      await pumpWith(tester, provider, const RecentAiDiscussionsView());

      expect(find.text('No discussions yet'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
    });
  });

  group('Earlier discussions in the dialog', () {
    Future<void> openDialog(
      WidgetTester tester,
      AppProvider provider,
      String discussionId, {
      String targetWord = '사과',
      String translation = 'apple',
      Lesson? lesson,
    }) async {
      await pumpWith(
        tester,
        provider,
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => AiDiscussionDialog(
                  discussionId: discussionId,
                  targetWord: targetWord,
                  translation: translation,
                  targetLanguage: 'ko',
                  nativeLanguage: 'en',
                  lesson: lesson,
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    final sameWord = [
      _msg('user', 'Why 사과 and not 능금?', 1),
      _msg('assistant', 'Because it is the common word.', 2),
    ];
    final related = [_msg('user', 'Is 애플 a loanword?', 3)];

    testWidgets('lists other discussions about the same word', (tester) async {
      final (provider, _) = await loadedProvider(
        tester,
        discussions: {'v-apple:old': sameWord},
      );

      await openDialog(tester, provider, 'v-apple:new');

      expect(find.text('Earlier discussions'), findsOneWidget);
      expect(find.text('Same word'), findsOneWidget);
      // The dialog header says the same, so look inside the tile.
      expect(
        find.descendant(
          of: find.byType(ListTile),
          matching: find.text('사과 — apple'),
        ),
        findsOneWidget,
      );
      expect(find.text('Why 사과 and not 능금?'), findsOneWidget);
    });

    testWidgets('lists the discussion of a related word', (tester) async {
      final (provider, _) = await loadedProvider(
        tester,
        discussions: {'v-twin:old': related},
      );

      await openDialog(tester, provider, 'v-apple:new');

      expect(find.text('Earlier discussions'), findsOneWidget);
      expect(find.text('Same meaning'), findsOneWidget);
      expect(find.text('애플 — apple'), findsOneWidget);
    });

    testWidgets('puts the same word before a related one', (tester) async {
      final (provider, _) = await loadedProvider(
        tester,
        discussions: {'v-twin:old': related, 'v-apple:old': sameWord},
      );

      await openDialog(tester, provider, 'v-apple:new');

      final same = tester.getTopLeft(find.text('Same word')).dy;
      final meaning = tester.getTopLeft(find.text('Same meaning')).dy;
      expect(same, lessThan(meaning));
    });

    testWidgets('does not list an unrelated word', (tester) async {
      final (provider, _) = await loadedProvider(
        tester,
        discussions: {
          'v-school:old': [_msg('user', 'How is 학교 used?', 4)],
        },
      );

      await openDialog(tester, provider, 'v-apple:new');

      expect(find.text('Earlier discussions'), findsNothing);
      expect(find.text('Try asking'), findsOneWidget);
    });

    testWidgets('shows nothing extra when there are no earlier discussions', (
      tester,
    ) async {
      final (provider, _) = await loadedProvider(tester);

      await openDialog(tester, provider, 'v-apple:new');

      expect(find.text('Earlier discussions'), findsNothing);
      expect(find.text('Try asking'), findsOneWidget);
    });

    testWidgets('a discussion that already has messages offers none', (
      tester,
    ) async {
      final (provider, _) = await loadedProvider(
        tester,
        discussions: {
          'v-apple:old': sameWord,
          'v-apple:other': [_msg('user', 'Another question', 5)],
        },
      );

      await openDialog(tester, provider, 'v-apple:old');

      expect(find.text('Earlier discussions'), findsNothing);
      expect(find.byTooltip('Delete saved discussion'), findsOneWidget);
    });

    testWidgets('a lesson discussion offers none', (tester) async {
      final (provider, lesson) = await loadedProvider(
        tester,
        discussions: {'v-apple:old': sameWord},
      );

      await openDialog(
        tester,
        provider,
        LessonAiPrompt.discussionId(lesson.id),
        targetWord: lesson.displayTitle,
        translation: '',
        lesson: lesson,
      );

      expect(find.text('Earlier discussions'), findsNothing);
    });

    testWidgets('tapping one opens that discussion in place', (tester) async {
      final (provider, _) = await loadedProvider(
        tester,
        discussions: {'v-apple:old': sameWord},
      );
      await openDialog(tester, provider, 'v-apple:new');

      await tester.tap(find.text('Why 사과 and not 능금?'));
      await tester.pumpAndSettle();

      // Replaced, not stacked on top of the empty one.
      expect(find.byType(AiDiscussionDialog), findsOneWidget);
      expect(find.text('Earlier discussions'), findsNothing);
      expect(find.byTooltip('Delete saved discussion'), findsOneWidget);
    });

    testWidgets('the replaced dialog closes with one tap', (tester) async {
      final (provider, _) = await loadedProvider(
        tester,
        discussions: {'v-apple:old': sameWord},
      );
      await openDialog(tester, provider, 'v-apple:new');
      await tester.tap(find.text('Why 사과 and not 능금?'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();

      expect(find.byType(AiDiscussionDialog), findsNothing);
    });
  });
}
