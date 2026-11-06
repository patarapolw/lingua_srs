import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/lesson.dart';
import 'package:lingua_srs/models/srs_card.dart';
import 'package:lingua_srs/models/vocab_item.dart';
import 'package:lingua_srs/providers/app_provider.dart';
import 'package:lingua_srs/services/storage_service.dart';
import 'package:lingua_srs/views/activity_heatmap_view.dart';
import 'package:lingua_srs/widgets/adaptive_scaffold.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'secret_storage_mock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(setUpSecretStorage);

  late AppProvider provider;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'lingua_srs_windows_legacy_migration_complete': true,
    });
    provider = AppProvider();
    for (var attempt = 0; attempt < 100 && provider.isLoading; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(provider.isLoading, isFalse);
  });

  tearDown(() {
    provider.dispose();
  });

  testWidgets('shows a non-scrollable empty state when there are no reviews', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ChangeNotifierProvider<AppProvider>.value(
        value: provider,
        child: const MaterialApp(home: ActivityHeatmapView()),
      ),
    );

    expect(find.text('No study activity yet'), findsOneWidget);
    expect(
      find.text('Review vocabulary to see your activity here.'),
      findsOneWidget,
    );
    expect(find.text('Less'), findsNothing);
    expect(find.text('Jan'), findsNothing);
    expect(find.byType(Scrollable), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('records and persists daily reviews for the activity calendar', (
    tester,
  ) async {
    for (final rating in SrsRating.values) {
      await provider.recordCardReview(
        SrsCard(direction: CardDirection.targetToNative),
        rating,
      );
    }

    final today = DateTime.now();
    expect(
      provider.dailyReviewCounts[DateTime(today.year, today.month, today.day)],
      SrsRating.values.length,
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<AppProvider>.value(
        value: provider,
        child: const MaterialApp(home: ActivityHeatmapView()),
      ),
    );
    expect(find.text('Study activity'), findsOneWidget);
    expect(
      find.text('${SrsRating.values.length} reviews in the past year'),
      findsOneWidget,
    );
    expect(find.text('Less'), findsOneWidget);
    expect(find.text('More'), findsOneWidget);
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    // Only today has reviews, so the calendar is this week's column, which is
    // labelled with the month of its Monday: on Dec 1–6, 2026 that is Nov.
    final weekStart = DateTime(
      today.year,
      today.month,
      today.day - (today.weekday - DateTime.monday),
    );
    expect(find.text(months[weekStart.month - 1]), findsOneWidget);
    expect(find.byType(RotatedBox), findsWidgets);
    expect(find.text('Cards by stage'), findsOneWidget);
    expect(find.byTooltip('New: 0 cards'), findsOneWidget);

    final restoredCounts = await StorageService.loadDailyReviewCounts();
    expect(
      restoredCounts[DateTime(today.year, today.month, today.day)],
      SrsRating.values.length,
    );
  });

  testWidgets('backfills activity from last review dates on first load', (
    tester,
  ) async {
    final reviewed = DateTime.now().subtract(const Duration(days: 3));
    late AppProvider fresh;
    // Real timers and storage I/O don't progress inside testWidgets' fake zone.
    await tester.runAsync(() async {
      await StorageService.saveLessons([
        Lesson(
          title: 'Old',
          vocabularies: [
            VocabItem(
              targetWord: 'a',
              translation: 'b',
              pos: 'nouns',
              cardTargetToNative: SrsCard(
                direction: CardDirection.targetToNative,
                status: SrsStatus.review,
                lastReviewed: reviewed,
              ),
            ),
          ],
        ),
      ]);
      fresh = AppProvider();
      for (var attempt = 0; attempt < 100 && fresh.isLoading; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    addTearDown(fresh.dispose);
    expect(
      fresh.dailyReviewCounts[DateTime(
        reviewed.year,
        reviewed.month,
        reviewed.day,
      )],
      1,
    );
  });

  testWidgets('shows unique enabled leeches at the lapse threshold', (
    tester,
  ) async {
    final leech = SrsCard(
      id: 'leech-card',
      direction: CardDirection.targetToNative,
      lapses: 8,
      status: SrsStatus.review,
    );
    provider.lessons.addAll([
      Lesson(
        title: 'First',
        vocabularies: [
          VocabItem(
            targetWord: 'word',
            translation: 'meaning',
            pos: 'nouns',
            cardTargetToNative: leech,
          ),
        ],
      ),
      Lesson(
        title: 'Second',
        vocabularies: [
          VocabItem(
            targetWord: 'duplicate',
            translation: 'meaning',
            pos: 'nouns',
            cardTargetToNative: leech,
          ),
          VocabItem(
            targetWord: 'not-yet',
            translation: 'not-yet',
            pos: 'nouns',
            cardTargetToNative: SrsCard(
              direction: CardDirection.targetToNative,
              lapses: 7,
              status: SrsStatus.learning,
            ),
          ),
          VocabItem(
            targetWord: 'disabled',
            translation: 'disabled',
            pos: 'nouns',
            cardTargetToNative: SrsCard(
              direction: CardDirection.targetToNative,
              isEnabled: false,
              lapses: 9,
            ),
          ),
        ],
      ),
    ]);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppProvider>.value(
        value: provider,
        child: const MaterialApp(home: ActivityHeatmapView()),
      ),
    );

    expect(find.text('0 reviews in the past year'), findsOneWidget);
    expect(find.text('No study activity yet'), findsNothing);
    expect(find.text('Leeches (1)'), findsOneWidget);
    expect(find.text('Cards by stage'), findsOneWidget);
    expect(find.byTooltip('Review: 1 card'), findsOneWidget);
    expect(find.byTooltip('Learning: 1 card'), findsOneWidget);
    expect(find.text('word'), findsOneWidget);
    expect(find.text('meaning'), findsOneWidget);
    expect(find.text('8 lapses'), findsOneWidget);
    expect(find.text('duplicate'), findsNothing);
    expect(find.text('not-yet'), findsNothing);
    expect(find.text('disabled'), findsNothing);
  });

  testWidgets('opens study activity from the Lessons options on mobile', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ChangeNotifierProvider<AppProvider>.value(
        value: provider,
        child: const MaterialApp(home: AdaptiveScaffold()),
      ),
    );

    expect(find.byType(NavigationDestination), findsNWidgets(4));
    expect(find.text('Activity'), findsNothing);

    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
    expect(find.text('Study activity'), findsOneWidget);

    await tester.tap(find.text('Study activity'));
    await tester.pumpAndSettle();
    expect(find.text('Study activity'), findsOneWidget);
    expect(find.text('No study activity yet'), findsOneWidget);
    expect(find.byType(Scrollable), findsNothing);
  });
}
