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

  // The ListView builds lazily, so a view tall enough for every section lets
  // the tests find the stage line and the leeches below the summary.
  void useTallView(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

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
    useTallView(tester);
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

  String dayLabel(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  Finder dayCells() => find.byWidgetPredicate(
    (widget) =>
        widget is Tooltip &&
        RegExp(r'^\d{4}-\d{2}-\d{2}: ').hasMatch(widget.message ?? ''),
  );

  testWidgets('a day with one review says "1 review"', (tester) async {
    await provider.recordCardReview(
      SrsCard(direction: CardDirection.targetToNative),
      SrsRating.good,
    );
    final today = DateTime.now();

    await tester.pumpWidget(
      ChangeNotifierProvider<AppProvider>.value(
        value: provider,
        child: const MaterialApp(home: ActivityHeatmapView()),
      ),
    );

    // A new card answered Good: right, and a new card started.
    expect(
      find.byTooltip('${dayLabel(today)}: 1 review, 1 right, 1 new'),
      findsOneWidget,
    );
    expect(find.text('1 review in the past year'), findsOneWidget);
  });

  testWidgets('the weekday labels are on their own rows', (tester) async {
    useTallView(tester);
    await provider.recordCardReview(
      SrsCard(direction: CardDirection.targetToNative),
      SrsRating.good,
    );
    final today = DateTime.now();

    await tester.pumpWidget(
      ChangeNotifierProvider<AppProvider>.value(
        value: provider,
        child: const MaterialApp(home: ActivityHeatmapView()),
      ),
    );

    // Weeks start on Monday, one 16-pixel row per day, so the Monday row is
    // (weekday - 1) rows above today's cell. The labels sat one row too low,
    // which put Saturday on the "Fri" row.
    final cell = tester.getTopLeft(
      find.byTooltip('${dayLabel(today)}: 1 review, 1 right, 1 new'),
    );
    final mondayTop = cell.dy - (today.weekday - DateTime.monday) * 16;
    Offset labelTopLeft(String label) {
      final labels = find.text(label);
      for (var i = 0; i < labels.evaluate().length; i++) {
        final topLeft = tester.getTopLeft(labels.at(i));
        // The calendar's labels are left of its cells; the 7-day forecast
        // has weekday names too.
        if (topLeft.dx < cell.dx) return topLeft;
      }
      fail('No "$label" label next to the calendar');
    }

    expect(labelTopLeft('Mon').dy, mondayTop);
    expect(labelTopLeft('Wed').dy, mondayTop + 2 * 16);
    expect(labelTopLeft('Fri').dy, mondayTop + 4 * 16);
  });

  testWidgets('days outside the calendar range have no tooltip', (
    tester,
  ) async {
    await provider.recordCardReview(
      SrsCard(direction: CardDirection.targetToNative),
      SrsRating.good,
    );
    final today = DateTime.now();
    final tomorrow = DateTime(today.year, today.month, today.day + 1);

    await tester.pumpWidget(
      ChangeNotifierProvider<AppProvider>.value(
        value: provider,
        child: const MaterialApp(home: ActivityHeatmapView()),
      ),
    );

    // The only reviews are today's, so today is the only day in range, even
    // though the week's other days take up space in its column.
    expect(dayCells(), findsOneWidget);
    expect(find.byTooltip('${dayLabel(tomorrow)}: 0 reviews'), findsNothing);
  });

  testWidgets('opens scrolled to the newest week', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final now = DateTime.now();
    await provider.recordCardReview(
      SrsCard(direction: CardDirection.targetToNative),
      SrsRating.good,
      at: now.subtract(const Duration(days: 200)),
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<AppProvider>.value(
        value: provider,
        child: const MaterialApp(home: ActivityHeatmapView()),
      ),
    );
    await tester.pumpAndSettle();

    final calendar = tester.state<ScrollableState>(
      find.byWidgetPredicate(
        (widget) =>
            widget is Scrollable && widget.axisDirection == AxisDirection.right,
      ),
    );
    expect(calendar.position.maxScrollExtent, greaterThan(0));
    expect(calendar.position.pixels, calendar.position.maxScrollExtent);
  });

  group('calendarWeekStart', () {
    test('is the Monday of the week, at midnight', () {
      expect(calendarWeekStart(DateTime(2026, 11, 2)), DateTime(2026, 11, 2));
      expect(
        calendarWeekStart(DateTime(2026, 11, 4, 15, 30)),
        DateTime(2026, 11, 2),
      );
      expect(calendarWeekStart(DateTime(2026, 11, 8)), DateTime(2026, 11, 2));
    });

    test('crosses month and year boundaries', () {
      expect(calendarWeekStart(DateTime(2026, 12, 1)), DateTime(2026, 11, 30));
      expect(calendarWeekStart(DateTime(2027, 1, 3)), DateTime(2026, 12, 28));
    });

    test('is the Monday after a clock change mid-week', () {
      // Egypt moves its clocks forward on Friday 2026-04-24; the week still
      // starts on Monday the 20th wherever the test runs.
      final monday = calendarWeekStart(DateTime(2026, 4, 25));
      expect(monday, DateTime(2026, 4, 20));
      expect(monday.weekday, DateTime.monday);
    });
  });

  testWidgets('sums up the streak, today and right and wrong', (tester) async {
    for (final rating in [SrsRating.again, SrsRating.good, SrsRating.easy]) {
      await provider.recordCardReview(
        SrsCard(direction: CardDirection.targetToNative),
        rating,
      );
    }
    final yesterday = DateTime.now().subtract(const Duration(days: 1));
    await provider.recordCardReview(
      SrsCard(direction: CardDirection.targetToNative),
      SrsRating.hard,
      at: yesterday,
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<AppProvider>.value(
        value: provider,
        child: const MaterialApp(home: ActivityHeatmapView()),
      ),
    );

    expect(find.text('2-day streak · Today 3 reviews, 3 new'), findsOneWidget);
    // Good and Easy are right; Again and Hard are wrong: 2 of 4.
    expect(find.text('50%'), findsOneWidget);
    expect(find.text('2 right'), findsOneWidget);
    expect(find.text('2 wrong'), findsOneWidget);
    // Each rating's count, so it shows which of the two made up more.
    expect(find.text('Good 1 · Easy 1'), findsOneWidget);
    expect(find.text('Again 1 · Hard 1'), findsOneWidget);
    // A ring of right in green over wrong in red, as in the study session.
    final ring = tester.widget<CircularProgressIndicator>(
      find.byType(CircularProgressIndicator),
    );
    expect(ring.value, 0.5);
    expect(ring.color, Colors.green.shade600);
    expect(ring.backgroundColor, Colors.red.shade600);
  });

  testWidgets('shows the next 7 days and stages on one line', (tester) async {
    useTallView(tester);
    final now = DateTime.now();
    SrsCard due(DateTime date) => SrsCard(
      direction: CardDirection.targetToNative,
      status: SrsStatus.review,
      interval: 3,
      lastReviewed: date.subtract(const Duration(days: 3)),
      dueDate: date,
    );
    provider.lessons.add(
      Lesson(
        title: 'L',
        vocabularies: [
          VocabItem(
            targetWord: 'a',
            translation: 'a',
            pos: 'nouns',
            cardTargetToNative: due(now.subtract(const Duration(days: 2))),
          ),
          VocabItem(
            targetWord: 'b',
            translation: 'b',
            pos: 'nouns',
            cardTargetToNative: due(now.add(const Duration(days: 1))),
          ),
          VocabItem(targetWord: 'c', translation: 'c', pos: 'nouns'),
        ],
      ),
    );
    await provider.recordCardReview(
      SrsCard(direction: CardDirection.targetToNative),
      SrsRating.good,
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<AppProvider>.value(
        value: provider,
        child: const MaterialApp(home: ActivityHeatmapView()),
      ),
    );

    expect(find.text('Next 7 days'), findsOneWidget);
    expect(
      find.text(
        'All cards coming due, before your limit of 100 reviews '
        'per 24 hours',
      ),
      findsOneWidget,
    );
    expect(find.byTooltip('Today: 1 due'), findsOneWidget);
    // Each forecast bar prints its count.
    expect(
      find.descendant(
        of: find.byTooltip('Today: 1 due'),
        matching: find.text('1'),
      ),
      findsOneWidget,
    );
    // The deck by stage comes before the forecast.
    expect(
      tester.getTopLeft(find.text('Cards by stage')).dy,
      lessThan(tester.getTopLeft(find.text('Next 7 days')).dy),
    );
    expect(find.text('1 new'), findsOneWidget);
    expect(find.text('2 review'), findsOneWidget);
    expect(find.byTooltip('Review: 2 cards'), findsOneWidget);

    // Today's bar in the Due badge's amber.
    final todayBar = tester.widget<Container>(
      find
          .descendant(
            of: find.byTooltip('Today: 1 due'),
            matching: find.byType(Container),
          )
          .last,
    );
    expect(
      (todayBar.decoration as BoxDecoration?)?.color,
      Colors.amber.shade800,
    );
  });

  testWidgets('a leech can be suspended, and the suspension undone', (
    tester,
  ) async {
    useTallView(tester);
    final card = SrsCard(
      direction: CardDirection.targetToNative,
      lapses: 8,
      status: SrsStatus.review,
    );
    provider.lessons.add(
      Lesson(
        title: 'L',
        vocabularies: [
          VocabItem(
            targetWord: 'word',
            translation: 'meaning',
            pos: 'nouns',
            cardTargetToNative: card,
          ),
        ],
      ),
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<AppProvider>.value(
        value: provider,
        child: const MaterialApp(home: ActivityHeatmapView()),
      ),
    );
    expect(find.text('Leeches (1)'), findsOneWidget);

    await tester.tap(find.byTooltip('Suspend'));
    await tester.pumpAndSettle();
    expect(card.isSuspended, isTrue);
    expect(find.text('Leeches (1)'), findsNothing);
    expect(find.text('Suspended "word"'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(card.isSuspended, isFalse);
    expect(find.text('Leeches (1)'), findsOneWidget);
  });

  testWidgets('the suspension snackbar goes away on its own', (tester) async {
    useTallView(tester);
    provider.lessons.add(
      Lesson(
        title: 'L',
        vocabularies: [
          VocabItem(
            targetWord: 'word',
            translation: 'meaning',
            pos: 'nouns',
            cardTargetToNative: SrsCard(
              direction: CardDirection.targetToNative,
              lapses: 8,
              status: SrsStatus.review,
            ),
          ),
        ],
      ),
    );
    await tester.pumpWidget(
      ChangeNotifierProvider<AppProvider>.value(
        value: provider,
        child: const MaterialApp(home: ActivityHeatmapView()),
      ),
    );

    await tester.tap(find.byTooltip('Suspend'));
    await tester.pumpAndSettle();
    expect(find.text('Suspended "word"'), findsOneWidget);

    // A snackbar with an action persists unless told otherwise; an old Undo
    // stayed on screen for minutes, across screens.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('Suspended "word"'), findsNothing);
  });

  group('activityLevel', () {
    test('is 0 without reviews', () {
      expect(activityLevel(0, 100), 0);
      expect(activityLevel(0, 0), 0);
    });

    test('splits the busiest day into quarters', () {
      expect(activityLevel(1, 100), 1);
      expect(activityLevel(25, 100), 1);
      expect(activityLevel(26, 100), 2);
      expect(activityLevel(50, 100), 2);
      expect(activityLevel(75, 100), 3);
      expect(activityLevel(76, 100), 4);
      expect(activityLevel(100, 100), 4);
    });

    test('gives a quiet calendar the darkest shade on its busiest day', () {
      expect(activityLevel(1, 1), 4);
      expect(activityLevel(1, 2), 2);
      expect(activityLevel(2, 2), 4);
    });

    test('ranges match the levels, and skip levels no count gets', () {
      expect(activityLevelRange(1, 100), (1, 25));
      expect(activityLevelRange(4, 100), (76, 100));
      expect(activityLevelRange(1, 2), isNull);
      expect(activityLevelRange(2, 2), (1, 1));
      expect(activityLevelRange(4, 2), (2, 2));
      for (var busiest = 1; busiest <= 12; busiest++) {
        for (var count = 1; count <= busiest; count++) {
          final range = activityLevelRange(
            activityLevel(count, busiest),
            busiest,
          )!;
          expect(count, inInclusiveRange(range.$1, range.$2));
        }
      }
    });
  });

  testWidgets('shades days by the busiest day shown', (tester) async {
    final today = DateTime.now();
    final day = DateTime(today.year, today.month, today.day);
    final earlier = DateTime(today.year, today.month, today.day - 1);
    late AppProvider fresh;
    await tester.runAsync(() async {
      await StorageService.saveDailyReviewCounts({day: 100, earlier: 40});
      fresh = AppProvider();
      for (var attempt = 0; attempt < 100 && fresh.isLoading; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    addTearDown(fresh.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider<AppProvider>.value(
        value: fresh,
        child: const MaterialApp(home: ActivityHeatmapView()),
      ),
    );

    Color? cellColor(String message) {
      final box = tester.widget<Container>(
        find
            .descendant(
              of: find.byTooltip(message),
              matching: find.byType(Container),
            )
            .last,
      );
      return (box.decoration as BoxDecoration?)?.color;
    }

    // At fixed thresholds, both days were the darkest shade.
    expect(
      cellColor('${dayLabel(day)}: 100 reviews'),
      isNot(cellColor('${dayLabel(earlier)}: 40 reviews')),
    );
    expect(find.byTooltip('1–25 reviews'), findsOneWidget);
    expect(find.byTooltip('76–100 reviews'), findsOneWidget);
    expect(find.byTooltip('No reviews'), findsOneWidget);
  });

  testWidgets('puts commas in large counts', (tester) async {
    final today = DateTime.now();
    final day = DateTime(today.year, today.month, today.day);
    late AppProvider fresh;
    await tester.runAsync(() async {
      await StorageService.saveDailyReviewCounts({day: 1234});
      fresh = AppProvider();
      for (var attempt = 0; attempt < 100 && fresh.isLoading; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    addTearDown(fresh.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider<AppProvider>.value(
        value: fresh,
        child: const MaterialApp(home: ActivityHeatmapView()),
      ),
    );

    expect(find.text('1,234 reviews in the past year'), findsOneWidget);
    expect(find.byTooltip('${dayLabel(day)}: 1,234 reviews'), findsOneWidget);
    expect(find.byTooltip('926–1,234 reviews'), findsOneWidget);
  });

  testWidgets('shows the cards waiting before the first review', (
    tester,
  ) async {
    provider.lessons.add(
      Lesson(
        title: 'New words',
        vocabularies: [
          VocabItem(targetWord: 'a', translation: 'b', pos: 'nouns'),
          VocabItem(targetWord: 'c', translation: 'd', pos: 'nouns'),
        ],
      ),
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<AppProvider>.value(
        value: provider,
        child: const MaterialApp(home: ActivityHeatmapView()),
      ),
    );

    expect(find.text('No study activity yet'), findsOneWidget);
    expect(find.text('Cards by stage'), findsOneWidget);
    // Nouns study KO ➔ EN only by default: one card each.
    expect(find.byTooltip('New: 2 cards'), findsOneWidget);
    expect(find.text('Less'), findsNothing);
    expect(find.textContaining('in the past year'), findsNothing);
    expect(dayCells(), findsNothing);
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
    useTallView(tester);
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

  group('New cards', () {
    test('the limit line', () {
      expect(newCardsLimitText(4, 10), '4 of 10 started in the last 24 hours');
      expect(
        newCardsLimitText(12, 0),
        '12 started in the last 24 hours (no limit)',
      );
    });

    test('the chart caption', () {
      expect(
        newCardsChartCaption(10),
        '*per calendar day. The limit refills 16 hours after a batch, '
        'and averages out to the limit per day.',
      );
      expect(newCardsChartCaption(0), '*per calendar day.');
    });

    test('the cards left and the time to start them', () {
      expect(
        newCardsLeftText(312, 10),
        '312 new cards left, about 32 days at 10 a day',
      );
      expect(
        newCardsLeftText(1, 10),
        '1 new card left, about 1 day at 10 a day',
      );
      expect(newCardsLeftText(1500, 0), '1,500 new cards left');
      expect(newCardsLeftText(0, 10), 'Every card has been started');
    });

    testWidgets('shows the limit, the cards left and a bar per day', (
      tester,
    ) async {
      useTallView(tester);
      final lesson = Lesson(title: 'New cards')
        ..vocabularies.addAll([
          for (var i = 0; i < 3; i++)
            VocabItem(targetWord: '새$i', translation: 'new $i', pos: 'nouns'),
        ]);
      provider.lessons.add(lesson);
      await provider.recordCardReview(
        lesson.vocabularies.first.cardTargetToNative,
        SrsRating.good,
      );

      await tester.pumpWidget(
        ChangeNotifierProvider<AppProvider>.value(
          value: provider,
          child: const MaterialApp(home: ActivityHeatmapView()),
        ),
      );

      expect(find.text('New cards'), findsOneWidget);
      expect(find.text('1 of 10 started in the last 24 hours'), findsOneWidget);
      expect(
        find.text('2 new cards left, about 1 day at 10 a day'),
        findsOneWidget,
      );
      expect(find.text('Limit 10'), findsOneWidget);
      expect(
        find.text(
          '*per calendar day. The limit refills 16 hours after a batch, '
          'and averages out to the limit per day.',
        ),
        findsOneWidget,
      );
      expect(find.text('Today'), findsWidgets);
      final today = DateTime.now();
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
      expect(
        find.byTooltip('${months[today.month - 1]} ${today.day}: 1 new'),
        findsOneWidget,
      );
    });
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
