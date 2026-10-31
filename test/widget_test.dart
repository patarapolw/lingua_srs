import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lingua_srs/models/lesson.dart';
import 'package:lingua_srs/models/sentence.dart';
import 'package:lingua_srs/models/srs_card.dart';
import 'package:lingua_srs/models/vocab_item.dart';
import 'package:lingua_srs/services/audio_service.dart';
import 'package:lingua_srs/views/lesson_detail_view.dart';
import 'package:lingua_srs/views/similar_meanings_dialog.dart';
import 'package:lingua_srs/views/similar_search_dialog.dart';
import 'package:lingua_srs/views/study_view.dart';
import 'package:lingua_srs/views/vocab_edit_dialog.dart';
import 'package:lingua_srs/views/vocab_merge_dialogs.dart';
import 'package:lingua_srs/views/yaml_import_view.dart';
import 'package:lingua_srs/widgets/emphasis_text.dart';
import 'package:lingua_srs/widgets/markdown_content.dart';
import 'package:lingua_srs/widgets/markdown_notes_field.dart';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/main.dart';
import 'package:lingua_srs/models/vocab_merge_record.dart';
import 'package:lingua_srs/providers/app_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A study screen must not touch real audio plugins.
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

String vocabYaml(String title, String pos, String ko, String en) =>
    '''
---
vocabulary:
  $pos:
    - ko: $ko
      en: $en
---
# $title
''';

http.Response aiOk(Object content) => http.Response(
  jsonEncode({
    'choices': [
      {
        'message': {'content': jsonEncode(content)},
      },
    ],
  }),
  200,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory storageDirectory;

  setUp(() {
    storageDirectory = Directory.systemTemp.createTempSync(
      'lingua_srs_widget_test_',
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

  /// Pumps the app and waits until the provider has really finished loading.
  Future<AppProvider> pumpApp(
    WidgetTester tester, [
    Map<String, Object> prefs = const {},
  ]) async {
    SharedPreferences.setMockInitialValues({
      'lingua_srs_windows_legacy_migration_complete': true,
      ...prefs,
    });
    final provider = AppProvider();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppProvider>(create: (_) => provider),
          // main.dart provides the real one; the edit dialogs preview audio.
          ChangeNotifierProvider<AudioService>(
            create: (_) => _FakeAudioService(),
          ),
        ],
        child: const LinguaSrsApp(),
      ),
    );
    // File I/O completes on the real event loop; init() also waits on a fake
    // Future.delayed(Duration.zero), so both clocks have to advance.
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
    await tester.pumpAndSettle();
    return provider;
  }

  /// Like pumpApp's loading loop, but without mounting the app.
  Future<AppProvider> loadedProvider(
    WidgetTester tester, [
    Map<String, Object> prefs = const {},
  ]) async {
    SharedPreferences.setMockInitialValues({
      'lingua_srs_windows_legacy_migration_complete': true,
      ...prefs,
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
    return provider;
  }

  Future<Lesson> seed(
    WidgetTester tester,
    AppProvider p,
    String title,
    String pos,
    String ko,
    String en,
  ) async => (await tester.runAsync(
    () => p.importYaml(vocabYaml(title, pos, ko, en)),
  ))!;

  VocabItem only(Lesson l) => l.vocabularies.single;

  /// Mounts [home] with the provider, without the full app.
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

  /// A button that runs [onOpen] with a BuildContext.
  Widget opener(Future<void> Function(BuildContext) onOpen) => Scaffold(
    body: Builder(
      builder: (context) => TextButton(
        onPressed: () => onOpen(context),
        child: const Text('open'),
      ),
    ),
  );

  Future<void> waitFor(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 100 && !done(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
    }
    expect(done(), isTrue, reason: 'condition never became true');
  }

  VocabGroup vg(String id, String ko, String en, {int reviews = 0}) =>
      VocabGroup(
        id: id,
        entry: VocabItem(
          id: id,
          targetWord: ko,
          translation: en,
          pos: 'adjectives',
        ),
        reviews: reviews,
      )..lessonTitles.add('L');

  Future<void> openDialog(
    WidgetTester tester,
    Widget Function() dialog,
    void Function(Object?) onResult,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => onResult(
              await showDialog<Object>(
                context: context,
                builder: (_) => dialog(),
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

  testWidgets(
    'Merge confirmation is disabled until acknowledged; most reviewed survives by default',
    (tester) async {
      Object? result;
      await openDialog(
        tester,
        () => ConfirmMergeDialog(
          a: vg('a', '아름답다', 'beautiful', reviews: 1),
          b: vg('b', '아름답다', 'to be beautiful', reviews: 5),
        ),
        (r) => result = r,
      );
      final merge = find.widgetWithText(FilledButton, 'Merge');
      expect(tester.widget<FilledButton>(merge).onPressed, isNull);
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pump();
      expect(tester.widget<FilledButton>(merge).onPressed, isNotNull);
      await tester.tap(merge);
      await tester.pumpAndSettle();
      expect(result, 'b');
    },
  );

  testWidgets(
    'Merge confirmation lets you keep the other one, and Cancel returns null',
    (tester) async {
      Object? result = 'unset';
      await openDialog(
        tester,
        () => ConfirmMergeDialog(
          a: vg('a', '아름답다', 'beautiful', reviews: 1),
          b: vg('b', '아름답다', 'to be beautiful', reviews: 5),
        ),
        (r) => result = r,
      );
      await tester.tap(find.text('Keep progress of 아름답다 — beautiful'));
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Merge'));
      await tester.pumpAndSettle();
      expect(result, 'a');

      result = 'unset';
      await openDialog(
        tester,
        () => ConfirmMergeDialog(a: vg('a', '가', 'x'), b: vg('b', '나', 'y')),
        (r) => result = r,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(result, isNull);
    },
  );

  testWidgets(
    'Merge picker lists same-spelling words first and filters by search',
    (tester) async {
      Object? result;
      final current = vg('c', '크다', 'big');
      await openDialog(
        tester,
        () => MergePickerDialog(
          current: current,
          groups: [
            current,
            vg('z', '작다', 'small'),
            vg('s', '크다', 'to be big'),
            vg('t', '큰', 'large'),
          ],
        ),
        (r) => result = r,
      );
      final titles = tester
          .widgetList<ListTile>(find.byType(ListTile))
          .map((t) => (t.title as Text).data)
          .toList();
      expect(titles, ['크다 — to be big', '작다 — small', '큰 — large']);

      await tester.enterText(find.byType(TextField), 'small');
      await tester.pump();
      expect(find.byType(ListTile), findsOneWidget);
      await tester.tap(find.byType(ListTile));
      await tester.pumpAndSettle();
      expect((result as VocabGroup).id, 'z');
    },
  );

  testWidgets(
    'Edit dialog has both hint fields; AI buttons only with a DeepSeek key',
    (tester) async {
      Future<void> open(Map<String, Object> prefs) async {
        await pumpApp(tester, prefs);
        unawaited(
          VocabEditDialog.show(
            tester.element(find.byType(Scaffold).first),
            VocabItem(targetWord: '배', translation: 'pear', pos: 'nouns'),
          ),
        );
        await tester.pumpAndSettle();
      }

      await open({});
      expect(
        find.text('KO ➔ EN front hint', skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.text('EN ➔ KO front hint', skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.byIcon(Icons.auto_awesome, skipOffstage: false),
        findsNothing,
      );
    },
  );

  testWidgets('Edit dialog shows one AI button per direction with a key', (
    tester,
  ) async {
    await pumpApp(tester, {'lingua_srs_deepseek_api_key': 'test-key'});
    unawaited(
      VocabEditDialog.show(
        tester.element(find.byType(Scaffold).first),
        VocabItem(targetWord: '배', translation: 'pear', pos: 'nouns'),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byIcon(Icons.auto_awesome, skipOffstage: false),
      findsNWidgets(2),
    );
  });

  testWidgets('App renders LinguaSRS scaffold', (tester) async {
    await pumpApp(tester);
    expect(find.text('LinguaSRS'), findsWidgets);
    expect(find.textContaining('24h Limit'), findsNothing);

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Max reviews per 24 hours'), findsOneWidget);
    expect(find.text('DeepSeek API key'), findsOneWidget);
  });

  testWidgets('Merge menu is hidden without a DeepSeek key or history', (
    tester,
  ) async {
    await pumpApp(tester);
    expect(find.byTooltip('Vocabulary merging'), findsNothing);
  });

  testWidgets('Merge menu offers AI only with a DeepSeek key', (tester) async {
    await pumpApp(tester, {'lingua_srs_deepseek_api_key': 'test-key'});
    await tester.tap(find.byTooltip('Vocabulary merging'));
    await tester.pumpAndSettle();
    expect(find.text('Suggest merges with AI'), findsOneWidget);
  });

  group('Study progress label', () {
    Future<Lesson> openStudy(
      WidgetTester tester, {
      required bool mistakes,
    }) async {
      final provider = await loadedProvider(tester);
      final lesson = await seed(
        tester,
        provider,
        'Progress',
        'nouns',
        '배',
        'pear',
      );
      final vocab = only(lesson);
      vocab.cardNativeToTarget.isEnabled = false;
      final card = vocab.cardTargetToNative;
      card.status = SrsStatus.learning;
      card.lastRating = SrsRating.again;
      card.lastMistakeDate = DateTime.now();
      card.lastReviewed = DateTime.now();
      await pumpWith(
        tester,
        provider,
        StudyView(
          lessonId: lesson.id,
          dueOnly: false,
          recentMistakesOnly: mistakes,
        ),
      );
      return lesson;
    }

    // Test fonts (Ahem) draw every glyph one em wide, about twice as wide as
    // a real font, so halve the text scale to get realistic text widths.
    Future<void> useWidth(WidgetTester tester, double width) async {
      tester.view.physicalSize = Size(width, 2400);
      tester.platformDispatcher.textScaleFactorTestValue = 0.5;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pump();
    }

    // Nothing in the app bar may be cut off or overflow. A Text that is
    // truncated (ellipsis or fade) is laid out narrower than its natural
    // width.
    void expectAppBarFits(WidgetTester tester) {
      expect(tester.takeException(), isNull);
      final paragraphs = tester.renderObjectList<RenderParagraph>(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.byType(RichText),
        ),
      );
      expect(paragraphs, isNotEmpty);
      for (final p in paragraphs) {
        expect(
          p.getMaxIntrinsicWidth(double.infinity),
          lessThanOrEqualTo(p.size.width + 0.5),
          reason: 'App bar text is cut off: "${p.text.toPlainText()}"',
        );
      }
    }

    testWidgets('Mistakes progress label, narrow', (tester) async {
      await openStudy(tester, mistakes: true);
      await useWidth(tester, 360);

      expect(find.text('1 / 1'), findsOneWidget);
      expect(find.textContaining('Card 1 of 1'), findsNothing);
      expectAppBarFits(tester);
    });

    testWidgets('Mistakes progress label, wide', (tester) async {
      final lesson = await openStudy(tester, mistakes: true);
      await useWidth(tester, 1200);

      expect(find.text('${lesson.displayTitle} (1/1)'), findsOneWidget);
      expect(find.textContaining('Card 1 of 1'), findsNothing);
      expect(find.text('Recent Mistakes Review'), findsOneWidget);
      expectAppBarFits(tester);
    });

    testWidgets('Study progress label is unchanged', (tester) async {
      final lesson = await openStudy(tester, mistakes: false);

      await useWidth(tester, 1200);
      expect(find.text('${lesson.displayTitle} (1/1)'), findsOneWidget);
      expect(find.text('Recent Mistakes Review'), findsNothing);
      expectAppBarFits(tester);

      await useWidth(tester, 360);
      expect(find.text('1 / 1'), findsOneWidget);
      expectAppBarFits(tester);
    });
  });

  group('Study card front hints', () {
    Future<VocabItem> openStudy(
      WidgetTester tester, {
      required String pos,
      required String ko,
      required String en,
      required CardDirection direction,
      void Function(VocabItem)? configure,
    }) async {
      final provider = await loadedProvider(tester);
      final lesson = await seed(tester, provider, 'Study hints', pos, ko, en);
      final vocab = only(lesson);
      vocab.cardTargetToNative.isEnabled =
          direction == CardDirection.targetToNative;
      vocab.cardNativeToTarget.isEnabled =
          direction == CardDirection.nativeToTarget;
      configure?.call(vocab);
      await pumpWith(tester, provider, StudyView(lessonId: lesson.id));
      return vocab;
    }

    Finder rich(String text) => find.textContaining(text, findRichText: true);

    testWidgets(
      'KO ➔ EN front shows its own hint, not the other direction\'s',
      (tester) async {
        await openStudy(
          tester,
          pos: 'nouns',
          ko: '배',
          en: 'pear',
          direction: CardDirection.targetToNative,
          configure: (v) {
            v.cardTargetToNative.frontHint = 'fruit';
            v.cardNativeToTarget.frontHint = 'wrong side';
          },
        );
        expect(find.text('배'), findsWidgets);
        expect(rich('fruit'), findsOneWidget);
        expect(rich('wrong side'), findsNothing);
      },
    );

    testWidgets(
      'EN ➔ KO front shows its own hint, not the other direction\'s',
      (tester) async {
        await openStudy(
          tester,
          pos: 'adjectives',
          ko: '크다',
          en: 'big',
          direction: CardDirection.nativeToTarget,
          configure: (v) {
            v.cardNativeToTarget.frontHint = 'general size';
            v.cardTargetToNative.frontHint = 'wrong side';
          },
        );
        expect(find.text('big'), findsWidgets);
        expect(rich('general size'), findsOneWidget);
        expect(rich('wrong side'), findsNothing);
      },
    );

    testWidgets('falls back to the general hint when the direction has none', (
      tester,
    ) async {
      await openStudy(
        tester,
        pos: 'nouns',
        ko: '배',
        en: 'pear',
        direction: CardDirection.targetToNative,
        configure: (v) => v.disambiguation = 'general hint',
      );
      expect(rich('general hint'), findsOneWidget);
    });

    testWidgets('the direction hint wins over the general hint', (
      tester,
    ) async {
      await openStudy(
        tester,
        pos: 'nouns',
        ko: '배',
        en: 'pear',
        direction: CardDirection.targetToNative,
        configure: (v) {
          v.disambiguation = 'general hint';
          v.cardTargetToNative.frontHint = 'fruit';
        },
      );
      expect(rich('fruit'), findsOneWidget);
      expect(rich('general hint'), findsNothing);
    });

    testWidgets('the hint is a front-only cue: gone after Show Answer', (
      tester,
    ) async {
      await openStudy(
        tester,
        pos: 'nouns',
        ko: '배',
        en: 'pear',
        direction: CardDirection.targetToNative,
        configure: (v) => v.cardTargetToNative.frontHint = 'fruit',
      );
      expect(rich('fruit'), findsOneWidget);
      await tester.tap(find.textContaining('Show Answer'));
      await tester.pump();
      await tester.pump();
      expect(rich('fruit'), findsNothing);
      expect(rich('pear'), findsWidgets);
    });
  });

  group('Study card pronunciation', () {
    const withSentence = '''
---
vocabulary:
  nouns:
    - ko: 배
      en: pear
      examples:
        - ko: 저는 **배**를 먹었어요
          en: I ate a **pear**
---
# Pron
''';
    const sentenceRomanization = 'jeoneun baereul meogeosseoyo';
    const sentenceIpa = '[t\u0361ɕʌ.nɯn pɛ.ɾɯl mʌ.ɡʌ.s\u0348ʌ.jo]';

    Map<String, Object> options(List<String> enabled) => {
      'lingua_srs_pronunciation': enabled,
    };
    final vocabOnly = options(['vocabulary_romanization', 'vocabulary_ipa']);
    final sentenceOnly = options(['sentence_romanization', 'sentence_ipa']);
    final everything = options([
      'vocabulary_romanization',
      'vocabulary_ipa',
      'sentence_romanization',
      'sentence_ipa',
    ]);

    Future<AppProvider> openStudy(
      WidgetTester tester, {
      required CardDirection direction,
      Map<String, Object> prefs = const {},
      String targetLanguage = 'ko',
      String? yaml,
    }) async {
      final provider = await loadedProvider(tester, prefs);
      final lesson = (await tester.runAsync(
        () => provider.importYaml(
          yaml ?? vocabYaml('Pron', 'nouns', '배', 'pear'),
        ),
      ))!;
      lesson.targetLanguage = targetLanguage;
      final vocab = only(lesson);
      vocab.cardTargetToNative.isEnabled =
          direction == CardDirection.targetToNative;
      vocab.cardNativeToTarget.isEnabled =
          direction == CardDirection.nativeToTarget;
      await pumpWith(tester, provider, StudyView(lessonId: lesson.id));
      return provider;
    }

    Future<void> reveal(WidgetTester tester) async {
      await tester.tap(find.textContaining('Show Answer'));
      await tester.pumpAndSettle();
    }

    testWidgets('nothing is shown by default', (tester) async {
      await openStudy(
        tester,
        direction: CardDirection.targetToNative,
        yaml: withSentence,
      );
      await reveal(tester);
      expect(find.text('bae'), findsNothing);
      expect(find.text('[pɛ]'), findsNothing);
      expect(find.text(sentenceRomanization), findsNothing);
    });

    for (final direction in CardDirection.values) {
      testWidgets('front never shows it ($direction)', (tester) async {
        await openStudy(
          tester,
          direction: direction,
          prefs: everything,
          yaml: withSentence,
        );
        expect(find.text('bae'), findsNothing);
        expect(find.text('[pɛ]'), findsNothing);
        expect(find.text(sentenceRomanization), findsNothing);
      });

      testWidgets('back shows the vocabulary lines ($direction)', (
        tester,
      ) async {
        await openStudy(tester, direction: direction, prefs: vocabOnly);
        await reveal(tester);
        expect(find.text('bae'), findsOneWidget);
        expect(find.text('[pɛ]'), findsOneWidget);
      });
    }

    testWidgets('sentence lines stay off while vocabulary lines are on', (
      tester,
    ) async {
      await openStudy(
        tester,
        direction: CardDirection.targetToNative,
        prefs: vocabOnly,
        yaml: withSentence,
      );
      await reveal(tester);
      expect(find.text('bae'), findsOneWidget);
      expect(find.text(sentenceRomanization), findsNothing);
      expect(find.text(sentenceIpa), findsNothing);
    });

    testWidgets('sentence lines show without the vocabulary lines', (
      tester,
    ) async {
      await openStudy(
        tester,
        direction: CardDirection.targetToNative,
        prefs: sentenceOnly,
        yaml: withSentence,
      );
      await reveal(tester);
      expect(find.text('bae'), findsNothing);
      expect(find.text('[pɛ]'), findsNothing);
      expect(find.text(sentenceRomanization), findsOneWidget);
      expect(find.text(sentenceIpa), findsOneWidget);
    });

    Future<void> closeMenu(WidgetTester tester) async {
      await tester.tapAt(Offset.zero); // tap the modal barrier
      await tester.pumpAndSettle();
    }

    Finder menuItem(String value) => find.byWidgetPredicate(
      (w) => w is PopupMenuItem<String> && w.value == value,
    );

    bool itemEnabled(WidgetTester tester, String value) =>
        tester.widget<PopupMenuItem<String>>(menuItem(value)).enabled;

    List<ToggleButtons> toggleGroups(WidgetTester tester) =>
        tester.widgetList<ToggleButtons>(find.byType(ToggleButtons)).toList();

    Future<void> openMore(WidgetTester tester) async {
      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
    }

    Finder toggle(String target, String kind) =>
        find.byKey(ValueKey('pronunciation-$target-$kind'));

    Future<void> tapToggle(
      WidgetTester tester,
      String target,
      String kind,
    ) async {
      await tester.tap(toggle(target, kind));
      await tester.pumpAndSettle();
    }

    testWidgets('toggles are not on the card, only inside the More menu', (
      tester,
    ) async {
      await openStudy(
        tester,
        direction: CardDirection.targetToNative,
        yaml: withSentence,
      );
      expect(toggle('vocabulary', 'romanization'), findsNothing); // front
      await reveal(tester);
      expect(toggle('vocabulary', 'romanization'), findsNothing); // back

      await openMore(tester);
      expect(find.text('Pronunciation cue'), findsOneWidget);
      for (final target in ['vocabulary', 'sentence']) {
        expect(toggle(target, 'romanization'), findsOneWidget);
        expect(toggle(target, 'ipa'), findsOneWidget);
      }
      expect(find.text('RR'), findsNWidgets(2));
      expect(find.text('IPA'), findsNWidgets(2));
    });

    for (final width in [1200.0, 360.0]) {
      testWidgets(
        'toggled from the More menu at ${width.toInt()}dp, live on the same card',
        (tester) async {
          final provider = await openStudy(
            tester,
            direction: CardDirection.targetToNative,
            yaml: withSentence,
          );
          tester.view.physicalSize = Size(width, 2400);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull); // app bar fits, no overflow

          await reveal(tester);
          expect(find.text('bae'), findsNothing);

          await openMore(tester);
          await tapToggle(tester, 'vocabulary', 'romanization');
          expect(
            provider.showRomanization(PronunciationTarget.vocabulary),
            isTrue,
          );
          expect(find.text('bae'), findsOneWidget); // card updates behind menu
          expect(find.text(sentenceRomanization), findsNothing);
          expect(toggle('sentence', 'ipa'), findsOneWidget); // menu stays open

          await tapToggle(tester, 'sentence', 'romanization');
          expect(find.text(sentenceRomanization), findsOneWidget);

          await tapToggle(tester, 'vocabulary', 'romanization'); // off again
          expect(find.text('bae'), findsNothing);
          expect(find.text(sentenceRomanization), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets('no pronunciation toggles for a non-Korean lesson', (
      tester,
    ) async {
      await openStudy(
        tester,
        direction: CardDirection.targetToNative,
        targetLanguage: 'es',
      );
      await openMore(tester);

      expect(toggle('vocabulary', 'romanization'), findsNothing);
      expect(find.text('Pronunciation cue'), findsNothing);
    });

    testWidgets('toggles are disabled until the back is shown', (tester) async {
      final provider = await openStudy(
        tester,
        direction: CardDirection.targetToNative,
        yaml: withSentence,
      );
      await openMore(tester); // front side
      expect(find.byType(ToggleButtons), findsNWidgets(2));
      expect(toggleGroups(tester).every((g) => g.onPressed == null), isTrue);

      await tapToggle(tester, 'vocabulary', 'romanization');
      await tapToggle(tester, 'sentence', 'ipa');
      expect(
        provider.showRomanization(PronunciationTarget.vocabulary),
        isFalse,
      );
      expect(provider.showIpa(PronunciationTarget.sentence), isFalse);
    });

    testWidgets(
      'toggles enable on reveal and disable again after flipping back',
      (tester) async {
        await openStudy(tester, direction: CardDirection.targetToNative);

        Future<bool> togglesEnabled() async {
          await openMore(tester);
          final enabled = toggleGroups(tester)
              .every((g) => g.onPressed != null);
          await closeMenu(tester);
          return enabled;
        }

        expect(await togglesEnabled(), isFalse);
        await reveal(tester);
        expect(await togglesEnabled(), isTrue);
        await tester.tap(find.textContaining('Flip back to Front'));
        await tester.pumpAndSettle();
        expect(await togglesEnabled(), isFalse);
      },
    );

    testWidgets('Edit and Ask AI are disabled until the back is shown', (
      tester,
    ) async {
      await openStudy(tester, direction: CardDirection.targetToNative);
      IconButton editButton() => tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.edit_outlined),
      );

      expect(editButton().onPressed, isNull);
      await openMore(tester);
      expect(itemEnabled(tester, 'ai'), isFalse);
      await closeMenu(tester);

      await reveal(tester);
      expect(editButton().onPressed, isNotNull);
      await openMore(tester);
      expect(itemEnabled(tester, 'ai'), isTrue);
    });

    testWidgets(
      'wide app bar (700dp): previous/next, undo, sound, edit, More',
      (tester) async {
        await openStudy(tester, direction: CardDirection.targetToNative);
        tester.view.physicalSize = const Size(700, 2400); // boundary is wide
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        for (final icon in [
          Icons.chevron_left,
          Icons.chevron_right,
          Icons.undo,
          Icons.edit_outlined,
        ]) {
          expect(find.byIcon(icon), findsOneWidget, reason: '$icon');
        }
        expect(find.byTooltip('Autoplay audio'), findsOneWidget);
        expect(
          tester
              .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.undo))
              .onPressed,
          isNull,
          reason: 'nothing to undo yet',
        );

        await openMore(tester);
        expect(menuItem('ai'), findsOneWidget);
        for (final value in ['undo', 'autoplay', 'edit']) {
          expect(menuItem(value), findsNothing, reason: value);
        }
        expect(find.text('Pronunciation cue'), findsOneWidget);
      },
    );

    testWidgets('narrow app bar (699dp): previous/next and More only', (
      tester,
    ) async {
      await openStudy(tester, direction: CardDirection.targetToNative);
      tester.view.physicalSize = const Size(699, 2400);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      expect(find.byIcon(Icons.chevron_left), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);
      expect(find.byIcon(Icons.undo), findsNothing);
      expect(find.byIcon(Icons.edit_outlined), findsNothing);
      expect(find.byTooltip('Autoplay audio'), findsNothing);

      await openMore(tester);
      for (final value in ['undo', 'autoplay', 'edit', 'ai']) {
        expect(menuItem(value), findsOneWidget, reason: value);
      }
      expect(itemEnabled(tester, 'undo'), isFalse, reason: 'nothing to undo');
    });

    testWidgets('autoplay toggle button works at 1200dp', (tester) async {
      final provider = await openStudy(
        tester,
        direction: CardDirection.targetToNative,
      );
      tester.view.physicalSize = Size(1200, 2400);
      await tester.pumpAndSettle();
      expect(provider.autoplayAudio, isTrue);
      await tester.tap(find.byTooltip('Autoplay audio'));
      await tester.pumpAndSettle();
      expect(provider.autoplayAudio, isFalse);
    });

    testWidgets('autoplay at 300dp lives in the More menu and toggles', (
      tester,
    ) async {
      final provider = await openStudy(
        tester,
        direction: CardDirection.targetToNative,
      );
      tester.view.physicalSize = const Size(300, 2400);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byTooltip('Autoplay audio'), findsNothing);
      expect(provider.autoplayAudio, isTrue);

      await openMore(tester);
      expect(find.text('Turn autoplay off'), findsOneWidget);
      await tester.tap(menuItem('autoplay'));
      await tester.pumpAndSettle();
      expect(provider.autoplayAudio, isFalse);

      await openMore(tester);
      expect(find.text('Turn autoplay on'), findsOneWidget);
    });

    testWidgets('nothing for a non-Korean lesson', (tester) async {
      await openStudy(
        tester,
        direction: CardDirection.targetToNative,
        prefs: everything,
        targetLanguage: 'es',
        yaml: withSentence,
      );
      await reveal(tester);
      expect(find.text('bae'), findsNothing);
      expect(find.text('[pɛ]'), findsNothing);
      expect(find.text(sentenceRomanization), findsNothing);
      expect(
        find.byKey(const ValueKey('pronunciation-vocabulary-ipa')),
        findsNothing,
      );
    });
  });

  group('Manual EN ➔ KO search dialog', () {
    Future<(AppProvider, VocabItem, List<Object?>)> setup(
      WidgetTester tester,
    ) async {
      final provider = await loadedProvider(tester);
      final big = await seed(tester, provider, 'L1', 'adjectives', '크다', 'big');
      await seed(tester, provider, 'L2', 'adjectives', '넓다', 'wide');
      await seed(
        tester,
        provider,
        'L3',
        'adjectives',
        '거대하다',
        'to be huge or big',
      );
      await seed(tester, provider, 'L4', 'nouns', '배', 'pear');
      final results = <Object?>[];
      final draft = VocabItem(
        id: only(big).id,
        targetWord: '크다',
        translation: 'big',
        pos: 'adjectives',
      );
      await pumpWith(
        tester,
        provider,
        opener((context) async {
          results.add(
            await showEnKoSearch(context, provider: provider, draft: draft),
          );
        }),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return (provider, draft, results);
    }

    testWidgets('prefills the query, lists matches, and returns typed hints', (
      tester,
    ) async {
      final (provider, _, results) = await setup(tester);
      expect(find.text('거대하다 — to be huge or big'), findsOneWidget);
      expect(find.text('넓다 — wide'), findsNothing);
      expect(find.text('배 — pear'), findsNothing);

      await tester.enterText(
        find.widgetWithText(TextField, 'Hint for this word'),
        'general size',
      );
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pump();
      await tester.enterText(
        find.widgetWithText(TextField, 'EN ➔ KO hint for 거대하다'),
        'enormous',
      );
      await tester.tap(find.text('Use selected'));
      await tester.pumpAndSettle();

      final choice = results.single as SimilarMeaningsChoice;
      expect(choice.targetHint, 'general size');
      final hugeId = provider.vocabGroups
          .firstWhere((g) => g.entry.targetWord == '거대하다')
          .id;
      expect(choice.otherHints, {hugeId: 'enormous'});
    });

    testWidgets('the same-type chip hides other types until switched off', (
      tester,
    ) async {
      await setup(tester);
      await tester.enterText(find.byType(TextField).first, 'pear');
      await tester.pump();
      expect(find.text('No matching vocabulary.'), findsOneWidget);
      await tester.tap(find.byType(FilterChip));
      await tester.pump();
      expect(find.text('배 — pear'), findsOneWidget);
    });

    testWidgets(
      'Cancel returns null, and an empty hint box returns no target hint',
      (tester) async {
        final (_, _, results) = await setup(tester);
        await tester.tap(find.text('Use selected'));
        await tester.pumpAndSettle();
        final choice = results.single as SimilarMeaningsChoice;
        expect(choice.targetHint, isNull);
        expect(choice.otherHints, isEmpty);
      },
    );
  });

  testWidgets('A word that already has an EN ➔ KO hint cannot be overwritten', (
    tester,
  ) async {
    final provider = await loadedProvider(tester);
    final big = await seed(tester, provider, 'L1', 'adjectives', '크다', 'big');
    final huge = await seed(
      tester,
      provider,
      'L2',
      'adjectives',
      '거대하다',
      'huge, big',
    );
    only(huge).cardNativeToTarget.frontHint = 'existing';
    final draft = VocabItem(
      id: only(big).id,
      targetWord: '크다',
      translation: 'big',
      pos: 'adjectives',
    );
    await pumpWith(
      tester,
      provider,
      opener((context) async {
        await showEnKoSearch(context, provider: provider, draft: draft);
      }),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final tile = tester.widget<CheckboxListTile>(find.byType(CheckboxListTile));
    expect(tile.onChanged, isNull);
    expect(find.textContaining('hint: existing'), findsOneWidget);
  });

  testWidgets(
    'Edit dialog: manual search button always, AI buttons only with a key',
    (tester) async {
      final provider = await loadedProvider(tester);
      await pumpWith(
        tester,
        provider,
        opener((context) async {
          await VocabEditDialog.show(
            context,
            VocabItem(targetWord: '배', translation: 'pear', pos: 'nouns'),
          );
        }),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(
        find.text('KO ➔ EN front hint', skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.text('EN ➔ KO front hint', skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.byTooltip('Find similar English meanings', skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.byIcon(Icons.auto_awesome, skipOffstage: false),
        findsNothing,
      );
    },
  );

  testWidgets('Edit dialog: a DeepSeek key adds one AI button per direction', (
    tester,
  ) async {
    final provider = await loadedProvider(tester, {
      'lingua_srs_deepseek_api_key': 'test-key',
    });
    await pumpWith(
      tester,
      provider,
      opener((context) async {
        await VocabEditDialog.show(
          context,
          VocabItem(targetWord: '배', translation: 'pear', pos: 'nouns'),
        );
      }),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(
      find.byIcon(Icons.auto_awesome, skipOffstage: false),
      findsNWidgets(2),
    );
    expect(
      find.byTooltip('Find similar English meanings', skipOffstage: false),
      findsOneWidget,
    );
  });

  group('AI merge dialog', () {
    Future<(AppProvider, Lesson, Lesson)> setup(
      WidgetTester tester,
      MockClient client,
    ) async {
      final provider = await loadedProvider(tester, {
        'lingua_srs_deepseek_api_key': 'k',
      });
      final a = await seed(
        tester,
        provider,
        'L1',
        'adjectives',
        '아름답다',
        'beautiful',
      );
      final b = await seed(
        tester,
        provider,
        'L2',
        'adjectives',
        '아름답다',
        'to be beautiful',
      );
      provider.aiClient = client;
      await pumpWith(
        tester,
        provider,
        opener((c) => showAiMergeSuggestions(c)),
      );
      return (provider, a, b);
    }

    MockClient suggesting(
      List<int> counter,
      AppProvider Function() provider,
      Lesson Function() a,
      Lesson Function() b,
    ) => MockClient((request) async {
      counter.add(1);
      expect(
        request.body,
        isNot(contains('auto-')),
        reason: 'merge requests should use entry numbers, not ids',
      );
      return aiOk({
        'merges': [
          {
            'keep': 1,
            'merge': [2],
            'reason': 'same word',
          },
        ],
      });
    });

    testWidgets(
      'lists a suggestion and merges the ticked one after confirmation',
      (tester) async {
        final requests = <int>[];
        late Lesson a, b;
        late AppProvider provider;
        final client = suggesting(requests, () => provider, () => a, () => b);
        (provider, a, b) = await setup(tester, client);

        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(requests, hasLength(1));
        expect(find.textContaining('same word'), findsOneWidget);
        expect(
          find.widgetWithText(FilledButton, 'Merge selected (0)'),
          findsOneWidget,
        );

        await tester.tap(find.byType(CheckboxListTile));
        await tester.pump();
        await tester.tap(find.text('Merge selected (1)'));
        await tester.pumpAndSettle();
        expect(find.text('Merge 1 vocabulary group(s)?'), findsOneWidget);
        expect(
          provider.mergeHistory,
          isEmpty,
        ); // nothing happens before confirming

        await tester.tap(find.widgetWithText(FilledButton, 'Merge 1'));
        await tester.pump();
        await waitFor(tester, () => provider.mergeHistory.length == 1);
        await tester.pumpAndSettle();

        expect(only(b).id, only(a).id);
        expect(provider.mergeHistory.single.source, 'ai');
        expect(find.text('Merged 1 group(s).'), findsOneWidget);
      },
    );

    testWidgets('cancelling the confirmation merges nothing', (tester) async {
      final requests = <int>[];
      late Lesson a, b;
      late AppProvider provider;
      (provider, a, b) = await setup(
        tester,
        suggesting(requests, () => provider, () => a, () => b),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pump();
      await tester.tap(find.text('Merge selected (1)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel').last);
      await tester.pumpAndSettle();
      expect(provider.mergeHistory, isEmpty);
      expect(only(b).id, isNot(only(a).id));
    });

    testWidgets('shows an empty state when the AI finds nothing', (
      tester,
    ) async {
      final requests = <int>[];
      final client = MockClient((_) async {
        requests.add(1);
        return aiOk({'merges': []});
      });
      await setup(tester, client);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(requests, hasLength(1));
      expect(find.text('No duplicate vocabulary found.'), findsOneWidget);
    });

    testWidgets('shows an error with Retry, and Retry asks again', (
      tester,
    ) async {
      var calls = 0;
      final client = MockClient((_) async {
        calls++;
        if (calls == 1) return http.Response('boom', 500);
        return aiOk({
          'merges': [
            {
              'keep': 1,
              'merge': [2],
              'reason': 'same word',
            },
          ],
        });
      });
      final (_, _, _) = await setup(tester, client);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('DeepSeek request failed (500)'),
        findsOneWidget,
      );

      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(find.textContaining('same word'), findsOneWidget);
    });

    testWidgets('a 401 hides the AI features until the key changes', (
      tester,
    ) async {
      final client = MockClient((_) async => http.Response('bad key', 401));
      final (provider, _, _) = await setup(tester, client);
      expect(provider.canUseAi, isTrue);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.textContaining('(401)'), findsOneWidget);
      expect(provider.canUseAi, isFalse);
    });
  });

  group('Merge section in the edit dialog', () {
    Future<(AppProvider, Lesson, Lesson)> open(
      WidgetTester tester, {
      Map<String, Object> prefs = const {},
      http.Client? client,
    }) async {
      final provider = await loadedProvider(tester, prefs);
      final a = await seed(
        tester,
        provider,
        'L1',
        'adjectives',
        '아름답다',
        'beautiful',
      );
      final b = await seed(
        tester,
        provider,
        'L2',
        'adjectives',
        '아름답다',
        'to be beautiful',
      );
      provider.aiClient = client;
      await pumpWith(
        tester,
        provider,
        opener(
          (context) => VocabEditDialog.show(context, only(a), lessonId: a.id),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return (provider, a, b);
    }

    testWidgets('is shown for a saved vocab, AI button only with a key', (
      tester,
    ) async {
      await open(tester);
      expect(
        find.text('Merge duplicates', skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.text('Merge with another word…', skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.text('Suggest merge with AI', skipOffstage: false),
        findsNothing,
      );
    });

    testWidgets('shows the AI merge button when a DeepSeek key is set', (
      tester,
    ) async {
      await open(tester, prefs: {'lingua_srs_deepseek_api_key': 'k'});
      expect(
        find.text('Suggest merge with AI', skipOffstage: false),
        findsOneWidget,
      );
    });

    testWidgets('is hidden for a vocab that is not saved yet', (tester) async {
      final provider = await loadedProvider(tester);
      await pumpWith(
        tester,
        provider,
        opener(
          (context) => VocabEditDialog.show(
            context,
            VocabItem(targetWord: '배', translation: 'pear', pos: 'nouns'),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Merge duplicates', skipOffstage: false), findsNothing);
    });

    testWidgets(
      'manual merge: pick, confirm with the warning, dialog closes, undo offered',
      (tester) async {
        final (provider, a, b) = await open(tester);
        await tester.ensureVisible(find.text('Merge with another word…'));
        await tester.tap(find.text('Merge with another word…'));
        await tester.pumpAndSettle();

        await tester.tap(find.text('아름답다 — to be beautiful'));
        await tester.pumpAndSettle();
        expect(
          find.text('Unsaved changes in this edit form will be discarded.'),
          findsOneWidget,
        );

        final confirm = find.byType(ConfirmMergeDialog);
        await tester.tap(
          find.descendant(of: confirm, matching: find.byType(CheckboxListTile)),
        );
        await tester.pump();
        await tester.tap(
          find.descendant(
            of: confirm,
            matching: find.widgetWithText(FilledButton, 'Merge'),
          ),
        );
        await tester.pump();
        await waitFor(tester, () => provider.mergeHistory.length == 1);
        await tester.pumpAndSettle();

        expect(only(b).id, only(a).id);
        expect(find.byType(VocabEditDialog), findsNothing);
        expect(find.textContaining('Merged'), findsOneWidget);
        expect(find.text('Undo'), findsOneWidget);
      },
    );

    testWidgets(
      'cancelling the picker keeps the edit dialog open and merges nothing',
      (tester) async {
        final (provider, a, b) = await open(tester);
        await tester.ensureVisible(find.text('Merge with another word…'));
        await tester.tap(find.text('Merge with another word…'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(
            of: find.byType(MergePickerDialog),
            matching: find.text('Cancel'),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byType(VocabEditDialog), findsOneWidget);
        expect(provider.mergeHistory, isEmpty);
        expect(only(b).id, isNot(only(a).id));
      },
    );

    testWidgets('AI merge: scoped suggestions, confirm, both dialogs close', (
      tester,
    ) async {
      var requests = 0;
      final client = MockClient((request) async {
        requests++;
        final user =
            ((jsonDecode(request.body) as Map<String, dynamic>)['messages']
                    as List)[1]['content']
                as String;
        expect(user, contains('아름답다'));
        return aiOk({
          'merges': [
            {
              'keep': 1,
              'merge': [2],
              'reason': 'same word',
            },
          ],
        });
      });
      final (provider, a, b) = await open(
        tester,
        prefs: {'lingua_srs_deepseek_api_key': 'k'},
        client: client,
      );
      await tester.ensureVisible(find.text('Suggest merge with AI'));
      await tester.tap(find.text('Suggest merge with AI'));
      await tester.pumpAndSettle();

      expect(find.text('AI merge suggestions for 아름답다'), findsOneWidget);
      expect(requests, 1);
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog).last,
          matching: find.byType(CheckboxListTile),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('Merge selected (1)'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Merge 1'));
      await tester.pump();
      await waitFor(tester, () => provider.mergeHistory.length == 1);
      await tester.pumpAndSettle();

      expect(only(b).id, only(a).id);
      expect(provider.mergeHistory.single.source, 'ai');
      expect(find.byType(VocabEditDialog), findsNothing);
    });
  });

  testWidgets('Merge history: Undo is enabled only for the newest merge', (
    tester,
  ) async {
    final provider = await loadedProvider(tester);
    final l1 = await seed(
      tester,
      provider,
      'L1',
      'adjectives',
      '아름답다',
      'beautiful',
    );
    final l2 = await seed(
      tester,
      provider,
      'L2',
      'adjectives',
      '아름답다',
      'to be beautiful',
    );
    final l3 = await seed(
      tester,
      provider,
      'L3',
      'adjectives',
      '아름답다',
      'lovely',
    );
    await tester.runAsync(() async {
      await provider.mergeVocab(
        survivorId: only(l1).id,
        absorbedIds: [only(l2).id],
      );
      await provider.mergeVocab(
        survivorId: only(l1).id,
        absorbedIds: [only(l3).id],
      );
    });
    await pumpWith(tester, provider, opener((c) => showMergeHistory(c)));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final undo = find.widgetWithText(TextButton, 'Undo');
    expect(undo, findsNWidgets(2));
    expect(tester.widgetList<TextButton>(undo).first.onPressed, isNotNull);
    expect(tester.widgetList<TextButton>(undo).last.onPressed, isNull);
    expect(find.textContaining('undo newer merges first'), findsOneWidget);

    await tester.tap(undo.first);
    await tester.pump();
    await waitFor(tester, () => provider.mergeHistory.length == 1);
    await tester.pumpAndSettle();

    expect(only(l3).id, isNot(only(l1).id)); // newest merge undone
    expect(only(l2).id, only(l1).id); // older one still merged
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Undo'))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('Merge history shows an empty state', (tester) async {
    final provider = await loadedProvider(tester);
    await pumpWith(tester, provider, opener((c) => showMergeHistory(c)));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Nothing to undo.'), findsOneWidget);
  });

  testWidgets('Merge picker suggests likely duplicates before typing', (
    tester,
  ) async {
    final current = vg('cur', '아름답다', 'beautiful');
    await openDialog(
      tester,
      () => MergePickerDialog(
        current: current,
        groups: [
          current,
          vg('zzz', '크다', 'big'),
          vg('same', '아름답다', 'to be beautiful'),
          vg('variant', '아름답고', 'pretty'),
          vg('meaning', '예쁘다', 'beautiful'),
        ],
      ),
      (_) {},
    );
    expect(find.text('Suggestions'), findsOneWidget);
    expect(find.text('All other words'), findsOneWidget);
    // Rows are built lazily: check the visible suggestions first...
    final titles = tester
        .widgetList<ListTile>(find.byType(ListTile))
        .map((t) => (t.title as Text).data)
        .toList();
    expect(titles.take(3), [
      '아름답다 — to be beautiful',
      '아름답고 — pretty',
      '예쁘다 — beautiful',
    ]);
    expect(find.textContaining('same Korean'), findsOneWidget);
    expect(find.textContaining('similar Korean'), findsOneWidget);
    expect(find.textContaining('same meaning'), findsNWidgets(2));

    // ...then scroll to the "All other words" section.
    await tester.scrollUntilVisible(
      find.text('크다 — big'),
      100,
      scrollable: find.descendant(
        of: find.byType(ListView),
        matching: find.byType(Scrollable),
      ),
    );
    expect(find.text('크다 — big'), findsOneWidget);
    expect(find.text('All other words'), findsOneWidget);
  });

  testWidgets('Merge picker searches Korean variants and English', (
    tester,
  ) async {
    final current = vg('cur', '아름답다', 'beautiful');
    await openDialog(
      tester,
      () => MergePickerDialog(
        current: current,
        groups: [
          current,
          vg('same', '아름답다', 'to be beautiful'),
          vg('variant', '아름답고', 'pretty'),
          vg('meaning', '예쁘다', 'beautiful'),
        ],
      ),
      (_) {},
    );
    List<String?> titles() => tester
        .widgetList<ListTile>(find.byType(ListTile))
        .map((t) => (t.title as Text).data)
        .toList();

    await tester.enterText(find.byType(TextField), '아름답습니다');
    await tester.pump();
    expect(titles(), containsAll(['아름답다 — to be beautiful', '아름답고 — pretty']));
    expect(titles(), isNot(contains('예쁘다 — beautiful')));
    expect(
      find.text('Suggestions'),
      findsNothing,
    ); // headers only before typing

    await tester.enterText(find.byType(TextField), 'pretty');
    await tester.pump();
    expect(titles(), ['아름답고 — pretty']);

    await tester.enterText(find.byType(TextField), 'zzzz');
    await tester.pump();
    expect(find.text('No matching vocabulary.'), findsOneWidget);
  });

  group('Add vocabulary dialog', () {
    Future<(AppProvider, VocabItem)> openAdd(
      WidgetTester tester, {
      List<Sentence> pool = const [],
    }) async {
      final provider = await loadedProvider(tester);
      final lesson = await seed(tester, provider, 'L1', 'nouns', '사과', 'apple');
      for (final sentence in pool) {
        await tester.runAsync(() => provider.addSentenceToPool(sentence));
      }
      final draft = VocabItem(targetWord: '', translation: '', pos: '');
      await pumpWith(
        tester,
        provider,
        opener(
          (context) => VocabEditDialog.show(
            context,
            draft,
            lessonId: lesson.id,
            isNew: true,
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return (provider, draft);
    }

    Future<void> fill(
      WidgetTester tester, {
      String ko = '',
      String en = '',
      String pos = '',
    }) async {
      Future<void> type(String label, String text) async {
        if (text.isEmpty) return;
        await tester.enterText(find.widgetWithText(TextField, label), text);
      }

      await type('Korean *', ko);
      await type('English *', en);
      await type('Part of speech *', pos);
      await tester.pump();
    }

    /// Save when it writes to storage (new examples join the pool).
    Future<void> saveAndWait(WidgetTester tester) async {
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      for (
        var i = 0;
        i < 50 && find.byType(VocabEditDialog).evaluate().isNotEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pumpAndSettle();
    }

    Finder inSentenceDialog(String label) => find.descendant(
      of: find.byType(AlertDialog),
      matching: find.widgetWithText(TextField, label),
    );

    Future<void> save(WidgetTester tester) async {
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
    }

    /// The row of an example (linked or picked from the pool). Other tiles in
    /// the dialog, such as the collapsed TTS one, are ListTiles too.
    Finder exampleTile() => find
        .byWidgetPredicate((w) => w is ListTile && w.title is EmphasisText)
        .first;

    /// The TTS text is collapsed; opens the tile (inside the sentence dialog
    /// when [inDialog] is set).
    Future<void> expandTts(WidgetTester tester, {bool inDialog = false}) async {
      final title = find.text('Text-to-speech');
      await tester.tap(
        inDialog
            ? find.descendant(of: find.byType(AlertDialog), matching: title)
            : title,
      );
      await tester.pumpAndSettle();
    }

    testWidgets('has a title and only the schema fields', (tester) async {
      await openAdd(tester);

      expect(find.text('Add vocabulary'), findsOneWidget);
      // ko, ko_text, en, audio, notes, plus the required part of speech.
      expect(find.widgetWithText(TextField, 'Korean *'), findsOneWidget);
      // ko_text is collapsed until opened, to keep the dialog short.
      expect(find.text('Text-to-speech'), findsOneWidget);
      expect(
        find.widgetWithText(TextField, 'Korean TTS text (optional)'),
        findsNothing,
      );
      expect(
        find.widgetWithText(
          TextField,
          'Korean TTS text (optional)',
          skipOffstage: false,
        ),
        findsOneWidget,
      );
      expect(find.widgetWithText(TextField, 'English *'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Audio URL'), findsOneWidget);
      expect(find.text('Add vocab note'), findsOneWidget);
      expect(find.text('Examples (0)'), findsOneWidget);
      expect(find.byTooltip('Add from pool'), findsOneWidget);
      expect(find.byTooltip('Create new sentence'), findsOneWidget);
      expect(
        find.widgetWithText(TextField, 'Part of speech *'),
        findsOneWidget,
      );
      for (final hidden in [
        'ID (optional)',
        'Front hint, both directions (optional)',
        'KO ➔ EN',
        'EN ➔ KO (cloze)',
      ]) {
        expect(
          find.text(hidden, skipOffstage: false),
          findsNothing,
          reason: hidden,
        );
      }
    });

    testWidgets('part of speech starts empty and is required', (tester) async {
      final (_, draft) = await openAdd(tester);
      final pos = tester.widget<TextField>(
        find.widgetWithText(TextField, 'Part of speech *'),
      );
      expect(pos.controller!.text, isEmpty);

      await fill(tester, ko: '배', en: 'pear');
      await save(tester);

      expect(find.text('Required'), findsOneWidget);
      expect(find.byType(VocabEditDialog), findsOneWidget);
      expect(draft.targetWord, isEmpty);
    });

    testWidgets('Korean and English are required too', (tester) async {
      await openAdd(tester);
      await fill(tester, pos: 'nouns');
      await save(tester);

      expect(find.text('Required'), findsNWidgets(2));
      expect(find.byType(VocabEditDialog), findsOneWidget);
    });

    testWidgets('saves a new word without a duplicate warning', (tester) async {
      final (_, draft) = await openAdd(tester);
      await fill(tester, ko: '배', en: 'pear', pos: 'nouns');
      await save(tester);

      expect(find.byType(VocabEditDialog), findsNothing);
      expect(find.text('Similar vocabulary exists'), findsNothing);
      expect(draft.targetWord, '배');
      expect(draft.pos, 'nouns');
    });

    testWidgets('saves ko_text, audio and notes with the new word', (
      tester,
    ) async {
      final (_, draft) = await openAdd(tester);
      await fill(tester, ko: '3개', en: 'three items', pos: 'numbers');
      await expandTts(tester);
      await tester.enterText(
        find.widgetWithText(TextField, 'Korean TTS text (optional)'),
        '세 개',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Audio URL'),
        'https://example.com/three.mp3',
      );
      await tester.ensureVisible(find.text('Add vocab note'));
      await tester.tap(find.text('Add vocab note'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byWidgetPredicate(
          (widget) =>
              widget is TextField &&
              (widget.decoration?.hintText ?? '').startsWith('Markdown notes'),
        ),
        'Counter for things.',
      );
      await save(tester);

      expect(draft.ttsText, '세 개');
      expect(draft.speechText, '세 개');
      expect(draft.audioUrl, 'https://example.com/three.mp3');
      expect(draft.notes, 'Counter for things.');
    });

    testWidgets('blank ko_text leaves speech on the Korean word', (
      tester,
    ) async {
      final (_, draft) = await openAdd(tester);
      await fill(tester, ko: '배', en: 'pear', pos: 'nouns');
      await save(tester);

      expect(draft.ttsText, isNull);
      expect(draft.speechText, '배');
    });

    Sentence recordedSentence() => Sentence(
      targetText: '배와 사과를 먹어요',
      translationText: 'I eat a pear and an apple',
      audioUrl: 'https://example.com/fruit.mp3',
    );

    testWidgets('each example can use its recording or TTS', (tester) async {
      final pooled = recordedSentence();
      final (provider, _) = await openAdd(tester, pool: [pooled]);
      await fill(tester, ko: '배', en: 'pear', pos: 'nouns');
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pump();

      final useRecording = find.widgetWithText(FilterChip, 'Use recording');
      expect(tester.widget<FilterChip>(useRecording).selected, isTrue);
      await tester.tap(useRecording);
      await tester.pump();
      expect(tester.widget<FilterChip>(useRecording).selected, isFalse);
      expect(pooled.useAudio, isTrue, reason: 'applied on Save, not before');

      await saveAndWait(tester);

      final saved = provider.sentences.firstWhere(
        (s) => s.targetText == '배와 사과를 먹어요',
      );
      expect(saved.useAudio, isFalse);
      expect(saved.audioUrl, 'https://example.com/fruit.mp3');
      expect(saved.playableAudioUrl, isNull);
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('cancelling leaves an example on its recording', (
      tester,
    ) async {
      final pooled = recordedSentence();
      await openAdd(tester, pool: [pooled]);
      await fill(tester, ko: '배', en: 'pear', pos: 'nouns');
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pump();

      await tester.tap(find.widgetWithText(FilterChip, 'Use recording'));
      await tester.pump();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(pooled.useAudio, isTrue);
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('an example without a recording has no choice', (tester) async {
      await openAdd(
        tester,
        pool: [
          Sentence(targetText: '배와 사과를 먹어요', translationText: 'I eat fruit'),
        ],
      );
      await fill(tester, ko: '배', en: 'pear', pos: 'nouns');
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pump();

      expect(exampleTile(), findsOneWidget);
      expect(find.widgetWithText(FilterChip, 'Use recording'), findsNothing);
    });

    testWidgets('a new example can be set to TTS before the word is saved', (
      tester,
    ) async {
      final (provider, _) = await openAdd(tester);

      await tester.tap(find.byTooltip('Create new sentence'));
      await tester.pumpAndSettle();
      await tester.enterText(inSentenceDialog('Sentence'), '**3개** 주세요');
      await tester.enterText(
        inSentenceDialog('Audio URL'),
        'https://e.com/3.mp3',
      );
      await tester.enterText(
        inSentenceDialog('English translation'),
        'Three, please',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilterChip, 'Use recording'));
      await tester.pump();
      await fill(tester, ko: '3개', en: 'three items', pos: 'numbers');
      await saveAndWait(tester);

      final added = provider.sentences.firstWhere(
        (s) => s.targetText == '3개 주세요',
      );
      expect(added.useAudio, isFalse);
      expect(added.audioUrl, 'https://e.com/3.mp3');
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('the Audio URL and TTS sections sit together, URL first', (
      tester,
    ) async {
      await openAdd(tester);

      double top(Finder finder) => tester.getTopLeft(finder).dy;
      final pos = top(find.widgetWithText(TextField, 'Part of speech *'));
      final url = top(find.widgetWithText(TextField, 'Audio URL'));
      final tts = top(find.text('Text-to-speech'));
      expect(pos, lessThan(url));
      expect(url, lessThan(tts));
      expect(
        top(find.widgetWithText(TextField, 'Korean *')),
        lessThan(pos),
        reason: 'TTS no longer sits under the Korean field',
      );
    });

    testWidgets('a recording can be switched off without losing its URL', (
      tester,
    ) async {
      final (_, draft) = await openAdd(tester);
      await fill(tester, ko: '배', en: 'pear', pos: 'nouns');
      expect(find.text('Use this recording'), findsNothing);

      await tester.enterText(
        find.widgetWithText(TextField, 'Audio URL'),
        'https://example.com/pear.mp3',
      );
      await tester.pump();
      final checkbox = find.byType(CheckboxListTile);
      expect(tester.widget<CheckboxListTile>(checkbox).value, isTrue);

      await tester.tap(checkbox);
      await tester.pump();
      await save(tester);

      expect(draft.audioUrl, 'https://example.com/pear.mp3');
      expect(draft.useAudio, isFalse);
      expect(draft.playableAudioUrl, isNull);
    });

    testWidgets(
      'suggests pool sentences for the typed word and links the pick',
      (tester) async {
        final (provider, draft) = await openAdd(
          tester,
          pool: [
            Sentence(targetText: '배를 먹어요', translationText: 'I eat a pear'),
          ],
        );
        final before = provider.sentences.length;
        expect(find.text('Suggested from the pool'), findsNothing);

        await fill(tester, ko: '배', en: 'pear', pos: 'nouns');
        expect(find.text('Suggested from the pool'), findsOneWidget);
        await tester.tap(find.byType(CheckboxListTile));
        await tester.pump();
        expect(find.text('Examples (1)'), findsOneWidget);
        expect(find.text('Suggested from the pool'), findsNothing);

        await save(tester);
        expect(
          provider.sentences.length,
          before,
          reason: 'nothing new in the pool',
        );
        expect(draft.sentenceIds, [
          provider.sentences.firstWhere((s) => s.targetText == '배를 먹어요').id,
        ]);
      },
    );

    testWidgets('a new sentence already in the pool offers the existing one', (
      tester,
    ) async {
      final (provider, _) = await openAdd(
        tester,
        pool: [Sentence(targetText: '배를 먹어요', translationText: 'I eat a pear')],
      );
      final before = provider.sentences.length;

      await tester.tap(find.byTooltip('Create new sentence'));
      await tester.pumpAndSettle();
      await tester.enterText(inSentenceDialog('Sentence'), '**배**를 먹어요');
      await tester.enterText(
        inSentenceDialog('English translation'),
        'I eat a pear',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pumpAndSettle();

      expect(find.text('Sentence already exists'), findsOneWidget);
      await tester.tap(find.text('Use existing'));
      await tester.pumpAndSettle();
      expect(find.text('Examples (1)'), findsOneWidget);
      expect(provider.sentences.length, before);

      // _disposeAfterRouteExit keeps a 1s timer for the closed dialog.
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('a new example joins the pool only when the word is saved', (
      tester,
    ) async {
      final (provider, draft) = await openAdd(tester);
      final before = provider.sentences.length;

      await tester.tap(find.byTooltip('Create new sentence'));
      await tester.pumpAndSettle();
      await tester.enterText(inSentenceDialog('Sentence'), '**3개** 주세요');
      await expandTts(tester, inDialog: true);
      await tester.enterText(
        inSentenceDialog('Korean TTS text (optional)'),
        '세 개 주세요',
      );
      await tester.enterText(
        inSentenceDialog('English translation'),
        'Three, please',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pumpAndSettle();

      expect(find.text('Examples (1)'), findsOneWidget);
      expect(provider.sentences.length, before, reason: 'still only a draft');

      await fill(tester, ko: '3개', en: 'three items', pos: 'numbers');
      await saveAndWait(tester);

      expect(provider.sentences.length, before + 1);
      final added = provider.sentences.firstWhere(
        (s) => s.targetText == '3개 주세요',
      );
      expect(added.ttsText, '세 개 주세요');
      expect(draft.sentenceIds, [added.id]);

      // _disposeAfterRouteExit keeps a 1s timer for the closed dialog.
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('cancelling discards new examples', (tester) async {
      final (provider, draft) = await openAdd(tester);
      final before = provider.sentences.length;

      await tester.tap(find.byTooltip('Create new sentence'));
      await tester.pumpAndSettle();
      await tester.enterText(inSentenceDialog('Sentence'), '**3개** 주세요');
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Remove example'));
      await tester.pump();
      expect(find.text('Examples (0)'), findsOneWidget);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(provider.sentences.length, before);
      expect(draft.sentenceIds, isEmpty);

      // _disposeAfterRouteExit keeps a 1s timer for the closed dialog.
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('tapping an example edits its emphasis with several segments', (
      tester,
    ) async {
      final (provider, draft) = await openAdd(
        tester,
        pool: [
          Sentence(
            targetText: '배와 사과를 먹어요',
            translationText: 'I eat a pear and an apple',
          ),
        ],
      );
      await fill(tester, ko: '배', en: 'pear', pos: 'nouns');
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pump();

      await tester.tap(exampleTile());
      await tester.pumpAndSettle();
      expect(find.text('Edit Example'), findsOneWidget);
      await tester.enterText(
        inSentenceDialog('Sentence'),
        '**배**와 **사과**를 먹어요',
      );
      await tester.pump();
      expect(find.textContaining('Cloze: (___)와 (___)를 먹어요'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Apply'));
      await tester.pumpAndSettle();

      final pooled = provider.sentences.firstWhere(
        (s) => s.translationText == 'I eat a pear and an apple',
      );
      expect(draft.sentenceEmphasis, isEmpty, reason: 'applied on Save');

      await saveAndWait(tester);
      // The pool keeps the plain text; the marking is the word's own. The
      // translation also gets a suggested emphasis for the typed meaning.
      expect(pooled.targetText, '배와 사과를 먹어요');
      expect(pooled.translationText, 'I eat a pear and an apple');
      expect(draft.sentenceIds, [pooled.id]);
      expect(draft.targetTextFor(pooled), '**배**와 **사과**를 먹어요');
      expect(draft.translationTextFor(pooled), 'I eat a **pear** and an apple');
      expect(draft.clozeFor(pooled), '(___)와 (___)를 먹어요');

      // _disposeAfterRouteExit keeps a 1s timer for the closed dialog.
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('cancelling the example editor leaves the sentence alone', (
      tester,
    ) async {
      final (provider, _) = await openAdd(
        tester,
        pool: [
          Sentence(targetText: '배와 사과를 먹어요', translationText: 'I eat fruit'),
        ],
      );
      await fill(tester, ko: '배', en: 'pear', pos: 'nouns');
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pump();

      await tester.tap(exampleTile());
      await tester.pumpAndSettle();
      await tester.enterText(inSentenceDialog('Sentence'), '**배**와 사과를 먹었어요');
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      await save(tester);

      final pooled = provider.sentences.firstWhere(
        (s) => s.translationText == 'I eat fruit',
      );
      expect(pooled.targetText, '배와 사과를 먹어요');

      // _disposeAfterRouteExit keeps a 1s timer for the closed dialog.
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('the example editor needs ** in the sentence', (tester) async {
      await openAdd(
        tester,
        pool: [
          Sentence(targetText: '배와 사과를 먹어요', translationText: 'I eat fruit'),
        ],
      );
      await fill(tester, ko: '배', en: 'pear', pos: 'nouns');
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pump();

      await tester.tap(exampleTile());
      await tester.pumpAndSettle();
      await tester.enterText(inSentenceDialog('Sentence'), '배와 사과를 먹어요');
      await tester.pump();

      expect(
        find.textContaining('Wrap the word being studied in ** **'),
        findsOneWidget,
      );
      final apply = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Apply'),
      );
      expect(apply.onPressed, isNull);
    });

    testWidgets('the example editor fields start one line tall', (
      tester,
    ) async {
      await openAdd(
        tester,
        pool: [
          Sentence(targetText: '배와 사과를 먹어요', translationText: 'I eat fruit'),
        ],
      );
      await fill(tester, ko: '배', en: 'pear', pos: 'nouns');
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pump();

      await tester.tap(exampleTile());
      await tester.pumpAndSettle();

      for (final label in ['Sentence', 'Translation']) {
        final field = tester.widget<TextField>(inSentenceDialog(label));
        expect(field.minLines, 1, reason: label);
      }
      expect(find.text('Korean sentence'), findsNothing);

      // _disposeAfterRouteExit keeps a 1s timer for the closed dialog.
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets(
      'the Add Example notes start as a button and can be previewed',
      (tester) async {
        await openAdd(tester);

        await tester.tap(find.byTooltip('Create new sentence'));
        await tester.pumpAndSettle();
        final inDialog = find.byType(AlertDialog);
        expect(
          find.descendant(of: inDialog, matching: find.text('Preview')),
          findsNothing,
        );
        await tester.tap(
          find.descendant(
            of: inDialog,
            matching: find.text('Add sentence note'),
          ),
        );
        await tester.pumpAndSettle();
        await tester.enterText(
          find.descendant(
            of: inDialog,
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is TextField &&
                  (widget.decoration?.hintText ?? '').startsWith(
                    'Markdown notes',
                  ),
            ),
          ),
          'Eat **slowly**',
        );
        await tester.tap(
          find.descendant(of: inDialog, matching: find.text('Preview')),
        );
        await tester.pumpAndSettle();
        expect(
          find.descendant(of: inDialog, matching: find.byType(MarkdownContent)),
          findsOneWidget,
        );
      },
    );

    testWidgets('a new example without ** is not added', (tester) async {
      final (provider, _) = await openAdd(tester);
      final before = provider.sentences.length;

      await tester.tap(find.byTooltip('Create new sentence'));
      await tester.pumpAndSettle();
      await tester.enterText(inSentenceDialog('Sentence'), '3개 주세요');
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Wrap the word being studied in ** **'),
        findsOneWidget,
      );
      expect(find.text('Examples (0)'), findsOneWidget);
      expect(provider.sentences.length, before);
    });

    testWidgets('editing the text of an example changes the shared sentence', (
      tester,
    ) async {
      final (provider, draft) = await openAdd(
        tester,
        pool: [
          Sentence(targetText: '배와 사과를 먹어요', translationText: 'I eat fruit'),
        ],
      );
      await fill(tester, ko: '배', en: 'pear', pos: 'nouns');
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pump();

      await tester.tap(exampleTile());
      await tester.pumpAndSettle();
      await tester.enterText(inSentenceDialog('Sentence'), '**배**와 사과를 먹었어요');
      await tester.tap(find.widgetWithText(FilledButton, 'Apply'));
      await tester.pumpAndSettle();
      await saveAndWait(tester);

      final pooled = provider.sentences.singleWhere(
        (s) => s.translationText == 'I eat fruit',
      );
      expect(pooled.targetText, '배와 사과를 먹었어요');
      expect(draft.targetTextFor(pooled), '**배**와 사과를 먹었어요');

      // _disposeAfterRouteExit keeps a 1s timer for the closed dialog.
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets(
      'the example editor warns when other words share the sentence',
      (tester) async {
        final (provider, _) = await openAdd(
          tester,
          pool: [
            Sentence(targetText: '배와 사과를 먹어요', translationText: 'I eat fruit'),
          ],
        );
        final sentence = provider.sentences.singleWhere(
          (s) => s.translationText == 'I eat fruit',
        );
        provider.lessons.first.vocabularies.first.sentenceIds.add(sentence.id);
        await fill(tester, ko: '배', en: 'pear', pos: 'nouns');
        await tester.tap(find.byType(CheckboxListTile));
        await tester.pump();

        await tester.tap(exampleTile());
        await tester.pumpAndSettle();

        expect(
          find.textContaining('also used by 1 other word'),
          findsOneWidget,
        );

        // _disposeAfterRouteExit keeps a 1s timer for the closed dialog.
        await tester.pump(const Duration(seconds: 1));
      },
    );

    testWidgets('verbs get the EN ➔ KO card by default', (tester) async {
      final (_, draft) = await openAdd(tester);
      await fill(tester, ko: '만들다', en: 'to make', pos: 'verbs');
      await save(tester);

      expect(draft.cardTargetToNative.isEnabled, isFalse);
      expect(draft.cardNativeToTarget.isEnabled, isTrue);
    });

    testWidgets('warns before adding a word with an existing card front', (
      tester,
    ) async {
      final (_, draft) = await openAdd(tester);
      await fill(tester, ko: '사과', en: 'apology', pos: 'nouns');
      await save(tester);

      expect(find.text('Similar vocabulary exists'), findsOneWidget);
      expect(find.textContaining('사과 — apple'), findsOneWidget);
      expect(draft.targetWord, isEmpty, reason: 'nothing is applied yet');

      await tester.tap(find.text('Go back'));
      await tester.pumpAndSettle();
      expect(find.byType(VocabEditDialog), findsOneWidget);
      expect(draft.targetWord, isEmpty);

      await save(tester);
      await tester.tap(find.text('Add anyway'));
      await tester.pumpAndSettle();
      expect(find.byType(VocabEditDialog), findsNothing);
      expect(draft.targetWord, '사과');
    });

    testWidgets('editing an existing word still shows every field', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      final lesson = await seed(tester, provider, 'L1', 'nouns', '사과', 'apple');
      await pumpWith(
        tester,
        provider,
        opener(
          (context) =>
              VocabEditDialog.show(context, only(lesson), lessonId: lesson.id),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('사과'), findsWidgets);
      expect(find.text('Add vocabulary'), findsNothing);
      expect(find.text('Audio URL', skipOffstage: false), findsOneWidget);
      expect(
        find.text('Korean TTS text (optional)', skipOffstage: false),
        findsOneWidget,
      );
      expect(find.text('ID (optional)', skipOffstage: false), findsOneWidget);
      expect(find.text('KO ➔ EN', skipOffstage: false), findsWidgets);
    });

    Future<void> openEdit(
      WidgetTester tester,
      AppProvider provider,
      Lesson lesson,
    ) async {
      await pumpWith(
        tester,
        provider,
        opener(
          (context) =>
              VocabEditDialog.show(context, only(lesson), lessonId: lesson.id),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('editing keeps the Audio URL and TTS sections together', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      final lesson = await seed(tester, provider, 'L1', 'nouns', '사과', 'apple');
      await openEdit(tester, provider, lesson);

      double top(Finder finder) => tester.getTopLeft(finder).dy;
      final url = top(find.widgetWithText(TextField, 'Audio URL'));
      final tts = top(find.text('Text-to-speech'));
      expect(url, lessThan(tts));
      // Hints, the ID and the other fields are outside the audio pair.
      for (final other in [
        find.text('Hints'),
        find.widgetWithText(TextField, 'ID (optional)'),
        find.widgetWithText(TextField, 'Part of speech'),
        find.widgetWithText(TextField, 'Korean *'),
      ]) {
        final y = top(other);
        expect(y < url || y > tts, isTrue, reason: 'between the audio panels');
      }
    });

    testWidgets('review notes are collapsed, with a preview for each', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      final lesson = await seed(tester, provider, 'L1', 'nouns', '사과', 'apple');
      await openEdit(tester, provider, lesson);

      expect(find.text('Review notes', skipOffstage: false), findsOneWidget);
      expect(find.byType(MarkdownNotesField), findsNothing);

      await tester.ensureVisible(find.text('Review notes'));
      await tester.tap(find.text('Review notes'));
      await tester.pumpAndSettle();
      expect(find.byType(MarkdownNotesField), findsNWidgets(2));

      final koEn = find.byKey(const ValueKey('review-notes-ko-en'));
      final enKo = find.byKey(const ValueKey('review-notes-en-ko'));
      // Each field is a button until a note is started.
      expect(
        find.descendant(of: koEn, matching: find.byType(TextField)),
        findsNothing,
      );
      await tester.tap(
        find.descendant(
          of: koEn,
          matching: find.text('Add KO ➔ EN review note'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(of: koEn, matching: find.byType(TextField)),
        'Use **polite** form',
      );
      await tester.tap(
        find.descendant(of: koEn, matching: find.text('Preview')),
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: koEn, matching: find.byType(TextField)),
        findsNothing,
      );
      expect(
        find.descendant(of: koEn, matching: find.byType(MarkdownContent)),
        findsOneWidget,
      );
      // The other card's field is independent and still just a button.
      expect(
        find.descendant(
          of: enKo,
          matching: find.text('Add EN ➔ KO review note'),
        ),
        findsOneWidget,
      );

      await tester.tap(find.descendant(of: koEn, matching: find.text('Edit')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(
              find.descendant(of: koEn, matching: find.byType(TextField)),
            )
            .controller!
            .text,
        'Use **polite** form',
      );

      await saveAndWait(tester);
      final vocab = only(lesson);
      expect(vocab.cardTargetToNative.backNotes, 'Use **polite** form');
      expect(vocab.cardNativeToTarget.backNotes, isEmpty);
    });

    testWidgets('hint fields are collapsed unless the word needs a hint', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      final lesson = await seed(tester, provider, 'L1', 'nouns', '사과', 'apple');
      await openEdit(tester, provider, lesson);

      const label = 'Front hint, both directions (optional)';
      expect(find.widgetWithText(TextField, label), findsNothing);
      expect(find.text('Hints', skipOffstage: false), findsOneWidget);

      await tester.ensureVisible(find.text('Hints'));
      await tester.tap(find.text('Hints'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, label), findsOneWidget);
      expect(find.text('KO ➔ EN front hint'), findsOneWidget);
      expect(find.text('EN ➔ KO front hint'), findsOneWidget);
    });

    testWidgets('hints start expanded when another card has the same front', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      await seed(tester, provider, 'L1', 'nouns', '사과', 'apple');
      final second = await seed(
        tester,
        provider,
        'L2',
        'nouns',
        '사과',
        'apology',
      );
      await openEdit(tester, provider, second);

      expect(
        find.widgetWithText(
          TextField,
          'Front hint, both directions (optional)',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('has the same front prompt'), findsOneWidget);
    });

    testWidgets('the vocab list warns about a duplicate front prompt', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      await seed(tester, provider, 'L1', 'nouns', '사과', 'apple');
      final second = await seed(
        tester,
        provider,
        'L2',
        'nouns',
        '사과',
        'apology',
      );
      await pumpWith(tester, provider, LessonDetailView(lessonId: second.id));

      expect(
        find.textContaining('KO ➔ EN card has the same front as 사과 — apple'),
        findsOneWidget,
      );

      await tester.tap(find.textContaining('has the same front as'));
      await tester.pumpAndSettle();
      expect(find.byType(VocabEditDialog), findsOneWidget);
      expect(
        find.widgetWithText(
          TextField,
          'Front hint, both directions (optional)',
        ),
        findsOneWidget,
      );
    });

    testWidgets('the vocab list has no warning without duplicates', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      final lesson = await seed(tester, provider, 'L1', 'nouns', '사과', 'apple');
      await pumpWith(tester, provider, LessonDetailView(lessonId: lesson.id));

      expect(find.textContaining('has the same front as'), findsNothing);
    });

    testWidgets(
      'lesson menu offers one word or YAML, prefilled with the name',
      (tester) async {
        final provider = await loadedProvider(tester);
        final lesson = await seed(
          tester,
          provider,
          'L1',
          'nouns',
          '사과',
          'apple',
        );
        await pumpWith(tester, provider, LessonDetailView(lessonId: lesson.id));

        await tester.tap(find.byIcon(Icons.add_circle_outline));
        await tester.pumpAndSettle();
        expect(find.text('Add manually'), findsOneWidget);
        expect(find.text('Add from YAML'), findsOneWidget);

        await tester.tap(find.text('Add from YAML'));
        await tester.pumpAndSettle();
        expect(find.byType(YamlImportView), findsOneWidget);
        final texts = tester
            .widgetList<TextField>(find.byType(TextField))
            .map((field) => field.controller?.text)
            .toList();
        expect(texts, contains('L1'));
      },
    );
  });
}
