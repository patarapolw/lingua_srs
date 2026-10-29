import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/sentence.dart';
import 'package:lingua_srs/providers/app_provider.dart';
import 'package:lingua_srs/services/audio_service.dart';
import 'package:lingua_srs/views/sentence_pool_view.dart';
import 'package:lingua_srs/views/vocab_edit_dialog.dart';
import 'package:lingua_srs/views/vocab_pool_view.dart';
import 'package:lingua_srs/widgets/adaptive_scaffold.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Lesson tabs must not touch real audio plugins.
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory storageDirectory;

  setUp(() {
    storageDirectory = Directory.systemTemp.createTempSync(
      'lingua_srs_vocab_pool_view_test_',
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
    expect(
      provider.isLoading,
      isFalse,
      reason: 'provider never finished loading',
    );
    return provider;
  }

  /// Imports a lesson with the given words, each `(pos, ko, en)`.
  Future<void> importLesson(
    WidgetTester tester,
    AppProvider provider,
    String title,
    List<(String, String, String)> words,
  ) async {
    final byPos = <String, List<String>>{};
    for (final (pos, ko, en) in words) {
      byPos.putIfAbsent(pos, () => []).add('    - ko: $ko\n      en: $en');
    }
    final sections = [
      for (final e in byPos.entries) '  ${e.key}:\n${e.value.join('\n')}',
    ].join('\n');
    final yaml = '---\nvocabulary:\n$sections\n---\n# $title\n';
    await tester.runAsync(() => provider.importYaml(yaml));
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

  Future<AppProvider> seeded(WidgetTester tester) async {
    final provider = await loadedProvider(tester);
    await importLesson(tester, provider, 'Food', [
      ('verbs', '먹다', 'to eat'),
      ('verbs', '마시다', 'to drink'),
      ('nouns', '사과', 'apple'),
    ]);
    await importLesson(tester, provider, 'Travel', [
      ('verbs', '먹다', 'to eat'),
      ('nouns', '공항', 'airport'),
    ]);
    return provider;
  }

  group('VocabPoolView', () {
    testWidgets('shows a message when there is no vocabulary', (tester) async {
      final provider = await loadedProvider(tester);
      await pumpWith(tester, provider, const VocabPoolView());

      expect(find.text('Vocab Pool'), findsOneWidget);
      expect(find.text('The Vocab Pool is currently empty.'), findsOneWidget);
      expect(find.text('0 words'), findsOneWidget);
    });

    testWidgets('lists each distinct word once, with its lessons', (
      tester,
    ) async {
      final provider = await seeded(tester);
      await pumpWith(tester, provider, const VocabPoolView());

      // 먹다 is in both lessons but is one word.
      expect(find.text('4 words'), findsOneWidget);
      expect(find.text('먹다'), findsOneWidget);
      expect(find.text('마시다'), findsOneWidget);
      expect(find.text('사과'), findsOneWidget);
      expect(find.text('공항'), findsOneWidget);
      expect(find.text('Food · Travel'), findsOneWidget);
      expect(find.text('Food'), findsNWidgets(2)); // 마시다, 사과
    });

    testWidgets('searches in Korean', (tester) async {
      final provider = await seeded(tester);
      await pumpWith(tester, provider, const VocabPoolView());

      await tester.enterText(find.byType(TextField), '사과');
      await tester.pump();

      // The search field also holds 사과, so look only inside the cards.
      expect(
        find.descendant(of: find.byType(Card), matching: find.text('사과')),
        findsOneWidget,
      );
      expect(find.text('먹다'), findsNothing);
      expect(find.text('1 of 4 words'), findsOneWidget);
    });

    testWidgets('searches in English', (tester) async {
      final provider = await seeded(tester);
      await pumpWith(tester, provider, const VocabPoolView());

      await tester.enterText(find.byType(TextField), 'airport');
      await tester.pump();

      expect(find.text('공항'), findsOneWidget);
      expect(find.text('먹다'), findsNothing);
      expect(find.text('1 of 4 words'), findsOneWidget);
    });

    testWidgets('says so when nothing matches, and clearing restores all', (
      tester,
    ) async {
      final provider = await seeded(tester);
      await pumpWith(tester, provider, const VocabPoolView());

      await tester.enterText(find.byType(TextField), 'zzz');
      await tester.pump();
      expect(find.text('No vocabulary matched your query.'), findsOneWidget);
      expect(find.text('0 of 4 words'), findsOneWidget);

      await tester.tap(find.byTooltip('Clear search'));
      await tester.pump();
      expect(find.text('No vocabulary matched your query.'), findsNothing);
      expect(find.text('4 words'), findsOneWidget);
    });

    testWidgets('filters by part of speech', (tester) async {
      final provider = await seeded(tester);
      await pumpWith(tester, provider, const VocabPoolView());

      await tester.tap(find.widgetWithText(FilterChip, 'verbs'));
      await tester.pump();
      expect(find.text('먹다'), findsOneWidget);
      expect(find.text('마시다'), findsOneWidget);
      expect(find.text('사과'), findsNothing);
      expect(find.text('2 of 4 words'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilterChip, 'All'));
      await tester.pump();
      expect(find.text('사과'), findsOneWidget);
      expect(find.text('4 words'), findsOneWidget);
    });

    testWidgets('shows underscores in a part of speech as spaces', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      await importLesson(tester, provider, 'Places', [
        ('proper_nouns', '서울', 'Seoul'),
      ]);
      await pumpWith(tester, provider, const VocabPoolView());

      expect(find.widgetWithText(FilterChip, 'proper nouns'), findsOneWidget);
      expect(find.text('proper_nouns'), findsNothing);
      expect(find.text('proper nouns'), findsNWidgets(2)); // chip and badge

      // Filtering still works on the stored spelling.
      await tester.tap(find.widgetWithText(FilterChip, 'proper nouns'));
      await tester.pump();
      expect(find.text('서울'), findsOneWidget);
    });

    testWidgets('lists the part of speech with the most words first', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      await importLesson(tester, provider, 'Mixed', [
        ('verbs', '먹다', 'to eat'),
        ('nouns', '사과', 'apple'),
        ('nouns', '공항', 'airport'),
        ('nouns', '학교', 'school'),
        ('proper_nouns', '서울', 'Seoul'),
        ('proper_nouns', '부산', 'Busan'),
      ]);
      await pumpWith(tester, provider, const VocabPoolView());

      double left(String label) =>
          tester.getTopLeft(find.widgetWithText(FilterChip, label)).dx;
      expect(left('All'), lessThan(left('nouns')));
      expect(left('nouns'), lessThan(left('proper nouns')));
      expect(left('proper nouns'), lessThan(left('verbs')));
    });

    testWidgets('tapping a word opens its editor', (tester) async {
      final provider = await seeded(tester);
      await pumpWith(tester, provider, const VocabPoolView());

      await tester.tap(find.text('공항'));
      await tester.pumpAndSettle();

      expect(find.byType(VocabEditDialog), findsOneWidget);
    });
  });

  group('Search box', () {
    String? hint(WidgetTester tester) =>
        tester.widget<TextField>(find.byType(TextField)).decoration?.hintText;

    testWidgets('has the whole width on a narrow screen', (tester) async {
      final provider = await seeded(tester);
      for (final home in [const VocabPoolView(), const SentencePoolView()]) {
        await pumpWith(tester, provider, home, size: const Size(360, 800));

        // Full width minus the 16 padding on each side, so no hint collapses.
        expect(tester.getSize(find.byType(TextField)).width, 360 - 32);
      }
    });

    testWidgets(
      'Vocab Pool puts the count and part-of-speech chips on a line',
      (tester) async {
        final provider = await seeded(tester);
        await pumpWith(
          tester,
          provider,
          const VocabPoolView(),
          size: const Size(360, 800),
        );

        final field = find.byType(TextField);
        final count = find.byType(Chip);
        final all = find.widgetWithText(FilterChip, 'All');
        expect(
          tester.getTopLeft(count).dy,
          greaterThanOrEqualTo(tester.getBottomLeft(field).dy),
        );
        expect(
          tester.getCenter(count).dy,
          closeTo(tester.getCenter(all).dy, 1),
        );
        expect(
          tester.getTopLeft(all).dx,
          greaterThanOrEqualTo(tester.getTopRight(count).dx),
        );
      },
    );

    testWidgets('Sentence Pool shows its count as a line under the box', (
      tester,
    ) async {
      final provider = await seeded(tester);
      await tester.runAsync(() async {
        await provider.addSentenceToPool(
          Sentence(targetText: '사과를 먹어요', translationText: 'I eat an apple'),
        );
        await provider.addSentenceToPool(
          Sentence(
            targetText: '공항에 가요',
            translationText: 'I go to the airport',
          ),
        );
      });
      await pumpWith(
        tester,
        provider,
        const SentencePoolView(),
        size: const Size(360, 800),
      );

      expect(find.byType(Chip), findsNothing);
      expect(hint(tester), 'Search sentences');
      expect(find.text('2 sentences'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('2 sentences')).dy,
        greaterThanOrEqualTo(tester.getBottomLeft(find.byType(TextField)).dy),
      );
      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.text('2 sentences'),
        ),
        findsNothing,
      );
    });

    testWidgets('Sentence Pool says "1 sentence" for a single one', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      await tester.runAsync(
        () => provider.addSentenceToPool(
          Sentence(targetText: '사과를 먹어요', translationText: 'I eat an apple'),
        ),
      );
      await pumpWith(
        tester,
        provider,
        const SentencePoolView(),
        size: const Size(360, 800),
      );

      expect(find.text('1 sentence'), findsOneWidget);
    });

    testWidgets('shares the row with the count on a wide screen', (
      tester,
    ) async {
      final provider = await seeded(tester);
      for (final home in [const VocabPoolView(), const SentencePoolView()]) {
        await pumpWith(tester, provider, home);

        final field = find.byType(TextField);
        final chip = find.byType(Chip);
        expect(
          tester.getTopLeft(chip).dx,
          greaterThanOrEqualTo(tester.getTopRight(field).dx),
        );
        expect(
          tester.getCenter(chip).dy,
          closeTo(tester.getCenter(field).dy, 1),
        );
      }
    });

    testWidgets('hints say what is searched', (tester) async {
      final provider = await seeded(tester);
      await pumpWith(tester, provider, const VocabPoolView());
      expect(hint(tester), 'Search Korean or English');

      await pumpWith(tester, provider, const SentencePoolView());
      expect(hint(tester), 'Search sentences');
    });
  });

  group('Sentence Pool rows', () {
    testWidgets('have no edit button, but tapping one edits it', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      await tester.runAsync(
        () => provider.addSentenceToPool(
          Sentence(targetText: '사과를 먹어요', translationText: 'I eat an apple'),
        ),
      );
      await pumpWith(tester, provider, const SentencePoolView());

      expect(find.byTooltip('Edit Sentence'), findsNothing);
      expect(find.byIcon(Icons.edit_outlined), findsNothing);

      await tester.tap(find.text('I eat an apple'));
      await tester.pumpAndSettle();

      expect(find.text('Edit Sentence'), findsOneWidget); // the dialog title
    });
  });

  group('Vocab Pool tab', () {
    testWidgets('is in the navigation rail on wide screens', (tester) async {
      final provider = await seeded(tester);
      await pumpWith(
        tester,
        provider,
        const AdaptiveScaffold(),
        size: const Size(1400, 900),
      );

      await tester.tap(find.text('Vocab Pool'));
      await tester.pumpAndSettle();

      expect(find.byType(VocabPoolView), findsOneWidget);
      expect(find.text('4 words'), findsOneWidget);
    });

    testWidgets('is in the bottom bar on narrow screens', (tester) async {
      final provider = await seeded(tester);
      await pumpWith(
        tester,
        provider,
        const AdaptiveScaffold(),
        size: const Size(420, 900),
      );

      await tester.tap(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text('Vocab'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(VocabPoolView), findsOneWidget);
      expect(find.text('4 words'), findsOneWidget);
    });
  });
}
