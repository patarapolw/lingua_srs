import '../models/vocab_merge_record.dart';

class VocabSearchHit {
  const VocabSearchHit(this.group, this.score);
  final VocabGroup group;
  final int score;
}

/// Light English full-text search over vocabulary meanings.
class EnglishTextSearch {
  static const _stopWords = {
    'to',
    'be',
    'a',
    'an',
    'the',
    'of',
    'or',
    'and',
    'for',
    'in',
    'on',
    'with',
    'something',
    'someone',
    'one',
  };
  static final _split = RegExp(r'[^a-z0-9]+');

  static String _clean(String text) => text
      .replaceAll(RegExp(r'<[^>]*>'), ' ')
      .replaceAll(RegExp(r'[*_`~]'), '')
      .toLowerCase();

  /// Deliberately light: running -> runn, walked -> walk, houses -> house.
  /// Prefix matching in [score] covers the rest.
  static String stem(String word) {
    if (word.length > 5 && word.endsWith('ing')) {
      return word.substring(0, word.length - 3);
    }
    if (word.length > 4 && word.endsWith('ed')) {
      return word.substring(0, word.length - 2);
    }
    if (word.length > 3 && word.endsWith('s') && !word.endsWith('ss')) {
      return word.substring(0, word.length - 1);
    }
    return word;
  }

  /// Stemmed content words. If a text is only stop words ("to be"), keeps them.
  static Set<String> tokens(String text) {
    final raw = [
      for (final t in _clean(text).split(_split))
        if (t.isNotEmpty) t,
    ];
    final content = raw.where((t) => !_stopWords.contains(t)).toList();
    return {for (final t in content.isEmpty ? raw : content) stem(t)};
  }

  static bool _prefixHit(String word, Set<String> pool) => pool.any(
    (other) =>
        (word.length >= 3 && other.startsWith(word)) ||
        (other.length >= 3 && word.startsWith(other)),
  );

  /// 0 means no match. Higher is closer.
  static int score(
    String query, {
    required String translation,
    String notes = '',
  }) {
    final q = tokens(query);
    if (q.isEmpty) return 0;
    final t = tokens(translation);
    if (t.isNotEmpty) {
      if (q.length == t.length && q.containsAll(t)) return 100; // same meaning
      if (q.every(t.contains)) return 60; // all query words present
      if (q.every((w) => t.contains(w) || _prefixHit(w, t))) return 40;
      final matched = q.where(t.contains).length;
      if (matched > 0) return 20 + matched * 5;
    }
    final n = tokens(notes);
    if (n.isNotEmpty) {
      if (q.every(n.contains)) return 10;
      if (q.any(n.contains)) return 5;
    }
    return 0;
  }

  static List<VocabSearchHit> search(
    String query,
    List<VocabGroup> groups, {
    String? pos,
    String? excludeId,
    int limit = 50,
  }) {
    final posKey = pos?.trim().toLowerCase();
    final hits = <VocabSearchHit>[];
    for (final g in groups) {
      if (g.id == excludeId) continue;
      if (posKey != null && g.entry.pos.trim().toLowerCase() != posKey) {
        continue;
      }
      final s = score(
        query,
        translation: g.entry.translation,
        notes: g.entry.notes,
      );
      if (s > 0) hits.add(VocabSearchHit(g, s));
    }
    hits.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      return byScore != 0 ? byScore : a.group.label.compareTo(b.group.label);
    });
    return hits.length > limit ? hits.sublist(0, limit) : hits;
  }
}
