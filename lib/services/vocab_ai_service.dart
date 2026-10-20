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

class VocabSimilarity {
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

  static List<AiDiscussionMessage> hintMessages(
    VocabItem vocab,
    List<VocabItem> sameFront,
  ) {
    const system =
        'You write a very short "front hint" for a flashcard so that cards with '
        'the same front can be told apart. Describe the sense of the TARGET '
        'entry (for example "fruit" versus "stomach"). Use 1 to 3 lowercase '
        'English words. Do not repeat the translation and do not give away the '
        'answer. Reply with JSON only: {"hint":"<hint>"}.';
    Map<String, String> describe(VocabItem v) => {
      'word': v.targetWord,
      'translation': v.translation,
      'pos': v.pos,
      'notes': v.notes,
    };
    return [
      const AiDiscussionMessage(role: 'system', content: system),
      AiDiscussionMessage(
        role: 'user',
        content: jsonEncode({
          'target': describe(vocab),
          'sameFront': sameFront.map(describe).toList(),
        }),
      ),
    ];
  }

  static String parseHint(String reply) {
    final raw = _decodeObject(reply)['hint'];
    var hint = raw is String ? raw.trim() : '';
    hint = hint.replaceAll(RegExp('^["\'“”]+|["\'“”]+\$'), '').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (hint.isEmpty) throw const FormatException('The AI returned no hint.');
    return hint.length > 40 ? hint.substring(0, 40).trim() : hint;
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