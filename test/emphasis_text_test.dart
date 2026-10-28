import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/providers/app_provider.dart';
import 'package:lingua_srs/services/audio_service.dart';
import 'package:lingua_srs/views/study_view.dart';
import 'package:lingua_srs/widgets/emphasis_text.dart';
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

List<(String, bool)> segmentsOf(String text) => [
  for (final s in EmphasisText.segments(text)) (s.text, s.emphasized),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('EmphasisText.segments', () {
    test('plain text is one plain segment', () {
      expect(segmentsOf('저는 사과를 먹어요.'), [('저는 사과를 먹어요.', false)]);
    });

    test('bolds the text between a pair of markers', () {
      expect(segmentsOf('저는 **사과**를 먹어요.'), [
        ('저는 ', false),
        ('사과', true),
        ('를 먹어요.', false),
      ]);
    });

    test('handles several emphasized segments and the text edges', () {
      expect(segmentsOf('**배**와 **사과**'), [
        ('배', true),
        ('와 ', false),
        ('사과', true),
      ]);
    });

    test('keeps a marker that is never closed as typed', () {
      expect(segmentsOf('I eat **an apple'), [('I eat **an apple', false)]);
      expect(segmentsOf('**'), [('**', false)]);
    });

    test('keeps the closed pairs before an unclosed marker', () {
      expect(segmentsOf('a **b** c **d'), [
        ('a ', false),
        ('b', true),
        (' c **d', false),
      ]);
    });

    test('drops empty segments', () {
      expect(segmentsOf('****'), isEmpty);
      expect(segmentsOf(''), isEmpty);
    });

    test('does not interpret any other Markdown', () {
      expect(segmentsOf('a *b* _c_ __d__ [e](f) (___)'), [
        ('a *b* _c_ __d__ [e](f) (___)', false),
      ]);
    });
  });

  group('EmphasisText widget', () {
    Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(colorScheme: const ColorScheme.light()),
        home: Scaffold(body: child),
      ),
    );

    List<TextSpan> spansOf(WidgetTester tester) {
      final text = tester.widget<Text>(
        find.descendant(
          of: find.byType(EmphasisText),
          matching: find.byType(Text),
        ),
      );
      return (text.textSpan! as TextSpan).children!.cast<TextSpan>();
    }

    testWidgets('shows emphasis in bold without the markers', (tester) async {
      await pump(tester, const EmphasisText('저는 **사과**를 먹어요.'));

      final spans = spansOf(tester);
      expect(spans.map((s) => s.text), ['저는 ', '사과', '를 먹어요.']);
      expect(spans[0].style, isNull);
      expect(spans[1].style?.fontWeight, FontWeight.bold);
      expect(spans[2].style, isNull);
      expect(
        find.textContaining('**', findRichText: true),
        findsNothing,
        reason: 'markers are not shown',
      );
    });

    testWidgets('uses the given style and alignment', (tester) async {
      const style = TextStyle(fontSize: 31);
      await pump(
        tester,
        const EmphasisText(
          'a **b**',
          style: style,
          textAlign: TextAlign.center,
        ),
      );

      final text = tester.widget<Text>(
        find.descendant(
          of: find.byType(EmphasisText),
          matching: find.byType(Text),
        ),
      );
      expect(text.style, style);
      expect(text.textAlign, TextAlign.center);
    });

    testWidgets('takes no space when there is nothing to show', (tester) async {
      await pump(tester, const EmphasisText('   '));

      expect(
        find.descendant(
          of: find.byType(EmphasisText),
          matching: find.byType(Text),
        ),
        findsNothing,
      );
    });
  });

  group('Review card', () {
    const pathProviderChannel = MethodChannel(
      'plugins.flutter.io/path_provider',
    );
    late Directory storageDirectory;

    setUp(() {
      storageDirectory = Directory.systemTemp.createTempSync(
        'lingua_srs_emphasis_text_test_',
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

    testWidgets('shows the sentence and its translation with bold emphasis', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      const yaml =
          '---\nvocabulary:\n  nouns:\n    - ko: 감귤\n      en: tangerine\n'
          '      examples:\n'
          '        - ko: "저는 **감귤**을 먹어요."\n'
          '          en: "I eat a **tangerine**."\n'
          '---\n# Lesson\n';
      final lesson = (await tester.runAsync(() => provider.importYaml(yaml)))!;

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

      // Front: the sentence, with the word in bold.
      expect(
        find.textContaining('저는 감귤을 먹어요.', findRichText: true),
        findsOneWidget,
      );
      final boldWord = find.byWidgetPredicate(
        (w) =>
            w is Text &&
            w.textSpan is TextSpan &&
            (w.textSpan! as TextSpan).children!.any(
              (c) =>
                  c is TextSpan &&
                  c.text == '감귤' &&
                  c.style?.fontWeight == FontWeight.bold,
            ),
      );
      expect(boldWord, findsOneWidget);

      // Back: the translation as well, and no marker is ever shown.
      await tester.tap(find.textContaining('Show Answer'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('I eat a tangerine.', findRichText: true),
        findsOneWidget,
      );
      expect(find.textContaining('**', findRichText: true), findsNothing);
    });
  });
}
