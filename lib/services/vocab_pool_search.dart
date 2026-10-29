import '../models/vocab_merge_record.dart';
import 'vocab_picker_search.dart';

/// Browsing and searching every distinct vocabulary, for the Vocab Pool tab.
class VocabPoolSearch {
  static String _posKey(String pos) => pos.trim().toLowerCase();

  /// The parts of speech in [groups], one per spelling, sorted. Words without
  /// one are left out.
  static List<String> posOptions(List<VocabGroup> groups) {
    final byKey = <String, String>{};
    for (final g in groups) {
      final key = _posKey(g.entry.pos);
      if (key.isNotEmpty) byKey.putIfAbsent(key, () => g.entry.pos.trim());
    }
    final keys = byKey.keys.toList()..sort();
    return [for (final k in keys) byKey[k]!];
  }

  /// Without a [query], every word sorted by its target form. With one, the
  /// words that match it, best first. [pos] keeps only that part of speech.
  /// Hangul in the query searches the Korean side, anything else the meanings.
  static List<VocabGroup> search(
    String query,
    List<VocabGroup> groups, {
    String? pos,
    int? limit,
  }) {
    final posKey = pos == null ? '' : _posKey(pos);
    final q = query.trim();
    final candidates = [
      for (final g in groups)
        if (posKey.isEmpty || _posKey(g.entry.pos) == posKey) g,
    ];

    final List<VocabGroup> result;
    if (q.isEmpty) {
      result = candidates
        ..sort((a, b) {
          final byTarget = a.entry.targetWord.compareTo(b.entry.targetWord);
          return byTarget != 0
              ? byTarget
              : a.entry.translation.compareTo(b.entry.translation);
        });
    } else {
      final scored = <MapEntry<VocabGroup, int>>[];
      for (final g in candidates) {
        final score = VocabPickerSearch.textScore(q, g);
        if (score > 0) scored.add(MapEntry(g, score));
      }
      scored.sort((a, b) {
        final byScore = b.value.compareTo(a.value);
        return byScore != 0 ? byScore : a.key.label.compareTo(b.key.label);
      });
      result = [for (final e in scored) e.key];
    }
    return limit != null && result.length > limit
        ? result.sublist(0, limit)
        : result;
  }
}
