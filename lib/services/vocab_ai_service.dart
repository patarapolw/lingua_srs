import 'dart:convert';

import '../models/ai_discussion_message.dart';
import '../models/vocab_item.dart';
import '../models/vocab_merge_record.dart';

class VocabMergeGroup {
  const VocabMergeGroup(this.number, this.target, this.items);
  final int number;
  final String target; // normalized target word
  final List<VocabGroup> items;
}

class VocabMergeSuggestion {
  const VocabMergeSuggestion({
    required this.keepId,
    required this.mergeIds,
    this.reason = '',
  });
  final String keepId;
  final List<String> mergeIds;
  final String reason;

  /// Survivor = the entry with the most reviews (ties keep the AI's choice).
  VocabMergeSuggestion withSurvivor(Map<String, int> reviewsById) {
    final ids = [keepId, ...mergeIds];
    var best = keepId;
    for (final id in ids) {
      if ((reviewsById[id] ?? 0) > (reviewsById[best] ?? 0)) best = id;
    }
    if (best == keepId) return this;
    return VocabMergeSuggestion(
      keepId: best,
      mergeIds: ids.where((id) => id != best).toList(),
      reason: reason,
    );
  }
}

class SimilarVocabHint {
  const SimilarVocabHint({required this.id, required this.hint});
  final String id;
  final String hint; // may be empty
}

class SimilarMeaningResult {
  const SimilarMeaningResult({required this.hint, required this.similar});
  final String hint; // for the vocab being edited; may be empty
  final List<SimilarVocabHint> similar;
}

class SimilarPrompt {
  const SimilarPrompt(this.messages, this.ids);
  final List<AiDiscussionMessage> messages;
  final List<String> ids; // ids[n - 1] is the vocab shown as number n
}

class VocabSimilarity {
  static const int maxPoolSize = 1200;

  static final _wordSplit = RegExp(r'[^\p{L}\p{N}]+', unicode: true);
  static Set<String> _words(String value) =>
      value.split(_wordSplit).where((w) => w.isNotEmpty).toSet();

  /// Every other vocabulary with the same POS but a different Korean form.
  static List<VocabGroup> similarPool(VocabItem target, List<VocabGroup> groups) {
    final pos = target.pos.trim().toLowerCase();
    final form = normalizeTarget(target.targetWord);
    return [
      for (final g in groups)
        if (g.id != target.id &&
            g.entry.pos.trim().toLowerCase() == pos &&
            normalizeTarget(g.entry.targetWord) != form)
          g,
    ];
  }

  /// Keeps the [limit] most lexically similar entries when the pool is huge.
  static List<VocabGroup> shortlist(
    VocabItem target,
    List<VocabGroup> pool, {
    int limit = maxPoolSize,
  }) {
    if (pool.length <= limit) return pool;
    final targetWords = _words(normalizeTranslation(target.translation));
    final targetChars = target.targetWord.runes.toSet();
    int score(VocabGroup g) =>
        _words(normalizeTranslation(g.entry.translation)).intersection(targetWords).length * 4 +
        g.entry.targetWord.runes.toSet().intersection(targetChars).length;
    final scored = [for (final g in pool) MapEntry(g, score(g))]
      ..sort((a, b) => b.value.compareTo(a.value));
    return [for (final e in scored.take(limit)) e.key];
  }

  static String normalizeTarget(String value) =>
      value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  /// "To be beautiful" / "a beautiful (thing)" -> "beautiful"
  static String normalizeTranslation(String value) {
    final base = normalizeTarget(value).replaceAll(RegExp(r'\s*\([^)]*\)'), '').trim();
    final stripped = base
        .replaceFirst(RegExp(r'^(to be|to|be)\s+'), '')
        .replaceFirst(RegExp(r'^(a|an|the)\s+'), '')
        .trim();
    return stripped.isEmpty ? base : stripped;
  }

  /// Distinct vocabularies that share a target word: the only things sent to the AI.
  static List<VocabMergeGroup> findCandidateGroups(List<VocabGroup> groups) {
    final buckets = <String, List<VocabGroup>>{};
    for (final group in groups) {
      final key = normalizeTarget(group.entry.targetWord);
      if (key.isEmpty) continue;
      buckets.putIfAbsent(key, () => []).add(group);
    }
    var number = 0;
    return [
      for (final entry in buckets.entries)
        if (entry.value.length > 1)
          VocabMergeGroup(++number, entry.key, entry.value),
    ];
  }
}

class VocabAiPrompts {
  static const int maxSimilar = 8;

  static String _oneLine(String s) => s.replaceAll(RegExp(r'[|\r\n]+'), ' ').trim();

  static SimilarPrompt similarPrompt(
    VocabItem target,
    List<VocabItem> sameFront,
    List<VocabGroup> pool,
  ) {
    const system =
        'You help a Korean learner avoid confusing flashcards. You get a TARGET '
        'vocabulary entry, optionally SAMEFRONT entries (cards with the same '
        'front text), and a numbered POOL of other entries with the same part '
        'of speech, one per line as number|Korean|English. Pick the pool '
        'entries whose meaning is so close to the target that a learner shown '
        'the English could answer with either Korean word, or shown the Korean '
        'could mistake its meaning: near-synonyms with different Korean forms '
        '(for example 크다 "big" versus 넓다 "wide"), including entries that share '
        'the English gloss. Ignore a leading "to"/"to be", articles and '
        'punctuation. Do not list entries that are only related by topic. List '
        'at most $maxSimilar, most confusable first. For the target and for each '
        'listed entry write a front hint: 1 to 3 lowercase English words naming '
        'the specific nuance that separates it from the others (for example '
        '"general size", "area or width"). Never repeat the English gloss and '
        'never reveal the Korean. If nothing is confusable, return an empty '
        '"similar" list, and give the target a hint only when SAMEFRONT is not '
        'empty, otherwise an empty hint. Reply with JSON only: '
        '{"hint":"...","similar":[{"n":<number>,"hint":"..."}]}';
    Map<String, String> describe(VocabItem v) => {
      'word': v.targetWord,
      'translation': v.translation,
      'pos': v.pos,
      'notes': v.notes,
    };
    final lines = StringBuffer();
    for (var i = 0; i < pool.length; i++) {
      final e = pool[i].entry;
      lines.writeln('${i + 1}|${_oneLine(e.targetWord)}|${_oneLine(e.translation)}');
    }
    return SimilarPrompt(
      [
        const AiDiscussionMessage(role: 'system', content: system),
        AiDiscussionMessage(
          role: 'user',
          content: jsonEncode({
            'target': describe(target),
            'sameFront': sameFront.map(describe).toList(),
            'pool': lines.toString().trimRight(),
          }),
        ),
      ],
      [for (final g in pool) g.id],
    );
  }

  static SimilarMeaningResult parseSimilarResult(String reply, List<String> ids) {
    final json = _decodeObject(reply);
    final seen = <String>{};
    final similar = <SimilarVocabHint>[];
    final raw = json['similar'];
    if (raw is List) {
      for (final item in raw) {
        if (item is! Map) continue;
        final n = item['n'];
        if (n is! num || n.toInt() < 1 || n.toInt() > ids.length) continue;
        final id = ids[n.toInt() - 1];
        if (!seen.add(id)) continue;
        similar.add(SimilarVocabHint(id: id, hint: _cleanHint(item['hint'])));
        if (similar.length == maxSimilar) break;
      }
    }
    return SimilarMeaningResult(hint: _cleanHint(json['hint']), similar: similar);
  }

  static String _cleanHint(Object? raw) {
    var hint = raw is String ? raw.trim() : '';
    hint = hint
        .replaceAll(RegExp('^["\'“”]+|["\'“”]+\$'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return hint.length > 40 ? hint.substring(0, 40).trim() : hint;
  }

  static List<AiDiscussionMessage> mergeMessages(List<VocabMergeGroup> groups) {
    const system =
        'You help clean up a language-learning flashcard deck. Each group lists '
        'vocabulary entries that share the same target-language word but have '
        'different ids. Decide which entries are the SAME vocabulary item with '
        'the SAME sense and should share one progress record. These are NOT '
        'differences: a leading "to", "to be" or "be", articles (a/an/the), '
        'capitalisation, punctuation, optional text in parentheses, or equivalent '
        'glosses in a different order. Do NOT merge entries with genuinely '
        'different senses (homonyms) . When unsure, do not merge. Reply with JSON '
        'only: {"merges":[{"group":<number>,"keep":"<id>","merge":["<id>"],'
        '"reason":"<at most 12 words>"}]}. Use only ids from the input. Omit '
        'groups with nothing to merge.';
    final payload = {
      'groups': [
        for (final group in groups)
          {
            'group': group.number,
            'target': group.items.first.entry.targetWord,
            'items': [
              for (final item in group.items)
                {
                  'id': item.id,
                  'translation': item.entry.translation,
                  'pos': item.entry.pos,
                  'notes': item.entry.notes,
                  'lessons': item.lessonTitles,
                },
            ],
          },
      ],
    };
    return [
      const AiDiscussionMessage(role: 'system', content: system),
      AiDiscussionMessage(role: 'user', content: jsonEncode(payload)),
    ];
  }

  static List<VocabMergeSuggestion> parseMergeSuggestions(
    String reply,
    List<VocabMergeGroup> groups,
  ) {
    final byNumber = {for (final g in groups) g.number: g};
    final merges = _decodeObject(reply)['merges'];
    if (merges is! List) return const [];
    final used = <String>{};
    final result = <VocabMergeSuggestion>[];
    for (final raw in merges) {
      if (raw is! Map) continue;
      final number = raw['group'];
      final group = number is num ? byNumber[number.toInt()] : null;
      if (group == null) continue;
      final valid = group.items.map((item) => item.id).toSet();
      final keep = raw['keep'];
      if (keep is! String || !valid.contains(keep) || used.contains(keep)) continue;
      final mergeIds = <String>{
        for (final id in (raw['merge'] as List? ?? const []))
          if (id is String && valid.contains(id) && id != keep && !used.contains(id))
            id,
      }.toList();
      if (mergeIds.isEmpty) continue;
      used
        ..add(keep)
        ..addAll(mergeIds);
      result.add(
        VocabMergeSuggestion(
          keepId: keep,
          mergeIds: mergeIds,
          reason: (raw['reason'] as String? ?? '').trim(),
        ),
      );
    }
    return result;
  }

  static Map<String, dynamic> _decodeObject(String reply) {
    var text = reply.trim();
    if (text.startsWith('```')) {
      text = text
          .replaceFirst(RegExp(r'^```(?:json)?\s*'), '')
          .replaceFirst(RegExp(r'\s*```$'), '');
    }
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Expected a JSON object.');
    }
    return decoded;
  }
}