import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/srs_card.dart';
import 'package:lingua_srs/providers/app_provider.dart';
import 'package:lingua_srs/services/storage_service.dart';
import 'package:lingua_srs/views/activity_heatmap_view.dart';
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

  testWidgets('records and persists daily reviews for the activity calendar', (
    tester,
  ) async {
    final card = SrsCard(direction: CardDirection.targetToNative);
    await provider.recordCardReview(card, SrsRating.good);

    final today = DateTime.now();
    expect(
      provider.dailyReviewCounts[DateTime(today.year, today.month, today.day)],
      1,
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<AppProvider>.value(
        value: provider,
        child: const MaterialApp(home: ActivityHeatmapView()),
      ),
    );
    expect(find.text('Study activity'), findsOneWidget);
    expect(find.text('1 review in the past year'), findsOneWidget);
    expect(find.text('Less'), findsOneWidget);
    expect(find.text('More'), findsOneWidget);

    final restoredCounts = await StorageService.loadDailyReviewCounts();
    expect(
      restoredCounts[DateTime(today.year, today.month, today.day)],
      1,
    );
  });
}
