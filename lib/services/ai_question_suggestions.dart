import 'dart:convert';

import '../models/ai_discussion_message.dart';

/// The questions the AI chats offer as buttons.
///
/// What is asked depends on the language being learned, so each language has
/// its own set of questions, and a language without one gets no word questions
/// and no AI suggestions. Korean is the only one the app supports. To add a
/// language, extend [_LanguageQuestions] and list it in [_languages].
///
/// After an answer, a few of the fixed questions are swapped for questions the
/// AI suggests from that answer, and the result never has more than
/// [maxQuestions].
class AiQuestionSuggestions {
  /// Most questions shown at once.
  static const maxQuestions = 4;

  /// Most questions taken from the AI. The rest are fixed ones.
  static const maxAiQuestions = 2;

  /// Most fixed questions shown at once. With the AI's suggestions in the
  /// list there is room for [maxQuestions] - their count.
  static const maxFixedQuestions = 3;

  /// Longest AI question that is shown, so that a chip stays a chip.
  static const maxAiQuestionLength = 120;

  static const Map<String, _LanguageQuestions> _languages = {
    'ko': _KoreanQuestions(),
  };

  /// Whether there are questions for [language], a code like `ko` (a region
  /// as in `ko-KR` and the English name are accepted too).
  static bool supports(String language) => _forLanguage(language) != null;

  /// Questions for a word chat that has no messages yet. Nothing is asked of
  /// the AI to show them. None for a language that is not [supports]ed.
  static List<String> wordFirstQuestions({
    required String language,
    required String word,
    required bool hasSentence,
    required bool verbOrAdjective,
  }) =>
      (_forLanguage(language)?.wordFirst(
                word: word,
                hasSentence: hasSentence,
                verbOrAdjective: verbOrAdjective,
              ) ??
              const <String>[])
          .take(maxQuestions)
          .toList();

  /// Questions for a word chat that has messages, most useful first. Those
  /// already asked are left out by [followUps]. None for a language that is
  /// not [supports]ed.
  static List<String> wordFollowUps({
    required String language,
    required String word,
    required bool hasSentence,
    required bool verbOrAdjective,
  }) =>
      _forLanguage(language)?.wordFollowUps(
        word: word,
        hasSentence: hasSentence,
        verbOrAdjective: verbOrAdjective,
      ) ??
      const [];

  /// What the AI is asked about when it suggests questions about a word.
  static String wordSubject({
    required String language,
    required String word,
    required String translation,
  }) {
    final name = _require(language).name;
    final meaning = translation.trim();
    return 'the $name word "$word"${meaning.isEmpty ? '' : ' ($meaning)'}';
  }

  /// What the AI is asked about when it suggests questions about a lesson.
  static String lessonSubject({
    required String language,
    required String title,
  }) => 'the ${_require(language).name} lesson "$title"';

  /// What to show after an answer: fixed questions that were not asked yet,
  /// then up to [maxAiQuestions] from [ai], at most [maxQuestions] together.
  /// The AI's questions come last, so that the others do not move when they
  /// arrive. Without any of them, up to [maxFixedQuestions] fixed ones are
  /// shown.
  static List<String> followUps({
    required List<String> hardcoded,
    required Iterable<String> asked,
    Iterable<String> ai = const [],
  }) {
    final askedKeys = {for (final question in asked) _key(question)};

    final fixed = <String>[];
    final fixedKeys = <String>{};
    for (final question in hardcoded) {
      final key = _key(question);
      if (askedKeys.contains(key) || !fixedKeys.add(key)) continue;
      fixed.add(question);
    }

    final suggested = <String>[];
    final suggestedKeys = <String>{};
    for (final question in ai) {
      final key = _key(question);
      if (key.isEmpty ||
          askedKeys.contains(key) ||
          fixedKeys.contains(key) ||
          !suggestedKeys.add(key)) {
        continue;
      }
      suggested.add(question);
      if (suggested.length == maxAiQuestions) break;
    }

    final room = maxQuestions - suggested.length;
    return [
      ...fixed.take(room < maxFixedQuestions ? room : maxFixedQuestions),
      ...suggested,
    ];
  }

  /// The request for the AI's questions. It only gets the last exchange, which
  /// keeps it small and cheap.
  static List<AiDiscussionMessage> aiRequest({
    required String language,
    required String subject,
    required String nativeLanguage,
    required String question,
    required String answer,
    required Iterable<String> asked,
    String? sentenceTarget,
    String? sentenceTranslation,
  }) {
    final questions = _require(language);
    final sentence = sentenceTarget?.trim();
    final sentenceMeaning = sentenceTranslation?.trim();
    final earlier = asked
        .map((q) => _clip(q, 120))
        .toList()
        .reversed
        .take(12)
        .toList()
        .reversed;
    return [
      AiDiscussionMessage(
        role: 'system',
        content: [
          'You suggest follow-up questions for a learner of ${questions.name}.',
          'Reply with JSON only: {"questions": ["...", "..."]}',
          'Suggest $maxAiQuestions short questions (under 12 words each) '
              'the learner would likely ask next about $subject.',
          questions.practicalFocus,
          'Write them in the learner\'s native language ($nativeLanguage), '
              'as the learner would type them.',
          'Each question must make sense on its own.',
          'Never repeat or reword a question that was already asked.',
        ].join('\n'),
      ),
      AiDiscussionMessage(
        role: 'user',
        content: [
          'Subject: $subject',
          if (sentence != null && sentence.isNotEmpty)
            'Example sentence on the card: "$sentence"'
                '${sentenceMeaning != null && sentenceMeaning.isNotEmpty ? ' (translation: "$sentenceMeaning")' : ''}',
          'Last question: ${_clip(question, 300)}',
          'Last answer (may be cut off): ${_clip(answer, 1500)}',
          if (earlier.isNotEmpty) ...[
            'Already asked:',
            for (final q in earlier) '- $q',
          ],
        ].join('\n'),
      ),
    ];
  }

  /// The questions in the AI's reply. Anything that is not the expected JSON
  /// gives none, so the fixed questions are shown alone.
  static List<String> parseAiQuestions(String? reply) {
    var text = reply?.trim() ?? '';
    final fenced = RegExp(r'^```(?:json)?\s*([\s\S]*?)\s*```$');
    if (fenced.firstMatch(text) case final match?) text = match.group(1)!;

    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      return const [];
    }
    final list = decoded is Map ? decoded['questions'] : decoded;
    if (list is! List) return const [];

    final questions = <String>[];
    final keys = <String>{};
    for (final item in list) {
      if (item is! String) continue;
      final question = item.trim();
      if (question.isEmpty || question.length > maxAiQuestionLength) continue;
      if (keys.add(_key(question))) questions.add(question);
    }
    return questions;
  }

  /// The questions for [language], or null if there are none.
  static _LanguageQuestions? _forLanguage(String language) {
    final code = language.trim().toLowerCase().split(RegExp(r'[-_]')).first;
    for (final entry in _languages.entries) {
      if (entry.key == code || entry.value.name.toLowerCase() == code) {
        return entry.value;
      }
    }
    return null;
  }

  static _LanguageQuestions _require(String language) =>
      _forLanguage(language) ??
      (throw ArgumentError.value(language, 'language', 'Not supported.'));

  /// Two questions that differ only in case, spacing or punctuation are the
  /// same question.
  static String _key(String question) => question.toLowerCase().replaceAll(
    RegExp(r'[^\p{L}\p{N}]+', unicode: true),
    '',
  );

  static String _clip(String text, int length) {
    final trimmed = text.trim();
    return trimmed.length <= length
        ? trimmed
        : '${trimmed.substring(0, length)}…';
  }
}

/// The questions asked about the words of one language.
abstract class _LanguageQuestions {
  const _LanguageQuestions();

  /// The English name of the language.
  String get name;

  /// A line telling the AI what kind of follow-up questions are the most
  /// useful to a learner of this language.
  String get practicalFocus;

  /// For a chat with no messages. [AiQuestionSuggestions.maxQuestions] of them
  /// are shown, from the first.
  List<String> wordFirst({
    required String word,
    required bool hasSentence,
    required bool verbOrAdjective,
  });

  /// For a chat with messages, most useful first.
  List<String> wordFollowUps({
    required String word,
    required bool hasSentence,
    required bool verbOrAdjective,
  });
}

class _KoreanQuestions extends _LanguageQuestions {
  const _KoreanQuestions();

  @override
  String get name => 'Korean';

  @override
  String get practicalFocus =>
      'Favor practical use: real sentences, how it sounds, '
      'how Koreans actually say it.';

  @override
  List<String> wordFirst({
    required String word,
    required bool hasSentence,
    required bool verbOrAdjective,
  }) => [
    'Is "$word" Sino-Korean (Hanja) or native Korean? '
        'Explain where it comes from.',
    if (hasSentence)
      'How does this sentence work? Break down the grammar and particles.',
    'How is "$word" used in everyday speech? '
        'What formality and politeness (speech levels) does it suit?',
    if (verbOrAdjective) _conjugation(word),
    'Give me another example sentence with "$word".',
  ];

  @override
  List<String> wordFollowUps({
    required String word,
    required bool hasSentence,
    required bool verbOrAdjective,
  }) => [
    if (hasSentence)
      'What speech level is this sentence in (formality and politeness)? '
          'Show it in the other common levels.',
    'How is "$word" pronounced? Which sound rules affect it in speech?',
    'Quiz me on "$word" with 3 short questions.',
    if (hasSentence) 'What other useful expressions are in this sentence?',
    if (verbOrAdjective) _conjugation(word),
    'How is "$word" different from similar words?',
    'Give me another example sentence with "$word".',
  ];

  /// Asks for the forms the learner will meet, in sentences, not a table.
  static String _conjugation(String word) =>
      'Show me sentences with how "$word" commonly conjugates.';
}
