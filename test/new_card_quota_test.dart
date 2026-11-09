import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/services/new_card_quota.dart';

void main() {
  final start = DateTime(2026, 1, 1, 8);
  DateTime at(double hours) =>
      start.add(Duration(minutes: (hours * 60).round()));
  List<DateTime> batch(double hours, int count) => [
    for (var i = 0; i < count; i++) at(hours),
  ];

  group('NewCardQuota', () {
    test('the full limit is open with no history', () {
      expect(NewCardQuota.remaining(10, const [], start), 10);
    });

    test('each start in the last 16 hours uses one card', () {
      final starts = batch(0, 4);
      expect(NewCardQuota.remaining(10, starts, at(1)), 6);
      expect(NewCardQuota.remaining(10, starts, at(15.9)), 6);
    });

    test('a full batch refills 16 hours later, not 24', () {
      final starts = batch(0, 10);
      expect(NewCardQuota.remaining(10, starts, at(15.9)), 0);
      expect(NewCardQuota.remaining(10, starts, at(16)), 10);
    });

    test('a daily batch can move earlier without losing cards', () {
      // Every day at 8:00 for a week, then at 6:00.
      final starts = [for (var day = 0; day < 7; day++) ...batch(day * 24, 10)];
      expect(NewCardQuota.remaining(10, starts, at(7 * 24 - 2)), 10);
    });

    test('batches every 16 hours slow down to the limit per day', () {
      final starts = <DateTime>[];
      var hours = 0.0;
      // Full batches 16 hours apart use up the carried-over day...
      for (var i = 0; i < 4; i++) {
        final left = NewCardQuota.remaining(10, starts, at(hours));
        expect(left, 10, reason: 'batch $i');
        starts.addAll(batch(hours, left));
        hours += 16;
      }
      // ...after which a batch 16 hours later is only partly open.
      final left = NewCardQuota.remaining(10, starts, at(hours));
      expect(left, inInclusiveRange(1, 9));
    });

    test('over many days the average stays at the limit', () {
      // Whoever studies every 16 hours, taking every card offered, starts
      // no more than the limit per 24 hours, plus the full allowance (two
      // days' worth) they began with.
      final starts = <DateTime>[];
      const days = 30;
      for (var hours = 0.0; hours < days * 24; hours += 16) {
        starts.addAll(
          batch(hours, NewCardQuota.remaining(10, starts, at(hours))),
        );
      }
      expect(starts.length, lessThanOrEqualTo(10 * (days + 2)));
      expect(starts.length, greaterThanOrEqualTo(10 * (days - 1)));
    });

    test('a day off lets the next two batches come 16 hours apart', () {
      final starts = batch(0, 10);
      // Nothing on day 2; day 3 at 8:00 and then 16 hours later.
      final third = [...starts, ...batch(48, 10)];
      expect(NewCardQuota.remaining(10, third, at(48 + 16)), 10);
    });

    test('cards started past the limit are not paid back for days', () {
      // Learn New Words started 50 cards at once.
      final starts = batch(0, 50);
      expect(NewCardQuota.remaining(10, starts, at(15)), 0);
      expect(NewCardQuota.remaining(10, starts, at(24)), 10);
    });

    test('starts in the future are ignored, and old ones run out', () {
      final starts = [...batch(-24 * 30, 10), at(5)];
      expect(NewCardQuota.remaining(10, starts, start), 10);
    });
  });
}
