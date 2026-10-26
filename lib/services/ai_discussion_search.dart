import '../models/ai_discussion_message.dart';
import '../models/lesson.dart';
import '../models/sentence.dart';
import '../models/vocab_item.dart';
import '../models/vocab_merge_record.dart';
import 'english_text_search.dart';
import 'korean_text_search.dart';
import 'lesson_ai_prompt.dart';
import 'vocab_ai_service.dart';
import 'vocab_picker_search.dart';

/// Ids of saved AI discussions about one vocabulary word and one sentence.
///
/// A vocabulary discussion is `<vocabId>:<sentenceId>`, or
/// `<vocabId>:no-sentence`. A whole-lesson discussion is `lesson:<lessonId>`
/// (see [LessonAiPrompt]). Explicit vocabulary ids are free text and may hold
/// a colon, while sentence ids never do, so the id is split at the last colon.
class AiDiscussionIds {
  static const noSentence = 'no-sentence';

  static String forVocab(String vocabId, String? sentenceId) =>
      '$vocabId:${sentenceId ?? noSentence}';

  /// The vocabulary a discussion is about; null for a whole-lesson one.
  static String? vocabIdFrom(String discussionId) {
    if (LessonAiPrompt.isLessonDiscussion(discussionId)) return null;
    final colon = discussionId.lastIndexOf(':');
    return colon < 0 ? discussionId : discussionId.substring(0, colon);
  }

  /// The sentence a discussion is about; null when it has none.
  static String? sentenceIdFrom(String discussionId) {
    if (LessonAiPrompt.isLessonDiscussion(discussionId)) return null;
    final colon = discussionId.lastIndexOf(':');
    if (colon < 0) return null;
    final sentenceId = discussionId.substring(colon + 1);
    return sentenceId.isEmpty || sentenceId == noSentence ? null : sentenceId;
  }
}

/// A saved discussion together with what it is about.
class AiDiscussionSummary {
  const AiDiscussionSummary({
    required this.id,
    required this.messages,
    this.lesson,
    this.vocab,
    this.sentence,
  });

  final String id;
  final List<AiDiscussionMessage> messages;
  final Lesson? lesson;
  final VocabItem? vocab;
  final Sentence? sentence;

  /// Looks up the lesson, vocabulary and sentence a discussion id points at.
  /// Any of them may be gone, for example after a lesson was deleted.
  factory AiDiscussionSummary.resolve({
    required String id,
    required List<AiDiscussionMessage> messages,
    required Iterable<Lesson> lessons,
    required Sentence? Function(String sentenceId) sentenceById,
  }) {
    if (LessonAiPrompt.isLessonDiscussion(id)) {
      final lessonId = LessonAiPrompt.lessonIdFrom(id);
      return AiDiscussionSummary(
        id: id,
        messages: messages,
        lesson: lessons.where((lesson) => lesson.id == lessonId).firstOrNull,
      );
    }
    final vocabId = AiDiscussionIds.vocabIdFrom(id);
    Lesson? lesson;
    VocabItem? vocab;
    for (final candidate in lessons) {
      final found = candidate.vocabularies
          .where((v) => v.id == vocabId)
          .firstOrNull;
      if (found != null) {
        lesson = candidate;
        vocab = found;
        break;
      }
    }
    final sentenceId = AiDiscussionIds.sentenceIdFrom(id);
    return AiDiscussionSummary(
      id: id,
      messages: messages,
      lesson: lesson,
      vocab: vocab,
      sentence: sentenceId == null ? null : sentenceById(sentenceId),
    );
  }

  bool get isLesson => LessonAiPrompt.isLessonDiscussion(id);

  String? get vocabId => AiDiscussionIds.vocabIdFrom(id);

  String get title =>
      vocab?.targetWord ?? lesson?.displayTitle ?? 'AI discussion';

  DateTime? get updatedAt {
    for (final message in messages.reversed) {
      if (message.createdAt != null) return message.createdAt;
    }
    return null;
  }

  /// The learner's latest question, or the last message when there is none.
  String get preview {
    for (final message in messages.reversed) {
      if (message.role == 'user' && message.content.trim().isNotEmpty) {
        return message.content.trim();
      }
    }
    if (messages.isNotEmpty) return messages.last.content.trim();
    return 'No messages';
  }
}

/// Searches saved discussions by the word, the sentence, the lesson and what
/// was said.
class AiDiscussionSearch {
  /// Most recently updated first; discussions without a time go last.
  static int newestFirst(AiDiscussionSummary a, AiDiscussionSummary b) {
    final x = a.updatedAt;
    final y = b.updatedAt;
    if (x != null && y != null) {
      final byTime = y.compareTo(x);
      if (byTime != 0) return byTime;
    } else if (x == null && y != null) {
      return 1;
    } else if (x != null) {
      return -1;
    }
    return a.id.compareTo(b.id);
  }

  /// The discussions matching [query], best match first and newest first among
  /// equals. An empty query returns all of them, newest first.
  static List<AiDiscussionSummary> search(
    String query,
    Iterable<AiDiscussionSummary> discussions,
  ) {
    final q = query.trim();
    if (q.isEmpty) return discussions.toList()..sort(newestFirst);
    final scored = <(AiDiscussionSummary, int)>[];
    for (final discussion in discussions) {
      final value = score(q, discussion);
      if (value > 0) scored.add((discussion, value));
    }
    scored.sort((a, b) {
      final byScore = b.$2.compareTo(a.$2);
      return byScore != 0 ? byScore : newestFirst(a.$1, b.$1);
    });
    return [for (final entry in scored) entry.$1];
  }

  /// 0 means no match. A word or meaning ranks above the lesson or sentence it
  /// came with, which ranks above something said in the conversation.
  static int score(String query, AiDiscussionSummary discussion) {
    final q = query.trim();
    if (q.isEmpty) return 0;
    var best = 0;
    void take(int value) {
      if (value > best) best = value;
    }

    final hasHangul = VocabPickerSearch.hasHangul(q);
    final normalized = VocabSimilarity.normalizeTarget(q);

    if (discussion.vocab case final vocab?) {
      if (hasHangul) {
        final target = VocabSimilarity.normalizeTarget(vocab.targetWord);
        if (target == normalized) {
          take(1000);
        } else if (target.startsWith(normalized)) {
          take(800);
        } else if (target.contains(normalized)) {
          take(600);
        } else if (KoreanTextSearch.areVariants(q, vocab.targetWord)) {
          take(500);
        } else if (KoreanTextSearch.matches(
          query: q,
          targetText: vocab.targetWord,
          translationText: vocab.translation,
        )) {
          take(300);
        }
      }
      if (!hasHangul || RegExp(r'[A-Za-z]').hasMatch(q)) {
        final english = EnglishTextSearch.score(
          q,
          translation: vocab.translation,
          notes: vocab.notes,
        );
        take(
          english == 100
              ? 900
              : english >= 60
              ? 700
              : english >= 40
              ? 450
              : english >= 20
              ? 200
              : english > 0
              ? 50
              : 0,
        );
      }
    }

    if (discussion.isLesson && discussion.lesson != null) {
      if (_contains(discussion.lesson!.displayTitle, q)) take(600);
    }

    if (discussion.sentence case final sentence?) {
      if (_contains(sentence.targetText, q) ||
          _contains(sentence.translationText, q)) {
        take(250);
      } else if (hasHangul &&
          KoreanTextSearch.matches(
            query: q,
            targetText: sentence.targetText,
            translationText: sentence.translationText,
          )) {
        take(180);
      }
    }

    final lower = q.toLowerCase();
    final words = lower.split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    for (final message in discussion.messages) {
      final text = message.content.toLowerCase();
      if (text.contains(lower)) {
        take(message.role == 'user' ? 200 : 170);
      } else if (words.length > 1 && words.every(text.contains)) {
        take(120);
      }
    }
    return best;
  }

  static bool _contains(String text, String query) =>
      text.toLowerCase().contains(query.toLowerCase());
}

/// An earlier discussion worth showing next to the one being opened.
class AiDiscussionSuggestion {
  const AiDiscussionSuggestion(
    this.discussion, {
    required this.sameWord,
    this.matches = const {},
    this.score = 0,
  });

  final AiDiscussionSummary discussion;

  /// About the very same vocabulary, but another sentence.
  final bool sameWord;

  /// How a different word relates to the current one.
  final Set<PickerMatch> matches;
  final int score;

  /// Why this discussion is shown; null for a plain search hit.
  String? get label {
    if (sameWord) return 'Same word';
    if (matches.contains(PickerMatch.sameKorean)) return 'Same spelling';
    if (matches.contains(PickerMatch.similarKorean)) return 'Similar word';
    if (matches.contains(PickerMatch.sameMeaning)) return 'Same meaning';
    if (matches.contains(PickerMatch.similarMeaning)) return 'Similar meaning';
    return null;
  }
}

/// Which earlier discussions to offer when a new one is opened.
class AiDiscussionSuggestions {
  /// Other discussions about the same word first (a word shows a random
  /// sentence each time, so earlier chats usually sit under another sentence),
  /// then the latest one for each related word. Lesson discussions and empty
  /// ones are never suggested.
  static List<AiDiscussionSuggestion> forDiscussion({
    required String discussionId,
    required List<VocabGroup> groups,
    required Iterable<AiDiscussionSummary> discussions,
    int limit = 6,
  }) {
    final vocabId = AiDiscussionIds.vocabIdFrom(discussionId);
    if (vocabId == null) return const [];
    final saved = [
      for (final discussion in discussions)
        if (discussion.id != discussionId &&
            !discussion.isLesson &&
            discussion.messages.isNotEmpty)
          discussion,
    ]..sort(AiDiscussionSearch.newestFirst);

    final result = [
      for (final discussion in saved)
        if (discussion.vocabId == vocabId)
          AiDiscussionSuggestion(discussion, sameWord: true),
    ];

    final current = groups.where((group) => group.id == vocabId).firstOrNull;
    if (current != null) {
      final hits = {
        for (final hit in VocabPickerSearch.suggest(current, groups))
          hit.group.id: hit,
      };
      final seen = <String>{};
      final related = <AiDiscussionSuggestion>[];
      for (final discussion in saved) {
        final otherId = discussion.vocabId;
        if (otherId == null || otherId == vocabId) continue;
        final hit = hits[otherId];
        if (hit == null || !seen.add(otherId)) continue;
        related.add(
          AiDiscussionSuggestion(
            discussion,
            sameWord: false,
            matches: hit.matches,
            score: hit.score,
          ),
        );
      }
      related.sort((a, b) {
        final byScore = b.score.compareTo(a.score);
        return byScore != 0
            ? byScore
            : AiDiscussionSearch.newestFirst(a.discussion, b.discussion);
      });
      result.addAll(related);
    }
    return result.length > limit ? result.sublist(0, limit) : result;
  }
}

/// What the Related discussions panel lists.
class AiDiscussionRelated {
  /// While [query] is still [suggestedQuery] (the learner has not edited the
  /// box) the list starts with the suggestions for [discussionId], then adds
  /// whatever else the search finds. Any other query is a plain search, and an
  /// empty one lists everything, newest first. The discussion being viewed and
  /// empty ones are never listed.
  static List<AiDiscussionSuggestion> forPanel({
    required String discussionId,
    required String query,
    required String suggestedQuery,
    required List<VocabGroup> groups,
    required Iterable<AiDiscussionSummary> discussions,
    int limit = 30,
  }) {
    final others = [
      for (final discussion in discussions)
        if (discussion.id != discussionId && discussion.messages.isNotEmpty)
          discussion,
    ];
    final result = <AiDiscussionSuggestion>[];
    final seen = <String>{};
    if (query.trim() == suggestedQuery.trim()) {
      for (final suggestion in AiDiscussionSuggestions.forDiscussion(
        discussionId: discussionId,
        groups: groups,
        discussions: others,
        limit: limit,
      )) {
        if (seen.add(suggestion.discussion.id)) result.add(suggestion);
      }
    }
    for (final discussion in AiDiscussionSearch.search(query, others)) {
      if (result.length >= limit) break;
      if (seen.add(discussion.id)) {
        result.add(AiDiscussionSuggestion(discussion, sameWord: false));
      }
    }
    return result;
  }
}
