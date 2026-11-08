import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/saved_time.dart';
import 'package:lingua_srs/models/srs_card.dart';
import 'package:lingua_srs/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('saved times', () {
    test('are saved in UTC and read back as the same local instant', () {
      final time = DateTime(2026, 11, 8, 9, 30, 15, 123, 456);

      final saved = savedTime(time);
      final loaded = loadedTime(saved);

      expect(saved, endsWith('Z'));
      expect(loaded.isUtc, isFalse);
      expect(loaded.isAtSameMomentAs(time), isTrue);
      expect(loaded, time);
    });

    test('a time saved before, with no zone, is still local time', () {
      expect(loadedTime('2026-11-08T09:00:00.000'), DateTime(2026, 11, 8, 9));
    });

    test('a time with an offset is the same instant', () {
      final loaded = loadedTime('2026-11-08T09:00:00.000+07:00');

      expect(loaded.isUtc, isFalse);
      expect(loaded.isAtSameMomentAs(DateTime.utc(2026, 11, 8, 2)), isTrue);
    });

    test('tryLoadedTime is null for text that is not a time', () {
      expect(tryLoadedTime('soon'), isNull);
      expect(tryLoadedTime('2026-11-08T09:00:00Z'), isNotNull);
    });
  });

  group('SrsCard times', () {
    SrsCard card() => SrsCard(
      direction: CardDirection.targetToNative,
      status: SrsStatus.review,
      interval: 3,
      dueDate: DateTime(2026, 11, 10, 8),
      lastReviewed: DateTime(2026, 11, 7, 8),
      lastMistakeDate: DateTime(2026, 11, 6, 20),
      mistakesClearedAt: DateTime(2026, 11, 7, 7),
      introducedAt: DateTime(2026, 10, 1, 12),
    );

    const fields = [
      'dueDate',
      'lastReviewed',
      'lastMistakeDate',
      'mistakesClearedAt',
      'introducedAt',
    ];

    test('every time is saved in UTC', () {
      final json = card().toJson();

      for (final field in fields) {
        expect(json[field], endsWith('Z'), reason: field);
      }
    });

    test('round-trip to the same local times', () {
      final original = card();
      final restored = SrsCard.fromJson(original.toJson());

      expect(restored.dueDate, original.dueDate);
      expect(restored.lastReviewed, original.lastReviewed);
      expect(restored.lastMistakeDate, original.lastMistakeDate);
      expect(restored.mistakesClearedAt, original.mistakesClearedAt);
      expect(restored.introducedAt, original.introducedAt);
      expect(restored.dueDate.isUtc, isFalse);
    });

    test('a card saved before, without zones, loads as local times', () {
      final json = card().toJson()
        ..['dueDate'] = '2026-11-10T08:00:00.000'
        ..['introducedAt'] = '2026-10-01T12:00:00.000';

      final restored = SrsCard.fromJson(json);

      expect(restored.dueDate, DateTime(2026, 11, 10, 8));
      expect(restored.introducedAt, DateTime(2026, 10, 1, 12));
    });
  });

  group('review timestamps', () {
    test('are saved in UTC and loaded as local times', () async {
      SharedPreferences.setMockInitialValues({});
      final now = DateTime.now();
      final recent = now.subtract(const Duration(hours: 2));

      await StorageService.saveReviewTimestamps([recent]);
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getStringList('lingua_srs_review_timestamps_24h');
      final loaded = await StorageService.loadReviewTimestamps();

      expect(saved, [endsWith('Z')]);
      expect(loaded, [recent]);
    });

    test('ones saved before, without a zone, still load', () async {
      final recent = DateTime.now().subtract(const Duration(hours: 2));
      SharedPreferences.setMockInitialValues({
        'lingua_srs_review_timestamps_24h': [recent.toIso8601String()],
      });

      expect(await StorageService.loadReviewTimestamps(), [recent]);
    });
  });
}
