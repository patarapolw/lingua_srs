import '../models/lesson.dart';

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
    ].join('\n\n');
  }

  static List<String> suggestedQuestions(bool hasMessages) => hasMessages
      ? [
          'Quiz me on this lesson.',
          'What are common mistakes with this grammar?',
        ]
      : [
          'Summarize this lesson.',
          'Explain the main grammar point simply.',
          'Give me practice sentences using this lesson.',
        ];
}
