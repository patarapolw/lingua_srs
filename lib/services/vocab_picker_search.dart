import '../models/vocab_merge_record.dart';
import 'english_text_search.dart';
import 'korean_text_search.dart';
import 'vocab_ai_service.dart';

enum PickerMatch { sameKorean, similarKorean, sameMeaning, similarMeaning }

class PickerHit {
  const PickerHit(this.group, this.score, this.matches);
  final VocabGroup group;
  final int score;
  final Set<PickerMatch> matches;
}

/// Ranks vocabulary for the "Merge with another word" picker, using both
/// Korean and English matching.
class VocabPickerSearch {
  /// Below this, a word is not shown as a suggestion before typing.
  static const int suggestionThreshold = 250;

  static bool hasHangul(String s) => s.runes.any(
    (r) =>
        (r >= 0xAC00 && r <= 0xD7A3) || // syllables
        (r >= 0x1100 && r <= 0x11FF) || // jamo
        (r >= 0x3130 && r <= 0x318F), // compatibility jamo (IME typing)
  );

  /// How [other] relates to [current]; null when it doesn't.
  static PickerHit? _relation(VocabGroup current, VocabGroup other) {
    var score = 0;
    final matches = <PickerMatch>{};
    final ko = VocabSimilarity.normalizeTarget(current.entry.targetWord);
    final otherKo = VocabSimilarity.normalizeTarget(other.entry.targetWord);
    if (ko.isNotEmpty && ko == otherKo) {
      score += 1000;
      matches.add(PickerMatch.sameKorean);
    } else if (KoreanTextSearch.areVariants(
      current.entry.targetWord,
      other.entry.targetWord,
    )) {
      score += 700;
      matches.add(PickerMatch.similarKorean);
    }
    final en = EnglishTextSearch.score(
      current.entry.translation,
      translation: other.entry.translation,
      notes: other.entry.notes,
    );
    if (en == 100) {
      score += 500;
      matches.add(PickerMatch.sameMeaning);
    } else if (en >= 60) {
      score += 300;
      matches.add(PickerMatch.similarMeaning);
    } else if (en >= 40) {
      score += 200; // a prefix-level match only helps next to a Korean match
      matches.add(PickerMatch.similarMeaning);
    }
    if (score == 0) return null;
    if (_samePos(current, other)) score += 30;
    return PickerHit(other, score, matches);
  }

  static bool _samePos(VocabGroup a, VocabGroup b) =>
      a.entry.pos.trim().toLowerCase() == b.entry.pos.trim().toLowerCase();

  static void _sort(List<PickerHit> hits) => hits.sort((a, b) {
    final byScore = b.score.compareTo(a.score);
    return byScore != 0 ? byScore : a.group.label.compareTo(b.group.label);
  });

  /// Shown before the user types anything.
  static List<PickerHit> suggest(
    VocabGroup current,
    List<VocabGroup> groups, {
    int limit = 30,
  }) {
    final hits = <PickerHit>[];
    for (final g in groups) {
      if (g.id == current.id) continue;
      final hit = _relation(current, g);
      if (hit != null && hit.score >= suggestionThreshold) hits.add(hit);
    }
    _sort(hits);
    return hits.length > limit ? hits.sublist(0, limit) : hits;
  }

  /// Korean and English at once. Hangul in the query searches the Korean side;
  /// anything without Hangul searches meanings. The old label-substring match
  /// stays as a last resort.
  static List<PickerHit> search(
    String query,
    VocabGroup current,
    List<VocabGroup> groups, {
    int limit = 100,
  }) {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final nq = VocabSimilarity.normalizeTarget(q);
    final korean = hasHangul(q);
    final latin = RegExp(r'[A-Za-z]').hasMatch(q);
    final hits = <PickerHit>[];
    for (final g in groups) {
      if (g.id == current.id) continue;
      var score = 0;
      if (korean) {
        final target = VocabSimilarity.normalizeTarget(g.entry.targetWord);
        if (target == nq) {
          score = 1000;
        } else if (target.startsWith(nq)) {
          score = 800;
        } else if (target.contains(nq)) {
          score = 600;
        } else if (KoreanTextSearch.areVariants(q, g.entry.targetWord)) {
          score = 500;
        } else if (KoreanTextSearch.matches(
          query: q,
          targetText: g.entry.targetWord,
          translationText: g.entry.translation,
        )) {
          score = 300;
        }
      }
      if (latin || !korean) {
        final en = EnglishTextSearch.score(
          q,
          translation: g.entry.translation,
          notes: g.entry.notes,
        );
        final enScore = en == 100
            ? 900
            : en >= 60
            ? 700
            : en >= 40
            ? 450
            : en >= 20
            ? 200
            : en > 0
            ? 50
            : 0;
        if (enScore > score) score = enScore;
      }
      if (score == 0 && g.label.toLowerCase().contains(q.toLowerCase())) {
        score = 100;
      }
      if (score == 0) continue;
      // Among equal text matches, prefer words close to the one being edited.
      final related = _relation(current, g);
      hits.add(
        PickerHit(
          g,
          score + (related == null ? 0 : related.score ~/ 100),
          related?.matches ?? const <PickerMatch>{},
        ),
      );
    }
    _sort(hits);
    return hits.length > limit ? hits.sublist(0, limit) : hits;
  }
}
