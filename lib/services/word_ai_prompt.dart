import '../models/ai_discussion_message.dart';

/// Builds the prompts for AI chats about a vocabulary word.
///
/// A word has one chat shared by all of its example sentences, so the sentence
/// on the card can change between two questions. A system prompt alone does not
/// survive that: the earlier answers pull the AI back to the sentence it was
/// first asked about. The current sentence is therefore also attached to the
/// newest question.
class WordAiPrompt {
  static String systemPrompt({
    required String targetLanguage,
    required String nativeLanguage,
    required String targetWord,
    required String translation,
    String? sentenceTarget,
    String? sentenceTranslation,
  }) {
    final sentence = _clean(sentenceTarget);
    final sentenceMeaning = _clean(sentenceTranslation);
    return [
      'You are a helpful language-learning tutor.',
      'The learner is studying $targetLanguage with $nativeLanguage support.',
      'Vocabulary: "$targetWord" means "$translation".',
      if (sentence != null)
        'Example sentence: "$sentence"${_translation(sentenceMeaning)}.',
      if (sentence != null) ...[
        'Earlier messages in this conversation may be about other example sentences of this vocabulary. "This sentence" means the one above.',
        'The latest question starts with a "$contextLabel" note. If it differs from earlier messages, the learner has moved on to that sentence: answer about it, not about an earlier one.',
      ],
      'Answer questions about this vocabulary and example sentence clearly. Explain nuances and usage when useful.',
      'Format your answer using Markdown.',
    ].join('\n');
  }

  /// The label of the note put in front of the latest question.
  static const contextLabel = 'Current example sentence';

  /// [history] for the AI, with the example sentence the learner is looking at
  /// put in front of the newest question. The saved conversation is not
  /// changed, so the learner still sees the question as they typed it.
  static List<AiDiscussionMessage> withCurrentSentence(
    List<AiDiscussionMessage> history, {
    String? sentenceTarget,
    String? sentenceTranslation,
  }) {
    final sentence = _clean(sentenceTarget);
    final latest = history.lastIndexWhere((m) => m.role == 'user');
    if (sentence == null || latest < 0) return history;
    final sentenceMeaning = _clean(sentenceTranslation);
    final note = '[$contextLabel: "$sentence"${_translation(sentenceMeaning)}]';
    final question = history[latest];
    return [
      ...history.take(latest),
      AiDiscussionMessage(
        role: question.role,
        content: '$note\n\n${question.content}',
        createdAt: question.createdAt,
      ),
      ...history.skip(latest + 1),
    ];
  }

  static String _translation(String? text) =>
      text == null ? '' : ' (translation: "$text")';

  static String? _clean(String? text) {
    final trimmed = text?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }
}
