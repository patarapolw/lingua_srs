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
import 'package:lingua_srs/views/study_view.dart';
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

  // The Study button of the dashboard banner (the bolt icon one).
  Finder bannerStudyButton() => find.ancestor(
    of: find.byIcon(Icons.bolt_rounded),
    matching: find.byWidgetPredicate((widget) => widget is FilledButton),
  );
  Finder bannerLimitButton() => find.ancestor(
    of: find.byIcon(Icons.check_circle_outline),
    matching: find.byWidgetPredicate((widget) => widget is FilledButton),
  );

  group('Dashboard', () {
    testWidgets('shows due and new cards separately', (tester) async {
      final provider = await loadedProvider(tester);
      await seedLesson(tester, provider, total: 5, due: 2);
      await pumpWith(tester, provider, const LessonListView());

      expect(find.text('Study (5)'), findsOneWidget);
      expect(find.text('2 due • '), findsOneWidget);
      expect(find.text('3 new'), findsOneWidget);
      expect(find.text('5 words'), findsOneWidget);
      expect(find.text('2 Due'), findsOneWidget);
      expect(find.text('3 New'), findsOneWidget);
    });

    testWidgets('does not count new cards as due', (tester) async {
      final provider = await loadedProvider(tester);
      await seedLesson(tester, provider, total: 4);
      await pumpWith(tester, provider, const LessonListView());

      expect(find.text('Study (4)'), findsOneWidget);
      expect(find.text('4 new'), findsOneWidget);
      expect(find.text('4 New'), findsOneWidget);
      expect(find.textContaining('due'), findsNothing);
      expect(find.textContaining('Due'), findsNothing);
    });

    testWidgets('caps the new count at the daily new-card limit', (
      tester,
    ) async {
      final provider = await loadedProvider(tester, {
        'lingua_srs_max_new_cards_24h': 2,
      });
      await seedLesson(tester, provider, total: 5);
      await pumpWith(tester, provider, const LessonListView());

      expect(find.text('Study (2)'), findsOneWidget);
      expect(find.text('2 new'), findsOneWidget);
      // The lesson row still says what the lesson holds.
      expect(find.text('5 words'), findsOneWidget);
      expect(find.text('5 New'), findsOneWidget);
    });

    testWidgets('a used-up review limit does not block new cards', (
      tester,
    ) async {
      final provider = await loadedProvider(tester, {
        'lingua_srs_max_reviews_24h': 1,
      });
      await seedLesson(tester, provider, total: 5, due: 3);
      await pumpWith(tester, provider, const LessonListView());

      expect(find.text('Study (3)'), findsOneWidget);
      expect(find.text('1 due • '), findsOneWidget);
      expect(find.text('2 new • '), findsOneWidget);
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
      expect(find.text('Study (2)'), findsOneWidget);
      expect(find.text('2 due'), findsOneWidget);
      expect(find.text('4 words'), findsOneWidget);
      expect(find.text('2 Due'), findsOneWidget);
      expect(find.text('1 New'), findsOneWidget);
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
      expect(bannerStudyButton(), findsNothing);

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

      expect(bannerStudyButton(), findsOneWidget);
      expect(
        tester.widget<FilledButton>(bannerStudyButton()).onPressed,
        isNull,
      );
      expect(bannerLimitButton(), findsNothing);
      expect(find.text('Daily Limit'), findsNothing);
    });
  });

  group('Lesson list on a phone', () {
    const phone = Size(400, 800);

    testWidgets('a row shows its words and Due/New badges, no Cards', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      await seedLesson(tester, provider, total: 5, due: 2);
      await pumpWith(tester, provider, const LessonListView(), size: phone);

      expect(find.text('5 words'), findsOneWidget);
      expect(find.text('2 Due'), findsOneWidget);
      expect(find.text('3 New'), findsOneWidget);
      expect(find.textContaining('Cards'), findsNothing);
      expect(find.textContaining('Words'), findsNothing);
    });

    testWidgets('the Due badge is amber and the New badge is tertiary', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      await seedLesson(tester, provider, total: 5, due: 2);
      await pumpWith(tester, provider, const LessonListView(), size: phone);

      final due = tester.widget<Badge>(find.widgetWithText(Badge, '2 Due'));
      final fresh = tester.widget<Badge>(find.widgetWithText(Badge, '3 New'));
      final theme = Theme.of(tester.element(find.byType(LessonListView)));
      expect(due.backgroundColor, Colors.amber.shade800);
      expect(fresh.backgroundColor, theme.colorScheme.tertiary);
    });

    testWidgets('a lesson with nothing waiting has no badges', (tester) async {
      final provider = await loadedProvider(tester);
      await seedLesson(tester, provider, total: 2, introducedRecently: 2);
      await pumpWith(tester, provider, const LessonListView(), size: phone);

      expect(find.text('2 words'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(ListTile),
          matching: find.byType(Badge),
        ),
        findsNothing,
      );
    });

    testWidgets('a row has a study icon but no arrow button', (tester) async {
      final provider = await loadedProvider(tester);
      await seedLesson(tester, provider, total: 3, due: 1);
      await pumpWith(tester, provider, const LessonListView(), size: phone);

      expect(find.byTooltip('Study'), findsOneWidget);
      expect(find.byTooltip('View Vocabulary'), findsNothing);
    });

    testWidgets('a lesson with nothing active has no study icon', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      final lesson = await seedLesson(tester, provider, total: 2);
      for (final vocab in lesson.vocabularies) {
        vocab.cardTargetToNative.isEnabled = false;
      }
      await pumpWith(tester, provider, const LessonListView(), size: phone);

      expect(find.byTooltip('Study'), findsNothing);
    });

    testWidgets('a row keeps its tap, which opens the lesson reader', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      await seedLesson(tester, provider, total: 2, title: 'Tap me');
      await pumpWith(tester, provider, const LessonListView(), size: phone);

      // Not tapped: the reader embeds a WebView, which has no platform
      // implementation under flutter test.
      final tile = tester.widget<ListTile>(
        find.widgetWithText(ListTile, 'Tap me'),
      );
      expect(tile.onTap, isNotNull);
    });

    testWidgets('the row menu gives phones the vocabulary view', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      await seedLesson(tester, provider, total: 2);
      await pumpWith(tester, provider, const LessonListView(), size: phone);

      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('View Vocabulary'));
      await tester.pumpAndSettle();

      expect(find.byType(LessonDetailView), findsOneWidget);
    });

    testWidgets('on a desktop the arrow opens it and the menu does not', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      await seedLesson(tester, provider, total: 2);
      await pumpWith(tester, provider, const LessonListView());

      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      expect(find.text('View Vocabulary'), findsNothing);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('View Vocabulary'));
      await tester.pumpAndSettle();
      expect(find.byType(LessonDetailView), findsOneWidget);
    });

    testWidgets('the study icon starts a lesson session', (tester) async {
      final provider = await loadedProvider(tester);
      await seedLesson(tester, provider, total: 2, due: 1);
      await pumpWith(tester, provider, const LessonListView(), size: phone);

      await tester.tap(find.byTooltip('Study'));
      await tester.pumpAndSettle();

      expect(find.byType(StudyView), findsOneWidget);
    });

    testWidgets('the banner puts its buttons below the text', (tester) async {
      final provider = await loadedProvider(tester);
      await seedLesson(tester, provider, total: 3, due: 1);
      await pumpWith(tester, provider, const LessonListView(), size: phone);

      final title = tester.getBottomLeft(find.text('Daily Review Queue'));
      final button = tester.getTopLeft(bannerStudyButton());
      expect(button.dy, greaterThan(title.dy));
      expect(button.dx, lessThan(title.dx + 100));
    });

    testWidgets('the banner keeps text and buttons side by side on a desktop', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      await seedLesson(tester, provider, total: 3, due: 1);
      await pumpWith(tester, provider, const LessonListView());

      final title = tester.getTopLeft(find.text('Daily Review Queue'));
      final button = tester.getTopLeft(bannerStudyButton());
      expect(button.dx, greaterThan(title.dx + 300));
    });

    testWidgets('nothing overflows on a small phone with a long title', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      await seedLesson(
        tester,
        provider,
        total: 8,
        due: 3,
        title: 'A rather long lesson title that has to wrap somewhere',
      );
      await pumpWith(
        tester,
        provider,
        const LessonListView(),
        size: const Size(320, 640),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('Study (8)'), findsOneWidget);
    });
  });

  group('Lesson detail', () {
    testWidgets('Study button counts due and new cards together', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      final lesson = await seedLesson(tester, provider, total: 3, due: 1);
      await pumpWith(tester, provider, LessonDetailView(lessonId: lesson.id));

      expect(find.text('Study (3)'), findsOneWidget);
    });

    testWidgets('Study button counts only the new cards still allowed', (
      tester,
    ) async {
      final provider = await loadedProvider(tester, {
        'lingua_srs_max_new_cards_24h': 1,
      });
      final lesson = await seedLesson(tester, provider, total: 3);
      await pumpWith(tester, provider, LessonDetailView(lessonId: lesson.id));

      expect(find.text('Study (1)'), findsOneWidget);
    });

    testWidgets('Study button is just Study when nothing is waiting', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      final lesson = await seedLesson(
        tester,
        provider,
        total: 2,
        introducedRecently: 2,
      );
      await pumpWith(tester, provider, LessonDetailView(lessonId: lesson.id));

      expect(find.text('Study'), findsOneWidget);
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

  group('Study ratings', () {
    Future<void> reveal(WidgetTester tester) async {
      await tester.tap(find.textContaining('Show Answer'));
      await tester.pumpAndSettle();
    }

    // Keyboard tests reveal with Enter instead, so no button tap takes focus
    // away from the study view's key listener.
    Future<AppProvider> openStudy(
      WidgetTester tester, {
      int due = 0,
      int total = 1,
      bool revealAnswer = true,
      bool revealWithButton = true,
    }) async {
      final provider = await loadedProvider(tester);
      final lesson = await seedLesson(tester, provider, total: total, due: due);
      await pumpWith(tester, provider, StudyView(lessonId: lesson.id));
      if (!revealAnswer) return provider;
      if (revealWithButton) {
        await reveal(tester);
      } else {
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
      }
      return provider;
    }

    testWidgets('a fresh card offers only Again and Good', (tester) async {
      await openStudy(tester);

      expect(find.textContaining('Again'), findsOneWidget);
      expect(find.textContaining('Good'), findsOneWidget);
      expect(find.text('Hard'), findsNothing);
      expect(find.text('Easy'), findsNothing);
    });

    testWidgets('a fresh card is marked NEW, before and after the reveal', (
      tester,
    ) async {
      await openStudy(tester, revealAnswer: false);
      expect(find.text('NEW'), findsOneWidget);

      await reveal(tester);
      expect(find.text('NEW'), findsOneWidget);
    });

    testWidgets('the NEW mark uses the tertiary colour of the list badge', (
      tester,
    ) async {
      await openStudy(tester, revealAnswer: false);

      final chip = tester.widget<Chip>(find.widgetWithText(Chip, 'NEW'));
      final theme = Theme.of(tester.element(find.byType(StudyView)));
      expect(chip.backgroundColor, theme.colorScheme.tertiary);
    });

    testWidgets('a card seen before is not marked NEW', (tester) async {
      await openStudy(tester, due: 1, revealAnswer: false);
      expect(find.text('NEW'), findsNothing);

      await reveal(tester);
      expect(find.text('NEW'), findsNothing);
    });

    testWidgets('a fresh card previews when Again and Good come back', (
      tester,
    ) async {
      await openStudy(tester);

      expect(find.text('1h'), findsOneWidget);
      expect(find.text('1d'), findsOneWidget);
    });

    testWidgets('a card that was seen before offers all four ratings', (
      tester,
    ) async {
      await openStudy(tester, due: 1);

      expect(find.textContaining('Again'), findsOneWidget);
      expect(find.text('Hard'), findsOneWidget);
      expect(find.textContaining('Good'), findsOneWidget);
      expect(find.text('Easy'), findsOneWidget);
    });

    testWidgets('Good on a fresh card introduces it', (tester) async {
      final provider = await openStudy(tester);

      await tester.tap(find.textContaining('Good'));
      await tester.pumpAndSettle();

      expect(provider.newCardsIntroducedLast24h, 1);
      expect(provider.remainingNewCards24h, 9);
    });

    testWidgets('the 2 and 4 keys do nothing on a fresh card', (tester) async {
      final provider = await openStudy(tester, revealWithButton: false);
      expect(find.textContaining('Good'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit4);
      await tester.pumpAndSettle();

      expect(provider.newCardsIntroducedLast24h, 0);
      expect(find.textContaining('Good'), findsOneWidget);
    });

    testWidgets('the 3 key still rates a fresh card Good', (tester) async {
      final provider = await openStudy(tester, revealWithButton: false);

      await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
      await tester.pumpAndSettle();

      expect(provider.newCardsIntroducedLast24h, 1);
    });

    testWidgets('the 2 and 4 keys still work on a card seen before', (
      tester,
    ) async {
      final provider = await openStudy(tester, due: 1, revealWithButton: false);
      final card =
          provider.lessons.single.vocabularies.single.cardTargetToNative;
      final before = card.interval;

      await tester.sendKeyEvent(LogicalKeyboardKey.digit4);
      await tester.pumpAndSettle();

      expect(card.lastRating, SrsRating.easy);
      expect(card.interval, greaterThan(before));
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
