import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/lesson.dart';
import 'package:lingua_srs/models/srs_card.dart';
import 'package:lingua_srs/models/vocab_item.dart';
import 'package:lingua_srs/providers/app_provider.dart';
import 'package:lingua_srs/services/audio_service.dart';
import 'package:lingua_srs/services/srs_service.dart';
import 'package:lingua_srs/views/study_view.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'secret_storage_mock.dart';

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
      await tester.tap(find.byTooltip('Undo Last Rating'));
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
      expect(find.text('Wrapping up: 1 Again card left.'), findsOneWidget);

      // Let the snackbar close; it covers the rating buttons.
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();

      await reveal(tester);
      await rate(tester, 'Good');
      expect(find.text('Session Complete!'), findsOneWidget);
      expect(seeded.fresh.status, SrsStatus.isNew);
    });

    testWidgets('wrap up with no Again card ends the session at once', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      final seeded = await seed(tester, provider);
      final repetitions = seeded.due.repetitions;
      await openStudy(tester, provider, seeded.lesson);

      await chooseFromMenu(tester, 'Wrap up session');

      expect(find.text('Session Complete!'), findsOneWidget);
      expect(seeded.due.repetitions, repetitions);
      expect(seeded.fresh.status, SrsStatus.isNew);
    });
  });
}
