import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/lesson.dart';
import 'package:lingua_srs/models/srs_card.dart';
import 'package:lingua_srs/models/vocab_item.dart';
import 'package:lingua_srs/providers/app_provider.dart';
import 'package:lingua_srs/services/audio_service.dart';
import 'package:lingua_srs/services/tts_voice.dart';
import 'package:lingua_srs/services/srs_service.dart';
import 'package:lingua_srs/views/study_view.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'secret_storage_mock.dart';

/// A study screen must not touch real audio plugins.
class _FakeAudioService extends ChangeNotifier implements AudioService {
  @override
  TtsVoiceUsed? get lastVoice => null;
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

StudyCardItem itemFor(String word) => StudyCardItem(
  vocab: VocabItem(targetWord: word, translation: word, pos: 'nouns'),
  card: SrsCard(direction: CardDirection.targetToNative),
  lesson: Lesson(title: 'L'),
);

StudyCardItem dupOf(StudyCardItem s) =>
    StudyCardItem(vocab: s.vocab, card: s.card, lesson: s.lesson);

List<String> words(List<StudyCardItem> queue) => [
  for (final i in queue) i.vocab.targetWord,
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(setUpSecretStorage);

  group('sendCardToBack', () {
    test('moves the card to the end and undo puts it back', () {
      final queue = [itemFor('a'), itemFor('b'), itemFor('c'), itemFor('d')];

      final record = sendCardToBack(queue, 1)!;
      expect(words(queue), ['a', 'c', 'd', 'b']);
      expect(record.fromIndex, 1);

      undoSendCardToBack(queue, record);
      expect(words(queue), ['a', 'b', 'c', 'd']);
    });

    test('does not change the card or its schedule', () {
      final item = itemFor('a');
      final card = item.card;
      final due = card.dueDate;
      final queue = [item, itemFor('b')];

      sendCardToBack(queue, 0);

      expect(card.status, SrsStatus.isNew);
      expect(card.repetitions, 0);
      expect(card.lastReviewed, isNull);
      expect(card.dueDate, due);
    });

    test('is a no-op for the last card', () {
      final queue = [itemFor('a'), itemFor('b')];
      expect(sendCardToBack(queue, 1), isNull);
      expect(words(queue), ['a', 'b']);
    });

    test('undo finds the card even after an Again copy was added', () {
      final queue = [itemFor('a'), itemFor('b'), itemFor('c')];
      final record = sendCardToBack(queue, 0)!;
      queue.add(dupOf(queue.first)); // b rated Again, re-queued at the end

      undoSendCardToBack(queue, record);
      expect(words(queue), ['a', 'b', 'c', 'b']);
    });
  });

  group('removeCardFromSession', () {
    test('drops the card and its re-queued copies, keeps the rest', () {
      final a = itemFor('a');
      final b = itemFor('b');
      final c = itemFor('c');
      // a was rated Again at 0 and its copy is on screen at 2.
      final queue = [a, b, dupOf(a), c, dupOf(a)];
      final againIds = {a.card.id, b.card.id};

      final removed = removeCardFromSession(
        card: a.card,
        queue: queue,
        fromIndex: 2,
        againCardIds: againIds,
      );

      expect(words(queue), ['a', 'b', 'c']);
      expect(queue.first, same(a), reason: 'answered entries stay');
      expect(againIds, {b.card.id});
      expect([for (final r in removed) r.index], [2, 4]);
    });

    test('restoreRemovedItems puts the queue back as it was', () {
      final a = itemFor('a');
      final queue = [itemFor('x'), a, itemFor('b'), dupOf(a), itemFor('c')];
      final before = List.of(queue);

      final removed = removeCardFromSession(
        card: a.card,
        queue: queue,
        fromIndex: 1,
        againCardIds: {},
      );
      restoreRemovedItems(queue, removed);

      expect(queue, before);
    });
  });

  group('wrapUpQueue', () {
    test('keeps only re-queued Again cards from the first unanswered on', () {
      final a = itemFor('a');
      final b = itemFor('b');
      final c = itemFor('c');
      final d = itemFor('d');
      final e = itemFor('e');
      // a and b answered (a Again); c is unseen and on screen; a's copy is
      // queued after d; e has not been seen either.
      final queue = [a, b, c, d, dupOf(a), e];

      final removed = wrapUpQueue(
        queue: queue,
        fromIndex: 2,
        againCardIds: {a.card.id},
      );

      expect(words(queue), ['a', 'b', 'a']);
      expect(distinctCardCount(queue), 2, reason: 'the total shrinks');
      expect(words([for (final r in removed) r.item]), ['c', 'd', 'e']);
    });

    test('leaves nothing ahead when no Again card is pending', () {
      final queue = [itemFor('a'), itemFor('b'), itemFor('c')];

      wrapUpQueue(queue: queue, fromIndex: 1, againCardIds: {});

      expect(words(queue), ['a']);
    });

    test('undo brings back the dropped cards in their places', () {
      final a = itemFor('a');
      final queue = [a, itemFor('b'), dupOf(a), itemFor('c'), dupOf(a)];
      final before = List.of(queue);

      final removed = wrapUpQueue(
        queue: queue,
        fromIndex: 1,
        againCardIds: {a.card.id},
      );
      restoreRemovedItems(queue, removed);

      expect(queue, before);
    });

    test('keeps the next unseen reviews but drops new cards', () {
      final seen = [
        for (final w in ['r1', 'r2', 'r3']) itemFor(w),
      ];
      for (final i in seen) {
        i.card.status = SrsStatus.review;
      }
      final r4 = itemFor('r4')..card.status = SrsStatus.learning;
      // n is new; r1..r4 are reviews; only the first two reviews are kept.
      final queue = [itemFor('done'), itemFor('n'), ...seen, r4];

      final removed = wrapUpQueue(
        queue: queue,
        fromIndex: 1,
        againCardIds: {},
        reviewCount: 2,
      );

      expect(words(queue), ['done', 'r1', 'r2']);
      expect(words([for (final r in removed) r.item]), ['n', 'r3', 'r4']);
    });

    test('keeps 5 reviews by default, after the Again cards', () {
      final a = itemFor('a');
      final reviews = [
        for (var i = 1; i <= 7; i++)
          itemFor('r$i')..card.status = SrsStatus.review,
      ];
      final queue = [a, ...reviews.take(2), dupOf(a), ...reviews.skip(2)];

      wrapUpQueue(queue: queue, fromIndex: 1, againCardIds: {a.card.id});

      expect(words(queue), ['a', 'r1', 'r2', 'a', 'r3', 'r4', 'r5']);
    });

    test('brings back an Again card with no copy left ahead', () {
      final a = itemFor('a');
      final queue = [itemFor('x'), a, itemFor('b')];

      final removed = wrapUpQueue(
        queue: queue,
        fromIndex: 2,
        againCardIds: {a.card.id},
        makeDuplicate: (id) => dupOf(queue.lastWhere((i) => i.card.id == id)),
      );

      expect(words(queue), ['x', 'a', 'a']);
      expect(identical(queue[2], a), isFalse, reason: 'a new copy');
      expect(words([for (final r in removed) r.item]), ['b']);
    });

    test('turning it off takes out the added copy, restores the rest', () {
      final a = itemFor('a');
      final r = itemFor('r')..card.status = SrsStatus.review;
      // a was answered Again with no copy re-queued; b is new and r is due.
      final queue = [itemFor('x'), a, itemFor('b'), r];
      final before = List.of(queue);

      final lengthBefore = queue.length;
      final removed = wrapUpQueue(
        queue: queue,
        fromIndex: 2,
        againCardIds: {a.card.id},
        makeDuplicate: (id) => dupOf(queue.lastWhere((i) => i.card.id == id)),
      );
      expect(words(queue), ['x', 'a', 'r', 'a']);
      final record = WrapUpRecord(
        fromIndex: 2,
        removed: removed,
        added: queue.sublist(lengthBefore - removed.length),
      );
      expect(record.added, hasLength(1));

      resumeWrappedUpQueue(queue, record, answeredCount: 2);

      expect(queue, before);
    });

    test('turning it off later never puts a card among the answered ones', () {
      final r = itemFor('r')..card.status = SrsStatus.review;
      // n1 and n2 are new; r is due.
      final queue = [itemFor('x'), itemFor('n1'), r, itemFor('n2')];
      final removed = wrapUpQueue(queue: queue, fromIndex: 1, againCardIds: {});
      expect(words(queue), ['x', 'r']);
      final record = WrapUpRecord(fromIndex: 1, removed: removed);

      // r is answered after the wrap up; n1 used to be before it.
      resumeWrappedUpQueue(queue, record, answeredCount: 2);

      expect(words(queue), ['x', 'r', 'n1', 'n2']);
    });

    test('turning it off keeps an added copy that was already answered', () {
      final a = itemFor('a');
      final queue = [itemFor('x'), a, itemFor('b')];
      final lengthBefore = queue.length;
      final removed = wrapUpQueue(
        queue: queue,
        fromIndex: 2,
        againCardIds: {a.card.id},
        makeDuplicate: (id) => dupOf(queue.lastWhere((i) => i.card.id == id)),
      );
      final record = WrapUpRecord(
        fromIndex: 2,
        removed: removed,
        added: queue.sublist(lengthBefore - removed.length),
      );

      // The copy of a is answered, then wrap up is turned off.
      resumeWrappedUpQueue(queue, record, answeredCount: 3);

      expect(words(queue), ['x', 'a', 'a', 'b']);
    });
  });

  group('Study session actions', () {
    const pathProviderChannel = MethodChannel(
      'plugins.flutter.io/path_provider',
    );
    late Directory storageDirectory;

    setUp(() {
      storageDirectory = Directory.systemTemp.createTempSync(
        'lingua_srs_session_actions_test_',
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

    /// One lesson with two nouns, studied KO ➔ EN only. 사과 is due, so it
    /// comes first; 바나나 is new and shows the NEW chip.
    Future<({Lesson lesson, SrsCard due, SrsCard fresh})> seed(
      WidgetTester tester,
      AppProvider provider,
    ) async {
      const yaml =
          '---\nvocabulary:\n  nouns:\n'
          '    - ko: 사과\n      en: apple\n'
          '    - ko: 바나나\n      en: banana\n'
          '---\n# Lesson\n';
      final lesson = (await tester.runAsync(() => provider.importYaml(yaml)))!;
      for (final vocab in lesson.vocabularies) {
        vocab.cardNativeToTarget.isEnabled = false;
      }
      final apple = lesson.vocabularies.firstWhere((v) => v.targetWord == '사과');
      final banana = lesson.vocabularies.firstWhere(
        (v) => v.targetWord == '바나나',
      );
      final due = apple.cardTargetToNative;
      SrsService.processReview(due, SrsRating.good);
      SrsService.processReview(due, SrsRating.good);
      due.dueDate = DateTime.now().subtract(const Duration(days: 1));
      return (lesson: lesson, due: due, fresh: banana.cardTargetToNative);
    }

    Future<void> openStudy(
      WidgetTester tester,
      AppProvider provider,
      Lesson lesson,
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
          child: MaterialApp(home: StudyView(lessonId: lesson.id)),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    Future<void> reveal(WidgetTester tester) async {
      await tester.tap(find.textContaining('Show Answer'));
      await tester.pumpAndSettle();
    }

    Future<void> rate(WidgetTester tester, String rating) async {
      await tester.tap(find.text(rating));
      await tester.pumpAndSettle();
    }

    Future<void> chooseFromMenu(WidgetTester tester, String title) async {
      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(PopupMenuItem<String>, title));
      await tester.pumpAndSettle();
    }

    Future<void> undo(WidgetTester tester) async {
      await tester.tap(find.byTooltip('Undo'));
      await tester.pumpAndSettle();
    }

    testWidgets('send to back shows the next card without rating', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      final seeded = await seed(tester, provider);
      final repetitions = seeded.due.repetitions;
      final dueDate = seeded.due.dueDate;
      await openStudy(tester, provider, seeded.lesson);
      expect(find.text('NEW'), findsNothing);

      await chooseFromMenu(tester, 'Send to back');

      expect(find.text('NEW'), findsOneWidget, reason: 'the new card is next');
      expect(find.textContaining('(1/2)'), findsOneWidget);
      expect(find.text('✓ 0'), findsOneWidget);
      expect(find.text('✗ 0'), findsOneWidget);
      expect(seeded.due.repetitions, repetitions);
      expect(seeded.due.dueDate, dueDate);

      // The sent card comes back after the new one.
      await reveal(tester);
      await rate(tester, 'Good');
      expect(find.text('NEW'), findsNothing);
      expect(find.textContaining('(2/2)'), findsOneWidget);
    });

    testWidgets('undo puts a card sent to the back where it was', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      final seeded = await seed(tester, provider);
      await openStudy(tester, provider, seeded.lesson);

      await chooseFromMenu(tester, 'Send to back');
      expect(find.text('NEW'), findsOneWidget);

      await undo(tester);
      expect(find.text('NEW'), findsNothing);
      expect(find.textContaining('(1/2)'), findsOneWidget);
    });

    testWidgets('suspend asks, then takes the card out of the session', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      final seeded = await seed(tester, provider);
      await openStudy(tester, provider, seeded.lesson);

      await chooseFromMenu(tester, 'Suspend card');
      expect(find.textContaining('Suspend this card'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Suspend'));
      await tester.pumpAndSettle();

      expect(seeded.due.isSuspended, isTrue);
      expect(seeded.fresh.isSuspended, isFalse);
      expect(find.text('NEW'), findsOneWidget);
      expect(find.textContaining('(1/1)'), findsOneWidget);
    });

    testWidgets('cancelling suspend leaves the card in the session', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      final seeded = await seed(tester, provider);
      await openStudy(tester, provider, seeded.lesson);

      await chooseFromMenu(tester, 'Suspend card');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(seeded.due.isSuspended, isFalse);
      expect(find.text('NEW'), findsNothing);
      expect(find.textContaining('(1/2)'), findsOneWidget);
    });

    testWidgets('undo unsuspends the card and puts it back', (tester) async {
      final provider = await loadedProvider(tester);
      final seeded = await seed(tester, provider);
      await openStudy(tester, provider, seeded.lesson);

      await chooseFromMenu(tester, 'Suspend card');
      await tester.tap(find.widgetWithText(FilledButton, 'Suspend'));
      await tester.pumpAndSettle();
      await undo(tester);

      expect(seeded.due.isSuspended, isFalse);
      expect(find.text('NEW'), findsNothing);
      expect(find.textContaining('(1/2)'), findsOneWidget);
    });

    testWidgets('wrap up keeps only the Again card already started', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      final seeded = await seed(tester, provider);
      await openStudy(tester, provider, seeded.lesson);

      // 사과 Again: its copy is queued after 바나나.
      await reveal(tester);
      await rate(tester, 'Again');
      expect(find.text('NEW'), findsOneWidget);
      expect(find.textContaining('(2/2)'), findsOneWidget);

      await chooseFromMenu(tester, 'Wrap up session');

      // 바나나 is dropped; the repeat of 사과 is on screen.
      expect(find.text('NEW'), findsNothing);
      expect(find.textContaining('(1/1)'), findsOneWidget);
      expect(seeded.fresh.status, SrsStatus.isNew);
      expect(find.text('Wrapping up: 1 mistake left.'), findsOneWidget);

      // Let the snackbar close; it covers the rating buttons.
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();

      await reveal(tester);
      await rate(tester, 'Good');
      expect(find.text('Session Complete!'), findsOneWidget);
      expect(seeded.fresh.status, SrsStatus.isNew);
    });

    testWidgets('wrap up with no Again card keeps the due review', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      final seeded = await seed(tester, provider);
      final repetitions = seeded.due.repetitions;
      await openStudy(tester, provider, seeded.lesson);

      await chooseFromMenu(tester, 'Wrap up session');

      // 사과 is due and stays on screen; the new 바나나 is dropped.
      expect(find.text('Session Complete!'), findsNothing);
      expect(find.text('NEW'), findsNothing);
      expect(find.textContaining('(1/1)'), findsOneWidget);
      expect(find.text('Wrapping up: 1 review left.'), findsOneWidget);

      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();

      await reveal(tester);
      await rate(tester, 'Good');
      expect(find.text('Session Complete!'), findsOneWidget);
      expect(seeded.due.repetitions, greaterThan(repetitions));
      expect(seeded.fresh.status, SrsStatus.isNew);
    });

    testWidgets('wrap up with only new cards left ends the session at once', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      final seeded = await seed(tester, provider);
      await openStudy(tester, provider, seeded.lesson);

      await reveal(tester);
      await rate(tester, 'Good');
      expect(find.text('NEW'), findsOneWidget);

      await chooseFromMenu(tester, 'Wrap up session');

      expect(find.text('Session Complete!'), findsOneWidget);
      expect(seeded.fresh.status, SrsStatus.isNew);
    });

    testWidgets('turning wrap up off from the menu brings the cards back', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      final seeded = await seed(tester, provider);
      await openStudy(tester, provider, seeded.lesson);

      await chooseFromMenu(tester, 'Wrap up session');
      expect(find.textContaining('(1/1)'), findsOneWidget);
      // Let the first snackbar close, so the next one shows.
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();

      await chooseFromMenu(tester, 'Wrap up session');

      expect(find.textContaining('(1/2)'), findsOneWidget);
      expect(find.text('Stopped wrapping up: 1 card back.'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();

      await reveal(tester);
      await rate(tester, 'Good');
      expect(find.text('NEW'), findsOneWidget, reason: 'the new card is back');
    });

    testWidgets('undo takes back a rating but leaves wrap up on', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      final seeded = await seed(tester, provider);
      final repetitions = seeded.due.repetitions;
      await openStudy(tester, provider, seeded.lesson);

      await chooseFromMenu(tester, 'Wrap up session');
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      await reveal(tester);
      await rate(tester, 'Good');
      expect(find.text('Session Complete!'), findsOneWidget);

      await tester.tap(find.text('Undo Last Card'));
      await tester.pumpAndSettle();

      expect(seeded.due.repetitions, repetitions);
      expect(find.text('NEW'), findsNothing);
      expect(find.textContaining('(1/1)'), findsOneWidget);

      // Still wrapped up: the menu offers to stop, which brings 바나나 back.
      await chooseFromMenu(tester, 'Wrap up session');
      expect(find.textContaining('(1/2)'), findsOneWidget);
    });

    testWidgets('the finish screen can turn wrap up off', (tester) async {
      final provider = await loadedProvider(tester);
      final seeded = await seed(tester, provider);
      await openStudy(tester, provider, seeded.lesson);

      await reveal(tester);
      await rate(tester, 'Good');
      await chooseFromMenu(tester, 'Wrap up session');
      expect(find.text('Session Complete!'), findsOneWidget);

      await tester.tap(find.text('Stop Wrapping Up'));
      await tester.pumpAndSettle();

      expect(find.text('NEW'), findsOneWidget);
      expect(seeded.fresh.status, SrsStatus.isNew);
    });

    testWidgets('the wrap up menu item shows its state like a toggle button', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      final seeded = await seed(tester, provider);
      await openStudy(tester, provider, seeded.lesson);

      // Whether the item is highlighted, after checking its icon matches.
      Future<bool> shownOn() async {
        await tester.tap(find.byTooltip('More'));
        await tester.pumpAndSettle();
        final tile = find.byKey(const ValueKey('wrapup-toggle'));
        final on = tester.widget<ListTile>(tile).selected;
        expect(
          find.descendant(
            of: tile,
            matching: find.byIcon(on ? Icons.flag : Icons.flag_outlined),
          ),
          findsOneWidget,
        );
        // Close the menu without choosing anything.
        await tester.tapAt(Offset.zero);
        await tester.pumpAndSettle();
        return on;
      }

      expect(await shownOn(), isFalse);
      await chooseFromMenu(tester, 'Wrap up session');
      expect(await shownOn(), isTrue);
      await chooseFromMenu(tester, 'Wrap up session');
      expect(await shownOn(), isFalse);
    });
  });
}
