import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lingua_srs/models/lesson.dart';
import 'package:lingua_srs/models/srs_card.dart';
import 'package:lingua_srs/models/vocab_item.dart';
import 'package:lingua_srs/services/audio_service.dart';
import 'package:lingua_srs/views/similar_meanings_dialog.dart';
import 'package:lingua_srs/views/similar_search_dialog.dart';
import 'package:lingua_srs/views/study_view.dart';
import 'package:lingua_srs/views/vocab_edit_dialog.dart';
import 'package:lingua_srs/views/vocab_merge_dialogs.dart';

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
      ChangeNotifierProvider(
        create: (_) => provider,
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

  testWidgets('Settings toggles romanization and IPA per target', (
    tester,
  ) async {
    final provider = await pumpApp(tester);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();

    Future<void> flip(String label) async {
      final finder = find.descendant(
        of: find.widgetWithText(Row, label),
        matching: find.byType(Switch),
      );
      await tester.ensureVisible(finder);
      await tester.tap(finder);
      await tester.pumpAndSettle();
    }

    await flip('Vocabulary romanization');
    expect(provider.showRomanization(PronunciationTarget.vocabulary), isTrue);
    expect(provider.showRomanization(PronunciationTarget.sentence), isFalse);

    await flip('Sentence IPA');
    expect(provider.showIpa(PronunciationTarget.sentence), isTrue);
    expect(provider.showIpa(PronunciationTarget.vocabulary), isFalse);
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

    testWidgets('toggled from the strip, live on the same card', (
      tester,
    ) async {
      final provider = await openStudy(
        tester,
        direction: CardDirection.targetToNative,
        yaml: withSentence,
      );
      await reveal(tester);
      expect(find.text('bae'), findsNothing);

      Future<void> tapToggle(String target, String kind) async {
        await tester.tap(find.byKey(ValueKey('pronunciation-$target-$kind')));
        await tester.pumpAndSettle();
      }

      await tapToggle('vocabulary', 'romanization');
      expect(provider.showRomanization(PronunciationTarget.vocabulary), isTrue);
      expect(find.text('bae'), findsOneWidget);
      expect(find.text(sentenceRomanization), findsNothing);

      await tapToggle('sentence', 'romanization');
      expect(find.text(sentenceRomanization), findsOneWidget);

      await tapToggle('vocabulary', 'romanization'); // and back off
      expect(find.text('bae'), findsNothing);
      expect(find.text(sentenceRomanization), findsOneWidget);
    });

    testWidgets('strip fits and works on a narrow phone', (tester) async {
      final provider = await openStudy(
        tester,
        direction: CardDirection.targetToNative,
      );
      tester.view.physicalSize = const Size(360, 800);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull); // no RenderFlex overflow

      await tester.tap(
        find.byKey(const ValueKey('pronunciation-sentence-ipa')),
      );
      await tester.pumpAndSettle();
      expect(provider.showIpa(PronunciationTarget.sentence), isTrue);
      expect(provider.showIpa(PronunciationTarget.vocabulary), isFalse);
    });

    testWidgets('autoplay is a toggle button in the app bar', (tester) async {
      final provider = await openStudy(
        tester,
        direction: CardDirection.targetToNative,
      );
      expect(provider.autoplayAudio, isTrue);
      await tester.tap(find.byTooltip('Autoplay audio'));
      await tester.pumpAndSettle();
      expect(provider.autoplayAudio, isFalse);
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
    ) => MockClient((_) async {
      counter.add(1);
      return aiOk({
        'merges': [
          {
            'group': 1,
            'keep': only(a()).id,
            'merge': [only(b()).id],
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
      late Lesson a, b;
      final client = MockClient((_) async {
        calls++;
        if (calls == 1) return http.Response('boom', 500);
        return aiOk({
          'merges': [
            {
              'group': 1,
              'keep': only(a).id,
              'merge': [only(b).id],
              'reason': 'same word',
            },
          ],
        });
      });
      final (_, a0, b0) = await setup(tester, client);
      a = a0;
      b = b0;
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
}
