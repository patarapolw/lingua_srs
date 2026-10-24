import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/lesson.dart';
import 'package:lingua_srs/models/srs_card.dart';
import 'package:lingua_srs/providers/app_provider.dart';
import 'package:lingua_srs/services/audio_service.dart';
import 'package:lingua_srs/services/storage_service.dart';
import 'package:lingua_srs/views/lesson_detail_view.dart';
import 'package:lingua_srs/views/lesson_list_view.dart';
import 'package:lingua_srs/views/settings_dialog.dart';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory storageDirectory;

  setUp(() {
    storageDirectory = Directory.systemTemp.createTempSync(
      'lingua_srs_new_vs_due_widget_test_',
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

  /// Imports one lesson of nouns, then sets how many are due and how many
  /// already started in the last 24 hours. The rest stay new.
  Future<Lesson> seedLesson(
    WidgetTester tester,
    AppProvider provider, {
    required int total,
    int due = 0,
    int introducedRecently = 0,
    String title = 'Lesson',
  }) async {
    final words = [
      for (var i = 0; i < total; i++) '    - ko: 단어$i\n      en: word $i',
    ].join('\n');
    final yaml = '---\nvocabulary:\n  nouns:\n$words\n---\n# $title\n';
    final lesson = (await tester.runAsync(() => provider.importYaml(yaml)))!;
    final now = DateTime.now();
    for (var i = 0; i < due; i++) {
      final card = lesson.vocabularies[i].cardTargetToNative;
      card.status = SrsStatus.review;
      card.dueDate = now.subtract(const Duration(days: 1));
    }
    for (var i = due; i < due + introducedRecently; i++) {
      final card = lesson.vocabularies[i].cardTargetToNative;
      card.status = SrsStatus.review;
      card.dueDate = now.add(const Duration(days: 1));
      card.introducedAt = now.subtract(const Duration(hours: 1));
    }
    return lesson;
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

  group('Dashboard', () {
    testWidgets('shows due and new cards separately', (tester) async {
      final provider = await loadedProvider(tester);
      await seedLesson(tester, provider, total: 5, due: 2);
      await pumpWith(tester, provider, const LessonListView());

      expect(find.text('Study (2 due + 3 new)'), findsOneWidget);
      expect(find.text('3 new'), findsOneWidget);
      expect(find.text('2 Due'), findsOneWidget);
      expect(find.text('3 New'), findsOneWidget);
    });

    testWidgets('does not count new cards as due', (tester) async {
      final provider = await loadedProvider(tester);
      await seedLesson(tester, provider, total: 4);
      await pumpWith(tester, provider, const LessonListView());

      expect(find.text('Study (4 new)'), findsOneWidget);
      expect(find.textContaining('due)'), findsNothing);
      expect(find.text('4 Due'), findsNothing);
    });

    testWidgets('caps the new count at the daily new-card limit', (
      tester,
    ) async {
      final provider = await loadedProvider(tester, {
        'lingua_srs_max_new_cards_24h': 2,
      });
      await seedLesson(tester, provider, total: 5);
      await pumpWith(tester, provider, const LessonListView());

      expect(find.text('Study (2 new)'), findsOneWidget);
      expect(find.text('Study (5 new)'), findsNothing);
    });

    testWidgets('a used-up review limit does not block new cards', (
      tester,
    ) async {
      final provider = await loadedProvider(tester, {
        'lingua_srs_max_reviews_24h': 1,
      });
      await seedLesson(tester, provider, total: 5, due: 3);
      await pumpWith(tester, provider, const LessonListView());

      expect(find.text('Study (1 due + 2 new)'), findsOneWidget);
      expect(find.text('3 remaining'), findsOneWidget);
    });

    testWidgets('a used-up new-card limit does not block due cards', (
      tester,
    ) async {
      final provider = await loadedProvider(tester, {
        'lingua_srs_max_new_cards_24h': 1,
      });
      await seedLesson(
        tester,
        provider,
        total: 4,
        due: 2,
        introducedRecently: 1,
      );
      await pumpWith(tester, provider, const LessonListView());

      expect(provider.remainingNewCards24h, 0);
      expect(find.text('Study (2 due)'), findsOneWidget);
    });

    testWidgets('says Daily Limit once both limits are used up', (
      tester,
    ) async {
      final provider = await loadedProvider(tester, {
        'lingua_srs_max_new_cards_24h': 1,
      });
      await seedLesson(tester, provider, total: 3, introducedRecently: 1);
      await pumpWith(tester, provider, const LessonListView());

      expect(find.text('Daily Limit'), findsOneWidget);
      expect(find.textContaining('Study ('), findsNothing);

      await tester.tap(find.text('Daily Limit'));
      await tester.pumpAndSettle();

      expect(find.text('Daily 24h Limit Reached'), findsOneWidget);
      expect(
        find.textContaining('started 1 new cards (limit 1)'),
        findsOneWidget,
      );
    });

    testWidgets('the limit dialog opens Settings', (tester) async {
      final provider = await loadedProvider(tester, {
        'lingua_srs_max_new_cards_24h': 1,
      });
      await seedLesson(tester, provider, total: 3, introducedRecently: 1);
      await pumpWith(tester, provider, const LessonListView());

      await tester.tap(find.text('Daily Limit'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open Settings'));
      await tester.pumpAndSettle();

      expect(find.byType(SettingsDialog), findsOneWidget);
    });

    testWidgets('has nothing to study when every card is scheduled later', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      await seedLesson(tester, provider, total: 2, introducedRecently: 2);
      await pumpWith(tester, provider, const LessonListView());

      expect(find.text('Study (0 due)'), findsOneWidget);
      expect(find.text('Daily Limit'), findsNothing);
    });
  });

  group('Lesson detail', () {
    testWidgets('Study button counts due and new cards', (tester) async {
      final provider = await loadedProvider(tester);
      final lesson = await seedLesson(tester, provider, total: 3, due: 1);
      await pumpWith(tester, provider, LessonDetailView(lessonId: lesson.id));

      expect(find.text('Study (1 Due + 2 New)'), findsOneWidget);
    });

    testWidgets('Study button counts only the new cards still allowed', (
      tester,
    ) async {
      final provider = await loadedProvider(tester, {
        'lingua_srs_max_new_cards_24h': 1,
      });
      final lesson = await seedLesson(tester, provider, total: 3);
      await pumpWith(tester, provider, LessonDetailView(lessonId: lesson.id));

      expect(find.text('Study (0 Due + 1 New)'), findsOneWidget);
    });

    testWidgets('Study button omits New when none are left to start', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      final lesson = await seedLesson(tester, provider, total: 2, due: 2);
      await pumpWith(tester, provider, LessonDetailView(lessonId: lesson.id));

      expect(find.text('Study (2 Due)'), findsOneWidget);
    });

    testWidgets('card chips say New for unseen cards and Due for due ones', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      final lesson = await seedLesson(tester, provider, total: 3, due: 1);
      await pumpWith(tester, provider, LessonDetailView(lessonId: lesson.id));

      expect(find.text('KO ➔ EN (New)', skipOffstage: false), findsNWidgets(2));
      expect(find.text('KO ➔ EN (Due)', skipOffstage: false), findsOneWidget);
    });
  });

  group('Settings dialog', () {
    Future<void> openSettings(WidgetTester tester, AppProvider provider) async {
      await pumpWith(
        tester,
        provider,
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => const SettingsDialog(),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    final reviewsField = find.widgetWithText(
      TextField,
      'Max reviews per 24 hours',
    );
    final newCardsField = find.widgetWithText(
      TextField,
      'Max new cards per 24 hours',
    );
    String textOf(WidgetTester tester, Finder field) =>
        tester.widget<TextField>(field).controller!.text;

    testWidgets('starts at 100 reviews and 10 new cards', (tester) async {
      final provider = await loadedProvider(tester);
      await openSettings(tester, provider);

      expect(textOf(tester, reviewsField), '100');
      expect(textOf(tester, newCardsField), '10');
    });

    testWidgets('shows the saved limits', (tester) async {
      final provider = await loadedProvider(tester, {
        'lingua_srs_max_reviews_24h': 40,
        'lingua_srs_max_new_cards_24h': 7,
      });
      await openSettings(tester, provider);

      expect(textOf(tester, reviewsField), '40');
      expect(textOf(tester, newCardsField), '7');
    });

    testWidgets('Save stores both limits', (tester) async {
      final provider = await loadedProvider(tester);
      await openSettings(tester, provider);

      await tester.ensureVisible(newCardsField);
      await tester.enterText(reviewsField, '150');
      await tester.enterText(newCardsField, '3');
      final save = find.widgetWithText(FilledButton, 'Save');
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();

      expect(provider.maxReviews24h, 150);
      expect(provider.maxNewCards24h, 3);
      expect(await tester.runAsync(StorageService.loadMaxNewCards24h), 3);
      expect(find.byType(SettingsDialog), findsNothing);
    });

    testWidgets('0 means unlimited new cards', (tester) async {
      final provider = await loadedProvider(tester);
      await openSettings(tester, provider);

      await tester.ensureVisible(newCardsField);
      await tester.enterText(newCardsField, '0');
      final save = find.widgetWithText(FilledButton, 'Save');
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();

      expect(provider.maxNewCards24h, 0);
      expect(provider.remainingNewCards24h, greaterThan(1000));
    });

    testWidgets('the preset chips fill the new-card field', (tester) async {
      final provider = await loadedProvider(tester);
      await openSettings(tester, provider);

      final twenty = find.widgetWithText(ActionChip, '20');
      await tester.ensureVisible(twenty);
      await tester.tap(twenty);
      await tester.pump();
      expect(textOf(tester, newCardsField), '20');

      // Both limit sections have an Unlimited chip; the new-card one is last.
      final unlimited = find.widgetWithText(ActionChip, 'Unlimited').last;
      await tester.ensureVisible(unlimited);
      await tester.tap(unlimited);
      await tester.pump();
      expect(textOf(tester, newCardsField), '0');
      expect(textOf(tester, reviewsField), '100');
    });

    testWidgets('an invalid new-card value is rejected and nothing is saved', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      await openSettings(tester, provider);

      await tester.ensureVisible(newCardsField);
      await tester.enterText(reviewsField, '150');
      await tester.enterText(newCardsField, 'abc');
      final save = find.widgetWithText(FilledButton, 'Save');
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();

      expect(
        find.text('Enter a whole number, or 0 for unlimited.'),
        findsOneWidget,
      );
      expect(find.byType(SettingsDialog), findsOneWidget);
      expect(provider.maxReviews24h, 100);
      expect(provider.maxNewCards24h, 10);
    });

    testWidgets('a negative review limit is rejected too', (tester) async {
      final provider = await loadedProvider(tester);
      await openSettings(tester, provider);

      await tester.ensureVisible(reviewsField);
      await tester.enterText(reviewsField, '-5');
      final save = find.widgetWithText(FilledButton, 'Save');
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();

      expect(
        find.text('Enter a whole number, or 0 for unlimited.'),
        findsOneWidget,
      );
      expect(provider.maxNewCards24h, 10);
    });
  });
}
