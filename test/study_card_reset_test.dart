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

StudyCardItem itemFor(String word, {SrsCard? card}) => StudyCardItem(
  vocab: VocabItem(targetWord: word, translation: word, pos: 'nouns'),
  card: card ?? SrsCard(direction: CardDirection.targetToNative),
  lesson: Lesson(title: 'L'),
);

StudyCardItem dupOf(StudyCardItem s) =>
    StudyCardItem(vocab: s.vocab, card: s.card, lesson: s.lesson);

/// A card that has been learned and is due.
SrsCard learnedCard() {
  final card = SrsCard(direction: CardDirection.targetToNative);
  SrsService.processReview(card, SrsRating.good);
  SrsService.processReview(card, SrsRating.good);
  return card;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('resetProgress on one card', () {
    test('leaves the other direction of the same vocab untouched', () {
      final vocab = VocabItem(
        targetWord: '배',
        translation: 'pear',
        pos: 'nouns',
      );
      SrsService.processReview(vocab.cardTargetToNative, SrsRating.good);
      SrsService.processReview(vocab.cardNativeToTarget, SrsRating.good);
      final otherInterval = vocab.cardNativeToTarget.interval;
      final otherRepetitions = vocab.cardNativeToTarget.repetitions;

      vocab.cardTargetToNative.resetProgress();

      expect(vocab.cardTargetToNative.status, SrsStatus.isNew);
      expect(vocab.cardTargetToNative.repetitions, 0);
      expect(vocab.cardTargetToNative.lastReviewed, isNull);
      expect(vocab.cardTargetToNative.introducedAt, isNull);
      expect(vocab.cardNativeToTarget.status, isNot(SrsStatus.isNew));
      expect(vocab.cardNativeToTarget.interval, otherInterval);
      expect(vocab.cardNativeToTarget.repetitions, otherRepetitions);
    });
  });

  group('forgetCardInSession', () {
    test('treats the card as never rated or failed this session', () {
      final card = learnedCard();
      final queue = [itemFor('a', card: card), itemFor('b')];
      final againIds = <String>{card.id};
      final ratedIds = <String>{card.id, 'other'};

      forgetCardInSession(
        card: card,
        queue: queue,
        currentIndex: 0,
        againCardIds: againIds,
        sessionRatedCardIds: ratedIds,
      );

      expect(againIds, isEmpty);
      expect(ratedIds, {'other'});
    });

    test('drops later copies of the card but keeps everything else', () {
      final card = learnedCard();
      final a = itemFor('a', card: card);
      final b = itemFor('b');
      final c = itemFor('c');
      // a is current (index 2); an older copy sits behind it and a stale
      // re-queued copy sits ahead.
      final queue = [dupOf(a), b, a, c, dupOf(a)];

      forgetCardInSession(
        card: card,
        queue: queue,
        currentIndex: 2,
        againCardIds: {card.id},
        sessionRatedCardIds: {card.id},
      );

      expect(queue.length, 4);
      expect(queue[2], same(a));
      expect(queue.last, same(c));
      expect(queue.where((i) => i.card.id == card.id).length, 2);
    });

    test('leaves the queue alone when no copy is ahead', () {
      final card = learnedCard();
      final queue = [itemFor('a', card: card), itemFor('b')];
      final before = List.of(queue);

      forgetCardInSession(
        card: card,
        queue: queue,
        currentIndex: 0,
        againCardIds: {},
        sessionRatedCardIds: {},
      );

      expect(queue, before);
    });

    test('a rating after the reset is a first-session rating again', () {
      final card = learnedCard();
      final ratedIds = <String>{card.id};
      final againIds = <String>{card.id};

      card.resetProgress();
      forgetCardInSession(
        card: card,
        queue: [itemFor('a', card: card)],
        currentIndex: 0,
        againCardIds: againIds,
        sessionRatedCardIds: ratedIds,
      );

      // Mirrors _rateCard: first-session means it was not already rated.
      expect(!ratedIds.contains(card.id), isTrue);
      expect(againIds.contains(card.id), isFalse);
      expect(card.isNewCard, isTrue);
    });

    test('undo after a reset walks back through the reset to the original', () {
      final card = learnedCard();
      final original = (
        interval: card.interval,
        repetitions: card.repetitions,
        status: card.status,
      );

      // Rate it (Again), then reset it, then rate the now-new card.
      final first = ReviewHistoryRecord.capture(
        queueIndex: 0,
        card: card,
        rating: SrsRating.again,
      );
      SrsService.processReview(card, SrsRating.again);

      card.resetProgress();
      final second = ReviewHistoryRecord.capture(
        queueIndex: 1,
        card: card,
        rating: SrsRating.good,
      );
      SrsService.processReview(card, SrsRating.good);

      second.restore();
      expect(card.status, SrsStatus.isNew);
      expect(card.repetitions, 0);

      first.restore();
      expect(card.interval, original.interval);
      expect(card.repetitions, original.repetitions);
      expect(card.status, original.status);
    });
  });

  group('Reset card during review', () {
    const pathProviderChannel = MethodChannel(
      'plugins.flutter.io/path_provider',
    );
    late Directory storageDirectory;

    setUp(() {
      storageDirectory = Directory.systemTemp.createTempSync(
        'lingua_srs_card_reset_test_',
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

    /// One lesson with one noun. Only KO ➔ EN is studied; it is either due
    /// (learned a while ago) or still new.
    Future<({Lesson lesson, VocabItem vocab})> seed(
      WidgetTester tester,
      AppProvider provider, {
      required bool due,
    }) async {
      const yaml =
          '---\nvocabulary:\n  nouns:\n    - ko: 단어\n      en: word\n---\n'
          '# Lesson\n';
      final lesson = (await tester.runAsync(() => provider.importYaml(yaml)))!;
      final vocab = lesson.vocabularies.single;
      vocab.cardNativeToTarget.isEnabled = false;
      if (due) {
        final card = vocab.cardTargetToNative;
        SrsService.processReview(card, SrsRating.good);
        SrsService.processReview(card, SrsRating.good);
        card.dueDate = DateTime.now().subtract(const Duration(days: 1));
      }
      return (lesson: lesson, vocab: vocab);
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

    Future<void> openMenu(WidgetTester tester) async {
      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
    }

    Finder resetMenuItem() =>
        find.widgetWithText(PopupMenuItem<String>, 'Reset card to New');

    bool resetEnabled(WidgetTester tester) =>
        tester.widget<PopupMenuItem<String>>(resetMenuItem()).enabled;

    testWidgets('provider.resetCardSrs resets only that card and notifies', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      final seeded = await seed(tester, provider, due: true);
      final other = seeded.vocab.cardNativeToTarget;
      SrsService.processReview(other, SrsRating.good);
      final otherRepetitions = other.repetitions;
      var notified = 0;
      provider.addListener(() => notified++);

      await tester.runAsync(
        () => provider.resetCardSrs(seeded.vocab.cardTargetToNative),
      );

      expect(seeded.vocab.cardTargetToNative.status, SrsStatus.isNew);
      expect(seeded.vocab.cardTargetToNative.repetitions, 0);
      expect(other.repetitions, otherRepetitions);
      expect(notified, greaterThan(0));
    });

    testWidgets('the menu item is disabled until the answer is shown', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      final seeded = await seed(tester, provider, due: true);
      await openStudy(tester, provider, seeded.lesson);

      await openMenu(tester);
      expect(resetEnabled(tester), isFalse);
    });

    testWidgets('the menu item is disabled for a card that is still New', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      final seeded = await seed(tester, provider, due: false);
      await openStudy(tester, provider, seeded.lesson);
      await reveal(tester);

      await openMenu(tester);
      expect(resetEnabled(tester), isFalse);
    });

    testWidgets('confirming resets the card and shows it as New', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      final seeded = await seed(tester, provider, due: true);
      await openStudy(tester, provider, seeded.lesson);
      await reveal(tester);
      expect(find.text('NEW'), findsNothing);
      expect(find.textContaining('Hard'), findsWidgets);

      await openMenu(tester);
      expect(resetEnabled(tester), isTrue);
      await tester.tap(resetMenuItem());
      await tester.pumpAndSettle();

      expect(find.textContaining('Reset this card'), findsOneWidget);
      await tester.tap(find.text('Reset to New'));
      await tester.pumpAndSettle();

      final card = seeded.vocab.cardTargetToNative;
      expect(card.status, SrsStatus.isNew);
      expect(card.repetitions, 0);
      expect(card.lastReviewed, isNull);
      expect(find.text('NEW'), findsOneWidget);
      // A New card only offers Again and Good.
      expect(find.textContaining('Hard'), findsNothing);
      expect(find.textContaining('Easy'), findsNothing);
    });

    testWidgets('cancelling leaves the card unchanged', (tester) async {
      final provider = await loadedProvider(tester);
      final seeded = await seed(tester, provider, due: true);
      final card = seeded.vocab.cardTargetToNative;
      final repetitions = card.repetitions;
      await openStudy(tester, provider, seeded.lesson);
      await reveal(tester);

      await openMenu(tester);
      await tester.tap(resetMenuItem());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(card.status, isNot(SrsStatus.isNew));
      expect(card.repetitions, repetitions);
      expect(find.text('NEW'), findsNothing);
    });
  });
}
