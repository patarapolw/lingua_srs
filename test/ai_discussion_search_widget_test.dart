import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/ai_discussion_message.dart';
import 'package:lingua_srs/models/lesson.dart';
import 'package:lingua_srs/models/vocab_item.dart';
import 'package:lingua_srs/providers/app_provider.dart';
import 'package:lingua_srs/services/audio_service.dart';
import 'package:lingua_srs/services/tts_voice.dart';
import 'package:lingua_srs/services/lesson_ai_prompt.dart';
import 'package:lingua_srs/services/storage_service.dart';
import 'package:lingua_srs/services/yaml_parser_service.dart';
import 'package:lingua_srs/views/ai_discussion_dialog.dart';
import 'package:lingua_srs/views/recent_ai_discussions_view.dart';
import 'package:lingua_srs/views/yaml_import_view.dart';
import 'package:lingua_srs/widgets/ai_question_chip.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'secret_storage_mock.dart';

/// Neither screen under test may touch real audio plugins.
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
  setUp(setUpSecretStorage);
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
    // Added after loading: discussions in storage are joined into one per
    // word on load, but these tests need several about the same word.
    await tester.runAsync(() async {
      for (final entry in discussions.entries) {
        for (final message in entry.value) {
          await provider.addAiDiscussionMessage(entry.key, message);
        }
      }
    });
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
    Widget home, {
    Size size = const Size(1200, 2400),
  }) async {
    tester.view.physicalSize = size;
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

    testWidgets('looks like the search boxes of the pool tabs', (tester) async {
      await open(tester);

      final decoration = tester
          .widget<TextField>(find.byType(TextField))
          .decoration!;
      expect(decoration.hintText, 'Search vocab, sentences or answers');
      final border = decoration.border! as OutlineInputBorder;
      expect(border.borderRadius, BorderRadius.circular(12));
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

    testWidgets('a row with an old date does not overflow on a phone', (
      tester,
    ) async {
      // Old dates print as 1/10/2026, which the test font draws wider than a
      // narrow trailing slot; the date must not have to fit there.
      final (provider, _) = await loadedProvider(
        tester,
        discussions: discussions,
      );
      await pumpWith(
        tester,
        provider,
        const RecentAiDiscussionsView(),
        size: const Size(320, 640),
      );

      expect(tester.takeException(), isNull);
      expect(title('사과'), findsOneWidget);
      expect(find.text('1/10/2026'), findsNWidgets(3));
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

      expect(find.text('Word not found'), findsOneWidget);

      await search(tester, 'remember');
      expect(find.text('Word not found'), findsOneWidget);
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
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Wrap &&
              widget.children.any((child) => child is AiQuestionChip) &&
              widget.alignment == WrapAlignment.center,
        ),
        findsOneWidget,
      );
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
      expect(find.byTooltip('More'), findsOneWidget);
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
      expect(find.byTooltip('More'), findsOneWidget);
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

    testWidgets('tapping a suggested question fills the composer', (
      tester,
    ) async {
      final (provider, _) = await loadedProvider(tester);
      await openDialog(tester, provider, 'v-apple:new');
      const question = 'Is "사과" Sino-Korean (Hanja) or native Korean?';

      await tester.tap(find.text(question));
      await tester.pumpAndSettle();

      final composer = tester.widget<TextField>(
        find.descendant(
          of: find.byType(AiDiscussionDialog),
          matching: find.byType(TextField),
        ),
      );
      expect(composer.controller!.text, question);
      expect(provider.getAiDiscussion('v-apple:new'), isEmpty);
      expect(
        find.text('Add your DeepSeek API key in settings first.'),
        findsNothing,
      );
    });

    testWidgets('sending from the composer dismisses the keyboard', (
      tester,
    ) async {
      final (provider, _) = await loadedProvider(tester);
      await openDialog(tester, provider, 'v-apple:new');
      final composer = find.descendant(
        of: find.byType(AiDiscussionDialog),
        matching: find.byType(TextField),
      );
      await tester.showKeyboard(composer);
      await tester.enterText(composer, 'What does it mean?');
      expect(tester.testTextInput.isVisible, isTrue);

      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();

      expect(tester.testTextInput.isVisible, isFalse);
      expect(tester.widget<TextField>(composer).focusNode!.hasFocus, isFalse);
      expect(
        find.text('Add your DeepSeek API key in settings first.'),
        findsOneWidget,
      );
    });

    testWidgets('sending collapses suggested questions', (tester) async {
      final (provider, _) = await loadedProvider(
        tester,
        discussions: {
          'v-apple:new': [
            _msg('user', 'What is 사과?', 1),
            _msg('assistant', 'It means apple.', 2),
          ],
        },
      );
      await openDialog(tester, provider, 'v-apple:new');
      expect(find.byType(AiQuestionChip), findsWidgets);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Wrap &&
              widget.children.any((child) => child is AiQuestionChip) &&
              widget.alignment == WrapAlignment.center,
        ),
        findsOneWidget,
      );

      final composer = find.descendant(
        of: find.byType(AiDiscussionDialog),
        matching: find.byType(TextField),
      );
      await tester.enterText(composer, 'What else can it mean?');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();

      expect(find.byType(AiQuestionChip), findsNothing);
      expect(find.text('Suggested next questions'), findsOneWidget);
    });
  });

  group('Related discussions panel', () {
    final current = [_msg('user', 'Current question', 1)];
    final older = [
      _msg('user', 'Why 사과 and not 능금?', 2),
      _msg('assistant', 'Because it is the common word.', 3),
    ];
    final twin = [_msg('user', 'Is 애플 a loanword?', 4)];
    final school = [_msg('user', 'How is 학교 used?', 5)];
    final mention = [_msg('user', 'Compare with 사과 please', 6)];
    final saved = {
      'v-apple:cur': current,
      'v-apple:old': older,
      'v-twin:old': twin,
      'v-school:old': school,
      'v-school:mention': mention,
    };

    Future<void> openChat(
      WidgetTester tester,
      AppProvider provider,
      String discussionId, {
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
                  targetWord: lesson?.displayTitle ?? '사과',
                  translation: lesson == null ? 'apple' : '',
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

    Finder inSheet(Finder finder) =>
        find.descendant(of: find.byType(BottomSheet), matching: finder);

    Future<void> openPanel(WidgetTester tester) async {
      await tester.tap(find.byTooltip('Related discussions'));
      await tester.pumpAndSettle();
    }

    Future<AppProvider> chatWithPanel(
      WidgetTester tester, {
      Map<String, List<AiDiscussionMessage>>? discussions,
      String id = 'v-apple:cur',
    }) async {
      final (provider, _) = await loadedProvider(
        tester,
        discussions: discussions ?? saved,
      );
      await openChat(tester, provider, id);
      await openPanel(tester);
      return provider;
    }

    testWidgets('an empty chat has the button', (tester) async {
      final (provider, _) = await loadedProvider(tester);
      await openChat(tester, provider, 'v-apple:new');

      expect(find.byTooltip('Related discussions'), findsOneWidget);
    });

    testWidgets('a chat with messages has it too', (tester) async {
      final (provider, _) = await loadedProvider(tester, discussions: saved);
      await openChat(tester, provider, 'v-apple:cur');

      expect(find.byTooltip('Related discussions'), findsOneWidget);
    });

    testWidgets('a lesson chat has none', (tester) async {
      final (provider, lesson) = await loadedProvider(tester);
      await openChat(
        tester,
        provider,
        LessonAiPrompt.discussionId(lesson.id),
        lesson: lesson,
      );

      expect(find.byTooltip('Related discussions'), findsNothing);
    });

    testWidgets('opens with the search box showing the word', (tester) async {
      await chatWithPanel(tester);

      expect(inSheet(find.text('Related discussions')), findsOneWidget);
      final field = tester.widget<TextField>(inSheet(find.byType(TextField)));
      expect(field.controller!.text, '사과');
    });

    testWidgets('lists the suggestions without typing anything', (
      tester,
    ) async {
      await chatWithPanel(tester);

      expect(inSheet(find.text('Same word')), findsOneWidget);
      expect(inSheet(find.text('Why 사과 and not 능금?')), findsOneWidget);
      expect(inSheet(find.text('Same meaning')), findsOneWidget);
      expect(inSheet(find.text('애플 — apple')), findsOneWidget);
      // Another word that only mentions it comes after, unlabelled.
      expect(inSheet(find.text('Compare with 사과 please')), findsOneWidget);
      // Neither an unrelated word nor the chat being viewed.
      expect(inSheet(find.text('How is 학교 used?')), findsNothing);
      expect(inSheet(find.text('Current question')), findsNothing);
    });

    testWidgets('editing the search turns it into a plain search', (
      tester,
    ) async {
      await chatWithPanel(tester);

      await tester.enterText(inSheet(find.byType(TextField)), 'school');
      await tester.pump();

      expect(inSheet(find.text('How is 학교 used?')), findsOneWidget);
      expect(inSheet(find.text('Compare with 사과 please')), findsOneWidget);
      expect(inSheet(find.text('Is 애플 a loanword?')), findsNothing);
      expect(inSheet(find.text('Same word')), findsNothing);
    });

    testWidgets('clearing the search lists every other discussion', (
      tester,
    ) async {
      await chatWithPanel(tester);

      await tester.tap(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.byTooltip('Clear search'),
        ),
      );
      await tester.pump();

      for (final preview in [
        'Why 사과 and not 능금?',
        'Is 애플 a loanword?',
        'How is 학교 used?',
        'Compare with 사과 please',
      ]) {
        expect(inSheet(find.text(preview)), findsOneWidget, reason: preview);
      }
      expect(inSheet(find.text('Current question')), findsNothing);
      final field = tester.widget<TextField>(inSheet(find.byType(TextField)));
      expect(field.controller!.text, isEmpty);
    });

    testWidgets('says when nothing is related yet', (tester) async {
      await chatWithPanel(tester, discussions: {'v-apple:cur': current});

      expect(
        inSheet(find.textContaining('No related discussions yet')),
        findsOneWidget,
      );
    });

    testWidgets('says when a search finds nothing', (tester) async {
      await chatWithPanel(tester);

      await tester.enterText(inSheet(find.byType(TextField)), 'zebra');
      await tester.pump();

      expect(
        inSheet(find.text('No discussions match "zebra".')),
        findsOneWidget,
      );
    });

    testWidgets('picking one opens it on top of this chat', (tester) async {
      await chatWithPanel(tester);

      await tester.tap(inSheet(find.text('Is 애플 a loanword?')));
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byType(AiDiscussionDialog), findsNWidgets(2));
    });

    testWidgets('closing the opened one comes back to this chat', (
      tester,
    ) async {
      await chatWithPanel(tester);
      await tester.tap(inSheet(find.text('Is 애플 a loanword?')));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Close').last);
      await tester.pumpAndSettle();

      expect(find.byType(AiDiscussionDialog), findsOneWidget);
      expect(find.text('Current question'), findsOneWidget);
    });
  });

  group('Dialog header buttons', () {
    final saved = [
      _msg('user', 'About the apple', 1),
      _msg('assistant', 'It is a fruit.', 2),
    ];

    Future<void> openChat(
      WidgetTester tester,
      AppProvider provider,
      String discussionId, {
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
                  targetWord: lesson?.displayTitle ?? '사과',
                  translation: lesson == null ? 'apple' : '',
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

    Future<void> chooseDelete(WidgetTester tester) async {
      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete discussion'));
      await tester.pumpAndSettle();
    }

    testWidgets('has no key button, which opened all of the settings', (
      tester,
    ) async {
      final (provider, _) = await loadedProvider(
        tester,
        discussions: {'v-apple:cur': saved},
      );
      await openChat(tester, provider, 'v-apple:cur');

      expect(find.byTooltip('DeepSeek settings'), findsNothing);
      expect(find.byIcon(Icons.key_outlined), findsNothing);
    });

    testWidgets('an empty chat has nothing to delete, so no More button', (
      tester,
    ) async {
      final (provider, _) = await loadedProvider(tester);
      await openChat(tester, provider, 'v-apple:new');

      expect(find.byTooltip('Related discussions'), findsOneWidget);
      expect(find.byTooltip('Close'), findsOneWidget);
      expect(find.byTooltip('More'), findsNothing);
    });

    testWidgets('delete is hidden in More, not a header button', (
      tester,
    ) async {
      final (provider, _) = await loadedProvider(
        tester,
        discussions: {'v-apple:cur': saved},
      );
      await openChat(tester, provider, 'v-apple:cur');

      expect(find.byTooltip('More'), findsOneWidget);
      expect(find.byTooltip('Delete saved discussion'), findsNothing);
      expect(find.byIcon(Icons.delete_outline), findsNothing);
      expect(find.text('Delete discussion'), findsNothing);

      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();

      expect(find.text('Delete discussion'), findsOneWidget);
    });

    testWidgets('Cancel keeps the discussion', (tester) async {
      final (provider, _) = await loadedProvider(
        tester,
        discussions: {'v-apple:cur': saved},
      );
      await openChat(tester, provider, 'v-apple:cur');

      await chooseDelete(tester);
      expect(find.text('Delete this discussion?'), findsOneWidget);
      expect(
        find.text(
          'The saved AI conversation about "사과" will be permanently deleted.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(provider.getAiDiscussion('v-apple:cur'), hasLength(2));
      expect(find.byTooltip('More'), findsOneWidget);
    });

    testWidgets('deleting empties the chat and keeps the dialog open', (
      tester,
    ) async {
      final (provider, _) = await loadedProvider(
        tester,
        discussions: {'v-apple:cur': saved},
      );
      await openChat(tester, provider, 'v-apple:cur');

      await chooseDelete(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(provider.getAiDiscussion('v-apple:cur'), isEmpty);
      expect(find.byType(AiDiscussionDialog), findsOneWidget);
      expect(find.byTooltip('More'), findsNothing);
      expect(
        find.text('Ask a question about this word or sentence.'),
        findsOneWidget,
      );
    });

    testWidgets('a lesson chat names the lesson in the confirmation', (
      tester,
    ) async {
      final (provider, lesson) = await loadedProvider(tester);
      final id = LessonAiPrompt.discussionId(lesson.id);
      await tester.runAsync(
        () => provider.addAiDiscussionMessage(id, _msg('user', 'Summarise', 1)),
      );
      await openChat(tester, provider, id, lesson: lesson);

      await chooseDelete(tester);

      expect(
        find.text(
          'The saved AI conversation about the lesson '
          '"${lesson.displayTitle}" will be permanently deleted.',
        ),
        findsOneWidget,
      );
    });
  });

  group('Deleting a discussion', () {
    final discussions = {
      'v-apple:no-sentence': [_msg('user', 'About the apple', 11)],
      'v-eat:no-sentence': [_msg('user', 'About eating', 30)],
    };

    Future<AppProvider> open(
      WidgetTester tester, [
      Map<String, List<AiDiscussionMessage>>? saved,
    ]) async {
      final (provider, _) = await loadedProvider(
        tester,
        discussions: saved ?? discussions,
      );
      await pumpWith(tester, provider, const RecentAiDiscussionsView());
      return provider;
    }

    /// Opens a discussion from the list, and deletes it from its More menu.
    Future<void> deleteFromInside(WidgetTester tester, String word) async {
      await tester.tap(title(word));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete discussion'));
      await tester.pumpAndSettle();
    }

    Future<void> confirm(WidgetTester tester) async {
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
    }

    Future<void> closeDialog(WidgetTester tester) async {
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
    }

    testWidgets('the list has no delete buttons', (tester) async {
      await open(tester);

      expect(find.byTooltip('Delete discussion'), findsNothing);
      expect(find.byIcon(Icons.delete_outline), findsNothing);
    });

    final panel = find.byIcon(Icons.delete_outline);

    testWidgets('a swipe reveals a limited Delete button without asking', (
      tester,
    ) async {
      await open(tester);
      final appleCard = find.ancestor(
        of: title('사과'),
        matching: find.byType(Card),
      );
      final before = tester.getTopLeft(appleCard).dx;

      await tester.drag(title('사과'), const Offset(-500, 0));
      await tester.pumpAndSettle();

      final moved = before - tester.getTopLeft(appleCard).dx;
      expect(moved, 96);
      expect(panel, findsOneWidget);
      expect(find.text('Delete this discussion?'), findsNothing);
    });

    testWidgets('a short swipe springs back', (tester) async {
      await open(tester);

      await tester.drag(title('사과'), const Offset(-20, 0));
      await tester.pumpAndSettle();

      expect(panel, findsNothing);
      expect(find.text('Delete this discussion?'), findsNothing);
    });

    testWidgets('tapping the open row closes it instead of opening it', (
      tester,
    ) async {
      await open(tester);

      await tester.drag(title('사과'), const Offset(-500, 0));
      await tester.pumpAndSettle();
      await tester.tap(title('사과'), warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(panel, findsNothing);
      expect(find.byTooltip('More'), findsNothing);
    });

    testWidgets('pressing a different row puts the swiped row back', (
      tester,
    ) async {
      await open(tester);

      await tester.drag(title('사과'), const Offset(-500, 0));
      await tester.pumpAndSettle();
      expect(panel, findsOneWidget);

      await tester.drag(title('먹다'), const Offset(-500, 0));
      await tester.pumpAndSettle();
      expect(panel, findsOneWidget);
      final eatCard = find.ancestor(
        of: title('먹다'),
        matching: find.byType(Card),
      );
      final appleCard = find.ancestor(
        of: title('사과'),
        matching: find.byType(Card),
      );
      expect(
        tester.getTopLeft(appleCard).dx,
        isNot(lessThan(tester.getTopLeft(eatCard).dx + 1)),
      );

      await tester.tap(title('사과'));
      await tester.pumpAndSettle();
      expect(panel, findsNothing);
    });

    testWidgets('pressing the Delete button asks before deleting', (
      tester,
    ) async {
      final provider = await open(tester);

      await tester.drag(title('사과'), const Offset(-500, 0));
      await tester.pumpAndSettle();
      await tester.tap(panel);
      await tester.pumpAndSettle();

      expect(find.text('Delete this discussion?'), findsOneWidget);
      expect(
        find.text(
          'The saved AI conversation about "사과" will be permanently deleted.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(title('사과'), findsOneWidget);
      expect(panel, findsNothing);
      expect(provider.aiDiscussions.keys, contains('v-apple:no-sentence'));
    });

    testWidgets('confirming deletes the discussion', (tester) async {
      final provider = await open(tester);

      await tester.drag(title('사과'), const Offset(-500, 0));
      await tester.pumpAndSettle();
      await tester.tap(panel);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(title('사과'), findsNothing);
      expect(title('먹다'), findsOneWidget);
      expect(provider.aiDiscussions.keys, ['v-eat:no-sentence']);
      final stored = await tester.runAsync(StorageService.loadAiDiscussions);
      expect(stored!.keys, ['v-eat:no-sentence']);
    });
    testWidgets('a discussion is deleted from inside it', (tester) async {
      final provider = await open(tester);

      await deleteFromInside(tester, '사과');
      expect(find.text('Delete this discussion?'), findsOneWidget);
      await confirm(tester);
      await closeDialog(tester);

      expect(title('사과'), findsNothing);
      expect(title('먹다'), findsOneWidget);
      expect(provider.aiDiscussions.keys, ['v-eat:no-sentence']);
      final stored = await tester.runAsync(StorageService.loadAiDiscussions);
      expect(stored!.keys, ['v-eat:no-sentence']);
    });

    testWidgets('Cancel keeps the discussion', (tester) async {
      final provider = await open(tester);

      await deleteFromInside(tester, '사과');
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      await closeDialog(tester);

      expect(provider.aiDiscussions.keys, hasLength(2));
      expect(title('사과'), findsOneWidget);
    });

    testWidgets('deleting the last one shows the empty state', (tester) async {
      await open(tester, {
        'v-apple:no-sentence': [_msg('user', 'About the apple', 11)],
      });

      await deleteFromInside(tester, '사과');
      await confirm(tester);
      await closeDialog(tester);

      expect(find.text('No discussions yet'), findsOneWidget);
    });

    testWidgets('deleting while searching keeps the search', (tester) async {
      await open(tester);
      await tester.enterText(find.byType(TextField), '사과');
      await tester.pump();

      await deleteFromInside(tester, '사과');
      await confirm(tester);
      await closeDialog(tester);

      expect(find.text('No discussions match "사과".'), findsOneWidget);
      expect(find.text('먹다'), findsNothing);
    });

    testWidgets('a word that is gone is labelled and can be deleted', (
      tester,
    ) async {
      final provider = await open(tester, {
        'gone:no-sentence': [_msg('user', 'Remember this?', 1)],
      });

      expect(find.text('Word not found'), findsOneWidget);
      await deleteFromInside(tester, 'Word not found');
      expect(
        find.textContaining('a word that no longer exists'),
        findsOneWidget,
      );
      await confirm(tester);

      // Nothing is left to read about a word that is gone, so it closes.
      expect(provider.aiDiscussions, isEmpty);
      expect(find.byType(AiDiscussionDialog), findsNothing);
      expect(find.text('No discussions yet'), findsOneWidget);
    });

    testWidgets('a lesson that is gone is labelled and can be deleted', (
      tester,
    ) async {
      final provider = await open(tester, {
        LessonAiPrompt.discussionId('missing'): [
          _msg('user', 'Summarise it', 1),
        ],
      });

      expect(find.text('Lesson not found'), findsOneWidget);
      await deleteFromInside(tester, 'Lesson not found');
      expect(
        find.textContaining('a lesson that no longer exists'),
        findsOneWidget,
      );
      await confirm(tester);

      expect(provider.aiDiscussions, isEmpty);
      expect(find.byType(AiDiscussionDialog), findsNothing);
    });

    testWidgets('a word that is gone still opens, with a clear title', (
      tester,
    ) async {
      await open(tester, {
        'gone:no-sentence': [_msg('user', 'Remember this?', 1)],
      });

      await tester.tap(find.text('Word not found'));
      await tester.pumpAndSettle();

      expect(find.byType(AiDiscussionDialog), findsOneWidget);
      expect(find.text('gone:no-sentence'), findsNothing);
    });

    testWidgets('deleting a lesson or word does not delete its chats', (
      tester,
    ) async {
      final (provider, lesson) = await loadedProvider(
        tester,
        discussions: {
          'v-apple:no-sentence': [_msg('user', 'About the apple', 11)],
          LessonAiPrompt.discussionId('lesson-1'): [
            _msg('user', 'Summarise it', 12),
          ],
        },
      );

      await tester.runAsync(() => provider.deleteLesson(lesson.id));

      expect(provider.aiDiscussions.keys, hasLength(2));
    });
  });

  group('Orphaned chats', () {
    final lessonGone = {
      LessonAiPrompt.discussionId('missing'): [
        _msg('user', 'Summarise it', 1),
        _msg('assistant', 'It is about fruit.', 2),
      ],
    };
    final wordGone = {
      'gone:no-sentence': [_msg('user', 'Remember this?', 1)],
    };

    Finder inDialog(Finder finder) =>
        find.descendant(of: find.byType(AiDiscussionDialog), matching: finder);

    Future<AppProvider> openFromList(
      WidgetTester tester,
      Map<String, List<AiDiscussionMessage>> saved,
      String title,
    ) async {
      final (provider, _) = await loadedProvider(tester, discussions: saved);
      await pumpWith(tester, provider, const RecentAiDiscussionsView());
      await tester.tap(find.text(title));
      await tester.pumpAndSettle();
      return provider;
    }

    testWidgets('a lesson that is gone opens its conversation read-only', (
      tester,
    ) async {
      await openFromList(tester, lessonGone, 'Lesson not found');

      expect(find.byType(AiDiscussionDialog), findsOneWidget);
      expect(inDialog(find.text('Summarise it')), findsOneWidget);
      expect(
        inDialog(
          find.textContaining(
            'This lesson no longer exists, so this chat is read-only',
          ),
        ),
        findsOneWidget,
      );
      expect(inDialog(find.byType(TextField)), findsNothing);
      expect(inDialog(find.byTooltip('Send question')), findsNothing);
    });

    testWidgets('a word that is gone opens read-only too', (tester) async {
      await openFromList(tester, wordGone, 'Word not found');

      expect(
        inDialog(
          find.textContaining(
            'This word no longer exists, so this chat is read-only',
          ),
        ),
        findsOneWidget,
      );
      expect(
        inDialog(
          find.widgetWithText(FilledButton, 'Continue without the word'),
        ),
        findsOneWidget,
      );
      expect(inDialog(find.byType(TextField)), findsNothing);
    });

    testWidgets('offers neither suggestions nor related discussions', (
      tester,
    ) async {
      await openFromList(tester, lessonGone, 'Lesson not found');

      expect(inDialog(find.text('Suggested next questions')), findsNothing);
      expect(inDialog(find.byTooltip('Related discussions')), findsNothing);
    });

    testWidgets('can be continued without the lesson', (tester) async {
      await openFromList(tester, lessonGone, 'Lesson not found');

      await tester.tap(
        inDialog(
          find.widgetWithText(FilledButton, 'Continue without the lesson'),
        ),
      );
      await tester.pumpAndSettle();

      expect(inDialog(find.byType(TextField)), findsOneWidget);
      expect(inDialog(find.byTooltip('Send question')), findsOneWidget);
      expect(inDialog(find.textContaining('read-only')), findsNothing);
      expect(
        inDialog(find.textContaining('cannot see the deleted lesson')),
        findsOneWidget,
      );
      expect(inDialog(find.text('Suggested next questions')), findsNothing);
    });

    testWidgets('a continued chat can send a question', (tester) async {
      await openFromList(tester, lessonGone, 'Lesson not found');
      await tester.tap(
        inDialog(
          find.widgetWithText(FilledButton, 'Continue without the lesson'),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(inDialog(find.byType(TextField)), 'And the rest?');
      await tester.tap(inDialog(find.byTooltip('Send question')));
      await tester.pumpAndSettle();

      // No API key is set in tests, so it stops at asking for one.
      expect(
        find.text('Add your DeepSeek API key in settings first.'),
        findsOneWidget,
      );
    });

    testWidgets('can still be deleted from inside, which closes it', (
      tester,
    ) async {
      final provider = await openFromList(
        tester,
        lessonGone,
        'Lesson not found',
      );

      await tester.tap(inDialog(find.byTooltip('More')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete discussion'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(provider.aiDiscussions, isEmpty);
      expect(find.byType(AiDiscussionDialog), findsNothing);
    });

    testWidgets('a chat whose word still exists is not read-only', (
      tester,
    ) async {
      await openFromList(tester, {
        'v-apple:no-sentence': [_msg('user', 'About the apple', 1)],
      }, '사과');

      expect(inDialog(find.textContaining('read-only')), findsNothing);
      expect(inDialog(find.byType(TextField)), findsOneWidget);
      expect(inDialog(find.byTooltip('Related discussions')), findsOneWidget);
    });
  });

  group('Vocabulary YAML in a chat', () {
    const yaml = 'vocabulary:\n  nouns:\n    - ko: "배"\n      en: "pear"\n';
    const answer = 'Try these:\n\n```yaml\n$yaml```\n';

    Future<void> openChat(
      WidgetTester tester,
      AppProvider provider,
      String discussionId, {
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
                  targetWord: lesson?.displayTitle ?? '사과',
                  translation: lesson == null ? 'apple' : '',
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

    testWidgets('a lesson chat opens it in the import screen to edit', (
      tester,
    ) async {
      final (provider, lesson) = await loadedProvider(tester);
      final id = LessonAiPrompt.discussionId(lesson.id);
      await tester.runAsync(() async {
        await provider.addAiDiscussionMessage(
          id,
          _msg('user', LessonAiPrompt.vocabularyQuestion, 1),
        );
        await provider.addAiDiscussionMessage(id, _msg('assistant', answer, 2));
      });
      await openChat(tester, provider, id, lesson: lesson);

      await tester.tap(find.text('Edit and add to lesson'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 301));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 500)),
      );
      await tester.pump();

      final view = tester.widget<YamlImportView>(find.byType(YamlImportView));
      expect(view.initialLessonName, 'Words');
      expect(view.initialYaml, yaml);
      expect(view.previewInitialYaml, isTrue);
      expect(view.vocabularyOnly, isTrue);
      expect(view.aiSuggested, isTrue);
      // Nothing is added until it is imported from there.
      expect(
        lesson.vocabularies.map((v) => v.targetWord),
        isNot(contains('배')),
      );
    });

    Future<void> openLessonChatWith(WidgetTester tester, String answer) async {
      final (provider, lesson) = await loadedProvider(tester);
      final id = LessonAiPrompt.discussionId(lesson.id);
      await tester.runAsync(
        () => provider.addAiDiscussionMessage(id, _msg('assistant', answer, 1)),
      );
      await openChat(tester, provider, id, lesson: lesson);
    }

    testWidgets('words already in a lesson are left out', (tester) async {
      // 사과 and 학교 are in the lesson; 배 is new.
      await openLessonChatWith(
        tester,
        '```yaml\n'
        'vocabulary:\n'
        '  nouns:\n'
        '    - ko: "사과"\n'
        '      en: "apple"\n'
        '    - ko: "배"\n'
        '      en: "pear"\n'
        '    - ko: "학교"\n'
        '      en: "school"\n'
        '```\n',
      );

      expect(
        find.textContaining('already in your lessons or listed twice'),
        findsOneWidget,
      );
      expect(find.textContaining('사과, 학교'), findsOneWidget);

      await tester.tap(find.text('Edit and add 1 new word'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 301));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 500)),
      );
      await tester.pump();

      final view = tester.widget<YamlImportView>(find.byType(YamlImportView));
      expect(view.initialYaml, yaml);
    });

    testWidgets('a word written the same with another meaning is kept', (
      tester,
    ) async {
      // The lesson has 사과 "apple"; 사과 "apology" may be another word.
      await openLessonChatWith(
        tester,
        '```yaml\n'
        'vocabulary:\n'
        '  nouns:\n'
        '    - ko: "사과"\n'
        '      en: "apology"\n'
        '```\n',
      );

      expect(
        find.text(
          'Possible duplicates (same word, another meaning): '
          '사과 "apology" (you have "apple")',
        ),
        findsOneWidget,
      );
      expect(find.text('Edit and add to lesson'), findsOneWidget);
    });

    testWidgets('words of a lesson in another language are not compared', (
      tester,
    ) async {
      final (provider, lesson) = await loadedProvider(tester);
      // The same characters can be another word in another language.
      provider.lessons.add(
        Lesson(
          title: 'Chinese',
          targetLanguage: 'zh',
          vocabularies: [_word('zh-1', '工夫', 'kung fu')],
        ),
      );
      final id = LessonAiPrompt.discussionId(lesson.id);
      await tester.runAsync(
        () => provider.addAiDiscussionMessage(
          id,
          _msg(
            'assistant',
            '```yaml\n'
                'vocabulary:\n'
                '  nouns:\n'
                '    - ko: "工夫"\n'
                '      en: "kung fu"\n'
                '```\n',
            1,
          ),
        ),
      );
      await openChat(tester, provider, id, lesson: lesson);

      expect(find.text('Edit and add to lesson'), findsOneWidget);
      expect(find.textContaining('already in your lessons'), findsNothing);
    });

    testWidgets('a noun whose 하다 verb is known is pointed out', (tester) async {
      final (provider, lesson) = await loadedProvider(tester);
      lesson.vocabularies.add(_word('v-study', '공부하다', 'to study'));
      final id = LessonAiPrompt.discussionId(lesson.id);
      await tester.runAsync(
        () => provider.addAiDiscussionMessage(
          id,
          _msg(
            'assistant',
            '```yaml\n'
                'vocabulary:\n'
                '  nouns:\n'
                '    - ko: "공부"\n'
                '      en: "study"\n'
                '    - ko: "배"\n'
                '      en: "pear"\n'
                '```\n',
            1,
          ),
        ),
      );
      await openChat(tester, provider, id, lesson: lesson);

      // It is only pointed out: both words are still offered.
      expect(
        find.text('Consider editing out: 공부 (you have 공부하다)'),
        findsOneWidget,
      );
      expect(find.text('Edit and add to lesson'), findsOneWidget);
    });

    testWidgets('an answer with only known words cannot be added', (
      tester,
    ) async {
      await openLessonChatWith(
        tester,
        '```yaml\n'
        'vocabulary:\n'
        '  nouns:\n'
        '    - ko: "사과"\n'
        '      en: "apple"\n'
        '```\n',
      );

      final button = tester.widget<OutlinedButton>(
        find.ancestor(
          of: find.text('Already in your lessons'),
          matching: find.byWidgetPredicate((w) => w is OutlinedButton),
        ),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('follows words added or edited after the answer', (
      tester,
    ) async {
      final (provider, lesson) = await loadedProvider(tester);
      final id = LessonAiPrompt.discussionId(lesson.id);
      await tester.runAsync(
        () => provider.addAiDiscussionMessage(
          id,
          _msg(
            'assistant',
            '```yaml\n'
                'vocabulary:\n'
                '  nouns:\n'
                '    - ko: "배"\n'
                '      en: "pear"\n'
                '    - ko: "포도"\n'
                '      en: "grape"\n'
                '```\n',
            1,
          ),
        ),
      );
      await openChat(tester, provider, id, lesson: lesson);
      expect(find.text('Edit and add to lesson'), findsOneWidget);

      // Added later: 배 is left out.
      await tester.runAsync(
        () =>
            provider.addVocabToLesson(lesson.id, _word('v-pear', '배', 'pear')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Edit and add 1 new word'), findsOneWidget);

      // Edited later, with as many words as before: 포도 is left out too.
      final school = lesson.vocabularies.firstWhere(
        (v) => v.targetWord == '학교',
      );
      school
        ..targetWord = '포도'
        ..translation = 'grape';
      await tester.runAsync(() => provider.updateVocab(school));
      await tester.pumpAndSettle();
      expect(find.text('Already in your lessons'), findsOneWidget);
    });

    testWidgets('words and new sentences get an AI note when added', (
      tester,
    ) async {
      final (provider, _) = await loadedProvider(tester);
      // A sentence the learner already has, with their own note.
      await tester.runAsync(
        () => provider.importParsedLessons([
          YamlParserService.parseLessonYaml(
            'vocabulary:\n'
            '  nouns:\n'
            '    - ko: "과일"\n'
            '      en: "fruit"\n'
            '      examples:\n'
            '        - ko: "**배**가 달아요."\n'
            '          en: "The pear is sweet."\n'
            '          notes: "Mine."\n',
            defaultTitle: 'Fruit',
          ),
        ]),
      );
      const yaml =
          'vocabulary:\n'
          '  nouns:\n'
          '    - ko: "배"\n'
          '      en: "pear"\n'
          '      examples:\n'
          '        - ko: "**배**가 달아요."\n'
          '          en: "The pear is sweet."\n'
          '        - ko: "**배**를 샀어요."\n'
          '          en: "I bought a pear."\n';
      // Opened over a page, as from the chat: it closes itself once added.
      await pumpWith(
        tester,
        provider,
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const YamlImportView(
                    initialLessonName: 'Words',
                    initialYaml: yaml,
                    previewInitialYaml: true,
                    vocabularyOnly: true,
                    aiSuggested: true,
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      // Not pumpAndSettle: the preview's progress bar runs while the YAML is
      // parsed on the real clock. These pumps open the page and start it.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 500)),
      );
      await tester.pump();
      expect(find.textContaining('Suggested by AI. Each word'), findsOneWidget);

      await tester.tap(find.text('Add Vocabulary').last);
      // The import yields to the fake clock between lessons and saves with
      // real I/O, so both have to run until it is done.
      bool added() => provider.lessons
          .expand((lesson) => lesson.vocabularies)
          .any((vocab) => vocab.targetWord == '배');
      for (var i = 0; i < 100 && !added(); i++) {
        await tester.pump(const Duration(milliseconds: 20));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
      }
      // Let the save after the import, and its snack bar, finish too.
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
      }
      expect(added(), isTrue, reason: 'the import never finished');
      // The screen has closed; the snack bar goes after a few seconds.
      await tester.pumpAndSettle();
      expect(find.byType(YamlImportView), findsNothing);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();

      final pear = provider.lessons
          .expand((lesson) => lesson.vocabularies)
          .singleWhere((vocab) => vocab.targetWord == '배');
      expect(pear.notes, LessonAiPrompt.aiWordNote);
      String notesOf(String target) => provider.sentences
          .singleWhere((sentence) => sentence.targetText == target)
          .notes;
      expect(notesOf('배를 샀어요.'), LessonAiPrompt.aiSentenceNote);
      expect(notesOf('배가 달아요.'), 'Mine.');
    });

    testWidgets('adds to a lesson from a file without asking about a clash', (
      tester,
    ) async {
      final (provider, _) = await loadedProvider(tester);
      // Imported from a folder: its virtual path is unit-1/words-1.md, not
      // the Lesson 1.md a typed name gives.
      await tester.runAsync(
        () => provider.importParsedLessons([
          YamlParserService.parseLessonYaml(
            '---\nvocabulary:\n  nouns:\n    - ko: "사과"\n'
            '      en: "apple"\n---\n# Lesson 1\n\nText.\n',
            defaultUnitTitle: 'Unit 1',
            sourcePath: 'unit-1/words-1.md',
          ),
        ]),
      );
      final lessonsBefore = provider.lessons.length;
      const yaml =
          'vocabulary:\n'
          '  nouns:\n'
          '    - ko: "배"\n'
          '      en: "pear"\n';
      await pumpWith(
        tester,
        provider,
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const YamlImportView(
                    initialLessonName: 'Unit 1::Lesson 1',
                    initialYaml: yaml,
                    previewInitialYaml: true,
                    vocabularyOnly: true,
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 500)),
      );
      await tester.pump();

      await tester.tap(find.text('Add Vocabulary').last);
      bool added() => provider.lessons
          .expand((lesson) => lesson.vocabularies)
          .any((vocab) => vocab.targetWord == '배');
      for (var i = 0; i < 100 && !added(); i++) {
        expect(find.text('Two lessons with one name'), findsNothing);
        await tester.pump(const Duration(milliseconds: 20));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
      }
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
      }
      expect(added(), isTrue, reason: 'the import never finished');
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();

      // Added to the same lesson, which keeps its file and text.
      expect(provider.lessons, hasLength(lessonsBefore));
      final lesson = provider.lessons.singleWhere(
        (lesson) => lesson.displayTitle == 'Lesson 1',
      );
      expect(lesson.vocabularies.map((vocab) => vocab.targetWord), ['사과', '배']);
      expect(lesson.fileName, 'words-1.md');
      expect(lesson.markdownContent, contains('Text.'));
    });

    testWidgets('a word chat has no button', (tester) async {
      final (provider, _) = await loadedProvider(
        tester,
        discussions: {
          'v-apple:yaml': [_msg('assistant', answer, 1)],
        },
      );
      await openChat(tester, provider, 'v-apple:yaml');

      expect(find.text('Edit and add to lesson'), findsNothing);
    });

    testWidgets('an answer without it has no button', (tester) async {
      final (provider, lesson) = await loadedProvider(tester);
      final id = LessonAiPrompt.discussionId(lesson.id);
      await tester.runAsync(
        () => provider.addAiDiscussionMessage(
          id,
          _msg('assistant', 'This lesson is about fruit.', 1),
        ),
      );
      await openChat(tester, provider, id, lesson: lesson);

      expect(find.text('Edit and add to lesson'), findsNothing);
    });
  });
}
