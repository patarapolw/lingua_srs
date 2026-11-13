import '../models/ai_discussion_message.dart';
import '../models/lesson.dart';
import 'lesson_ai_prompt.dart';
import 'yaml_parser_service.dart';

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
      examplesYamlInstructions(
        targetLanguage: targetLanguage,
        nativeLanguage: nativeLanguage,
        targetWord: targetWord,
      ),
    ].join('\n');
  }

  /// How the AI writes example sentences for the word, so that an answer can
  /// add them to the word ([examplesYaml]). The keys are ones the lesson
  /// format reads as a sentence and its translation.
  static String examplesYamlInstructions({
    required String targetLanguage,
    required String nativeLanguage,
    required String targetWord,
  }) {
    final (target, native) = exampleKeys(
      targetLanguage: targetLanguage,
      nativeLanguage: nativeLanguage,
    );
    return [
      'Whenever you give the learner new example sentences for "$targetWord" '
          '(they ask for more examples, other ways to use it, or sentences to '
          'practise with), besides any explanation put them in one ```yaml '
          'code block in this format. Write each sentence the way the word '
          'is written here, and do not repeat the example sentence above. In '
          'every sentence, wrap the word (in the form it takes there) in '
          '**bold**. In the translation, also wrap in **bold** the words that '
          'translate it; if no words in the translation match it, leave the '
          'translation without bold. `notes` is optional. Quote every value.',
      '```yaml\n'
          'examples:\n'
          '  - $target: "... **...** ..."\n'
          '    $native: "... **...** ..."\n'
          '    notes: "..."\n'
          '```',
      'The learner can choose which of them to add to the word.',
    ].join('\n');
  }

  /// The YAML keys of a sentence and its translation for these languages:
  /// their codes when the lesson format knows them, else `target` and
  /// `translation`.
  static (String, String) exampleKeys({
    required String targetLanguage,
    required String nativeLanguage,
  }) {
    const generic = {'target', 'term', 'word'};
    final target = Lesson.languageCodeOf(targetLanguage);
    final native = Lesson.languageCodeOf(nativeLanguage);
    return (
      YamlParserService.knownLangKeys.contains(target) &&
              !generic.contains(target)
          ? target
          : 'target',
      YamlParserService.knownNativeKeys.contains(native)
          ? native
          : 'translation',
    );
  }

  /// The example sentences in an AI [answer]: those of the first fenced code
  /// block whose root is `examples:`. Empty if there is none, or if it cannot
  /// be read.
  static List<ExampleSentence> examplesYaml(String answer) {
    final yaml = LessonAiPrompt.yamlBlock(answer, root: 'examples');
    if (yaml == null) return const [];
    try {
      return YamlParserService.parseExampleSentences(yaml);
    } on FormatException {
      return const [];
    }
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
