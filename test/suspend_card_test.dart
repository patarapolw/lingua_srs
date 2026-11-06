import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/lesson.dart';
import 'package:lingua_srs/models/srs_card.dart';
import 'package:lingua_srs/models/vocab_item.dart';
import 'package:lingua_srs/providers/app_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'secret_storage_mock.dart';

/// A word whose KO ➔ EN card is due and whose EN ➔ KO card is new.
VocabItem _word(String id) => VocabItem(
  id: id,
  targetWord: 'word-$id',
  translation: 'meaning-$id',
  pos: 'nouns',
  cardTargetToNative: SrsCard(
    id: '$id-tn',
    direction: CardDirection.targetToNative,
    status: SrsStatus.review,
    interval: 3,
    lastReviewed: DateTime.now().subtract(const Duration(days: 4)),
    dueDate: DateTime.now().subtract(const Duration(days: 1)),
  ),
  cardNativeToTarget: SrsCard(
    id: '$id-nt',
    direction: CardDirection.nativeToTarget,
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(setUpSecretStorage);

  group('SrsCard.isSuspended', () {
    test('takes the card out of reviews while it stays enabled', () {
      final card = SrsCard(
        direction: CardDirection.targetToNative,
        status: SrsStatus.learning,
        lastReviewed: DateTime.now().subtract(const Duration(hours: 1)),
        lastMistakeDate: DateTime.now().subtract(const Duration(hours: 1)),
        lastRating: SrsRating.again,
        dueDate: DateTime.now().subtract(const Duration(minutes: 1)),
      );
      expect(card.isActive, isTrue);
      expect(card.isDue, isTrue);
      expect(card.hasRecentMistake, isTrue);

      card.isSuspended = true;

      expect(card.isEnabled, isTrue);
      expect(card.isActive, isFalse);
      expect(card.isDue, isFalse);
      expect(card.isAvailable, isFalse);
      expect(card.hasRecentMistake, isFalse);
    });

    test('a suspended new card is not offered as new', () {
      final card = SrsCard(
        direction: CardDirection.targetToNative,
        isSuspended: true,
      );
      expect(card.isNewCard, isFalse);
    });

    test('survives JSON, and is false in data saved before it existed', () {
      final card = SrsCard(
        direction: CardDirection.targetToNative,
        isSuspended: true,
      );
      expect(SrsCard.fromJson(card.toJson()).isSuspended, isTrue);

      final old = card.toJson()..remove('isSuspended');
      expect(SrsCard.fromJson(old).isSuspended, isFalse);
    });

    test('resetting progress keeps the suspension', () {
      final card = SrsCard(
        direction: CardDirection.targetToNative,
        status: SrsStatus.review,
        isSuspended: true,
      )..resetProgress();
      expect(card.isSuspended, isTrue);
    });

    test("is left out of a lesson's card counts", () {
      final word = _word('a');
      final lesson = Lesson(title: 'L', vocabularies: [word]);
      expect(lesson.activeCardsCount, 2);
      expect(lesson.dueCardsCount, 1);
      expect(lesson.newCardsCount, 1);

      word.cardTargetToNative.isSuspended = true;
      word.cardNativeToTarget.isSuspended = true;

      expect(lesson.activeCardsCount, 0);
      expect(lesson.dueCardsCount, 0);
      expect(lesson.newCardsCount, 0);
    });
  });

  group('AppProvider.setCardSuspended', () {
    const pathProviderChannel = MethodChannel(
      'plugins.flutter.io/path_provider',
    );
    late Directory storageDirectory;
    late AppProvider provider;

    Future<AppProvider> load() async {
      final loaded = AppProvider();
      for (var i = 0; i < 100 && loaded.isLoading; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(loaded.isLoading, isFalse);
      return loaded;
    }

    setUp(() async {
      storageDirectory = Directory.systemTemp.createTempSync(
        'lingua_srs_suspend_card_test_',
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProviderChannel, (call) async {
            if (call.method == 'getApplicationSupportDirectory') {
              return storageDirectory.path;
            }
            throw MissingPluginException('Unexpected method: ${call.method}');
          });
      SharedPreferences.setMockInitialValues({
        'lingua_srs_windows_legacy_migration_complete': true,
      });
      provider = await load();
      provider.lessons.add(Lesson(title: 'L', vocabularies: [_word('a')]));
    });

    tearDown(() async {
      provider.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProviderChannel, null);
      if (storageDirectory.existsSync()) {
        await storageDirectory.delete(recursive: true);
      }
    });

    List<String> queuedCardIds() => [
      for (final item in provider.getStudyQueue(dueOnly: false)) item.card.id,
    ];

    test('leaves the card out of study until it is unsuspended', () async {
      final card = provider.lessons.single.vocabularies.single
          .cardTargetToNative;
      expect(queuedCardIds(), contains('a-tn'));

      await provider.setCardSuspended(card, true);
      expect(queuedCardIds(), isNot(contains('a-tn')));
      expect(queuedCardIds(), contains('a-nt'));
      expect(card.interval, 3, reason: 'progress is kept');

      await provider.setCardSuspended(card, false);
      expect(queuedCardIds(), contains('a-tn'));
    });

    test('is saved', () async {
      final card = provider.lessons.single.vocabularies.single
          .cardTargetToNative;
      await provider.setCardSuspended(card, true);

      final reloaded = await load();
      addTearDown(reloaded.dispose);
      final restored =
          reloaded.lessons.single.vocabularies.single.cardTargetToNative;
      expect(restored.isSuspended, isTrue);
      expect(restored.interval, 3);
    });
  });
}
