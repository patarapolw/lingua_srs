import '../models/lesson.dart';
import '../models/sentence.dart';
import 'yaml_parser_service.dart';

/// Builds AI discussion ids, prompts and suggestions for whole lessons.
class LessonAiPrompt {
  static const idPrefix = 'lesson:';
  // ~48k chars stays well inside deepseek-chat's context even for Korean-heavy
  // text; shorter caps made the AI miss patterns in long lessons.
  static const maxMarkdownChars = 48000;
  static const maxVocabulary = 150;

  static String discussionId(String lessonId) => '$idPrefix$lessonId';

  static bool isLessonDiscussion(String id) => id.startsWith(idPrefix);

  static String lessonIdFrom(String id) => id.substring(idPrefix.length);

  /// Cuts [markdown] to at most [maxChars] at a line break, and says what was
  /// left out (including the omitted headings) so the AI can tell the learner.
  static String clipMarkdown(
    String markdown, {
    int maxChars = maxMarkdownChars,
  }) {
    final text = markdown.trim();
    if (text.length <= maxChars) return text;
    var cut = text.lastIndexOf('\n', maxChars);
    if (cut < maxChars ~/ 2) cut = maxChars;
    final omitted = text.substring(cut);
    final headings = RegExp(
      r'^#{1,6}\s+(.+)$',
      multiLine: true,
    ).allMatches(omitted).map((m) => m[1]!.trim()).toList();
    return [
      text.substring(0, cut).trimRight(),
      '[The rest of the lesson (${omitted.length} characters) is omitted here because it is too long.]',
      if (headings.isNotEmpty) 'Omitted sections: ${headings.join(' | ')}',
    ].join('\n\n');
  }

  static String systemPrompt(Lesson lesson) {
    final body = clipMarkdown(lesson.markdownContent);
    final vocabulary = lesson.vocabularies
        .take(maxVocabulary)
        .map((v) => '- ${v.targetWord} — ${v.translation}');
    return [
      'You are a helpful language-learning tutor.',
      'The learner is studying ${lesson.targetLanguage} with ${lesson.nativeLanguage} support.',
      'They are reading the lesson "${lesson.displayTitle}". Answer using the lesson content below, and say so when the lesson does not cover something.',
      if (body.isNotEmpty) 'Lesson content:\n"""\n$body\n"""',
      if (vocabulary.isNotEmpty) 'Lesson vocabulary:\n${vocabulary.join('\n')}',
      'Format your answer using Markdown.',
      vocabularyYamlInstructions(lesson),
    ].join('\n\n');
  }

  /// The fixed question that asks for words to add to the lesson. The system
  /// prompt has the AI answer it, and any other request for words to learn,
  /// with YAML the learner can edit before adding it.
  static const vocabularyQuestion = 'List more vocabulary for this lesson.';

  /// How the AI writes vocabulary to add to [lesson], so that the reply opens
  /// in the import screen as it is (see docs/lesson-format.md).
  static String vocabularyYamlInstructions(Lesson lesson) {
    // Entries are keyed by the language alone: `zh`, not `zh-TW`.
    final target = lesson.targetLanguageCode;
    final native = lesson.nativeLanguage;
    final extra = switch (target) {
      'zh' => (
        'Give every word its `pinyin` with tone marks, written in the '
            '${_chineseScript(lesson.targetLanguage)} characters the lesson '
            'uses. ',
        '      pinyin: "..."\n',
      ),
      'ko' => (
        'Give a Sino-Korean word its `hanja`, and leave `hanja` out for a '
            'native Korean word. ',
        '      hanja: "..."\n',
      ),
      _ => ('', ''),
    };
    return [
      'Whenever you give the learner words to learn (they ask for more '
          'vocabulary, a word list, words on a topic, or words to add to '
          'this lesson), suggest words that fit the lesson and are not in '
          'its vocabulary yet, each once. Besides any explanation, put them '
          'in one ```yaml code block in this format, with '
          'part-of-speech keys (such as nouns, verbs, adjectives, adverbs, '
          'expressions) directly under `vocabulary:`. Verbs and adjectives '
          'are in their dictionary form. `notes` and `examples` are '
          'optional. ${extra.$1}In every example, the word being learned must be '
          'wrapped in **bold** in the $target sentence. In the $native '
          'translation, also wrap in **bold** the words that translate it; '
          'if no words in the translation match it (it is left out or '
          'reworded), leave the translation without bold. Quote every value.',
      '```yaml\n'
          'vocabulary:\n'
          '  nouns:\n'
          '    - $target: "..."\n'
          '${extra.$2}'
          '      $native: "..."\n'
          '      notes: "..."\n'
          '      examples:\n'
          '        - $target: "... **...** ..."\n'
          '          $native: "... **...** ..."\n'
          '```',
      'The learner can edit the list before adding it to the lesson.',
    ].join('\n');
  }

  /// Which characters a Chinese lesson is written in, from its language tag:
  /// traditional for Taiwan, Hong Kong, Macau and `Hant`, else simplified.
  static String _chineseScript(String language) {
    final parts = language.toLowerCase().split(RegExp(r'[-_]')).skip(1);
    return parts.any(const {'tw', 'hk', 'mo', 'hant'}.contains)
        ? 'traditional'
        : 'simplified';
  }

  /// The vocabulary YAML in an AI [answer]: the first fenced code block whose
  /// root is `vocabulary:`, or null if there is none. It is not checked here;
  /// the import screen parses it and shows any errors.
  static String? vocabularyYaml(String answer) {
    final fence = RegExp(
      r'^[ \t]*```[ \t]*([A-Za-z]*)[ \t]*\r?\n([\s\S]*?)^[ \t]*```',
      multiLine: true,
    );
    for (final match in fence.allMatches(answer)) {
      final language = match.group(1)!.toLowerCase();
      if (language.isNotEmpty && language != 'yaml' && language != 'yml') {
        continue;
      }
      final body = match.group(2)!.trimRight();
      if (RegExp(r'^vocabulary:', multiLine: true).hasMatch(body)) {
        return '$body\n';
      }
    }
    return null;
  }

  /// The note added to a word an AI suggested, when it is imported.
  static const aiWordNote =
      '*Suggested by AI: check this word, its meaning and its examples '
      'before relying on them.*';

  /// The note added to an example sentence an AI suggested, when it is
  /// imported.
  static const aiSentenceNote =
      '*Suggested by AI: check this sentence and its translation before '
      'relying on them.*';

  /// Adds [aiWordNote] to the notes of every word in [parsed], vocabulary an
  /// AI suggested, and [aiSentenceNote] to those of every example sentence
  /// that [isNew] says is not in the Sentence Pool yet. A sentence already in
  /// the pool is the learner's own, so it is left as it is. Each note goes
  /// after any notes there are, as a paragraph of its own, and is not added
  /// twice.
  static void addAiNotes(
    YamlParseResult parsed, {
    required bool Function(Sentence sentence) isNew,
  }) {
    for (final vocab in parsed.lesson.vocabularies) {
      vocab.notes = _withNote(vocab.notes, aiWordNote);
    }
    for (final sentence in parsed.sentences) {
      if (isNew(sentence)) {
        sentence.notes = _withNote(sentence.notes, aiSentenceNote);
      }
    }
  }

  static String _withNote(String notes, String note) {
    final text = notes.trim();
    if (text.contains(note)) return notes;
    return text.isEmpty ? note : '$text\n\n$note';
  }

  static List<String> suggestedQuestions(bool hasMessages) => hasMessages
      ? [
          'Quiz me on this lesson.',
          vocabularyQuestion,
          'What are common mistakes with this grammar?',
        ]
      : [
          'Summarize this lesson.',
          'Explain the main grammar point simply.',
          vocabularyQuestion,
          'Give me practice sentences using this lesson.',
        ];
}

/// System prompts for continuing a chat whose lesson or word is gone. The saved
/// conversation is then all the AI has to go on, and it is told so, so that it
/// asks for the text instead of guessing at it.
class OrphanedAiPrompt {
  static String forLesson({
    required String targetLanguage,
    required String nativeLanguage,
  }) => _build(targetLanguage, nativeLanguage, 'lesson', 'text or vocabulary');

  static String forWord({
    required String targetLanguage,
    required String nativeLanguage,
  }) => _build(targetLanguage, nativeLanguage, 'vocabulary word', 'meaning');

  static String _build(
    String targetLanguage,
    String nativeLanguage,
    String what,
    String detail,
  ) => [
    'You are a helpful language-learning tutor.',
    'The learner is studying $targetLanguage with $nativeLanguage support.',
    'This conversation was about a $what that is no longer available, so you cannot see its $detail.',
    'Continue from the conversation so far. If you need the $what itself to answer, say so instead of guessing.',
    'Format your answer using Markdown.',
  ].join('\n');
}
