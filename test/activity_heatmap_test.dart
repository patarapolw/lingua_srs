import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/srs_card.dart';
import 'package:lingua_srs/providers/app_provider.dart';
import 'package:lingua_srs/services/storage_service.dart';
import 'package:lingua_srs/views/activity_heatmap_view.dart';
import 'package:lingua_srs/widgets/adaptive_scaffold.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
    expect(find.text('Jan'), findsOneWidget);
    expect(find.byType(RotatedBox), findsWidgets);

    final restoredCounts = await StorageService.loadDailyReviewCounts();
    expect(
      restoredCounts[DateTime(today.year, today.month, today.day)],
      SrsRating.values.length,
    );
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
