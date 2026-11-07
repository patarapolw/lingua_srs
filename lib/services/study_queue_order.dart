import 'dart:math';

/// How many reviews of already-seen cards a day starts with before any new
/// card is mixed in.
const int reviewsBeforeNewCards = 10;

/// Reviews still to come before the first new card, given [reviewsToday]
/// reviews of seen cards already done today.
int newCardLeadIn(int reviewsToday) =>
    max(0, reviewsBeforeNewCards - reviewsToday);

/// Puts [items] in an order that spreads their groups out: each round takes
/// one item from every group, in a random group order, so items of the same
/// group (e.g. part of speech) rarely sit next to each other.
List<T> interleaveByGroup<T>(
  Iterable<T> items,
  String Function(T item) groupOf,
  Random rand,
) {
  final groups = <String, List<T>>{};
  for (final item in items) {
    groups.putIfAbsent(groupOf(item), () => []).add(item);
  }
  final buckets = [
    for (final key in groups.keys.toList()..shuffle(rand))
      groups[key]!..shuffle(rand),
  ];
  final result = <T>[];
  while (buckets.isNotEmpty) {
    buckets.shuffle(rand);
    for (var i = buckets.length - 1; i >= 0; i--) {
      final bucket = buckets[i];
      if (bucket.isNotEmpty) result.add(bucket.removeLast());
      if (bucket.isEmpty) buckets.removeAt(i);
    }
  }
  return result;
}

/// Mixes [newCards] into [reviews]: the first [leadIn] reviews come first,
/// then the new cards, in their order, are spread evenly through the
/// remaining reviews, the first one right after the lead-in. With no reviews
/// left after the lead-in, the new cards follow.
List<T> mixNewCardsIntoReviews<T>({
  required List<T> reviews,
  required List<T> newCards,
  required int leadIn,
}) {
  final head = min(max(0, leadIn), reviews.length);
  final rest = reviews.length - head;
  final result = <T>[...reviews.take(head)];
  var nextReview = head;
  for (var i = 0; i < newCards.length; i++) {
    final reviewsBefore = head + i * rest ~/ newCards.length;
    while (nextReview < reviewsBefore) {
      result.add(reviews[nextReview++]);
    }
    result.add(newCards[i]);
  }
  result.addAll(reviews.skip(nextReview));
  return result;
}
