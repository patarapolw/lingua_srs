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

  /// What the AI is told to keep its questions to, so that a chip stays short.
  static const maxAiQuestionWords = 8;

  /// Longest AI question that is shown, in case it did not keep to that.
  static const maxAiQuestionLength = 80;

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

  /// What the AI is asked about when it suggests questions about a word. A verb
  /// or adjective is on the card in its dictionary form, and the AI is told.
  static String wordSubject({
    required String language,
    required String word,
    required String translation,
    bool verbOrAdjective = false,
  }) {
    final name = _require(language).name;
    final meaning = translation.trim();
    final kind = verbOrAdjective ? 'verb or adjective' : 'word';
    return 'the $name $kind "$word"'
        '${meaning.isEmpty ? '' : ' ($meaning)'}'
        '${verbOrAdjective ? ', given in its dictionary form' : ''}';
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
    Iterable<String> shown = const [],
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
          'Suggest $maxAiQuestions questions the learner would likely ask '
              'next about $subject.',
          'Each is one short question of at most $maxAiQuestionWords words '
              '(about 50 characters).',
          questions.practicalFocus,
          'Write them in the learner\'s native language ($nativeLanguage), '
              'as the learner would type them.',
          'Each question must make sense on its own. '
              'Say "this sentence" only if an example sentence is given.',
          'Never repeat or reword a question that was already asked '
              'or is already on screen.',
          'Examples of the style, not to be copied: '
              '${questions.exampleQuestions.map((q) => '"$q"').join(', ')}',
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
          if (shown.isNotEmpty) ...[
            'Already on screen:',
            for (final q in shown) '- ${_clip(q, 120)}',
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

  /// A few short questions that show the AI the style that is wanted.
  List<String> get exampleQuestions;

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
      'how Koreans actually say it. '
      'A noun has a register (casual, neutral, formal, honorific words), not '
      'speech levels. A verb or adjective takes speech-level endings, and its '
      'dictionary form has none.';

  @override
  List<String> get exampleQuestions => const [
    'How do I say this politely?',
    'What are common mistakes with this word?',
    'Show me a short dialogue using it.',
  ];

  // A verb or adjective is on the card in its dictionary form, so what is
  // asked about it is its forms, and speech levels show in the endings. A noun
  // has no endings, so it is asked about its register instead. A sentence has
  // a speech level whatever the word is.

  @override
  List<String> wordFirst({
    required String word,
    required bool hasSentence,
    required bool verbOrAdjective,
  }) => [
    _origin(word),
    if (hasSentence) _sentenceGrammar,
    if (verbOrAdjective) _irregular(word) else _register(word),
    if (verbOrAdjective) _conjugation(word),
    if (verbOrAdjective) _speechLevels(word),
    if (hasSentence) _sentenceSpeechLevel,
    _anotherExample(word),
  ];

  @override
  List<String> wordFollowUps({
    required String word,
    required bool hasSentence,
    required bool verbOrAdjective,
  }) => [
    if (hasSentence) _sentenceSpeechLevel,
    if (verbOrAdjective) _irregular(word),
    if (verbOrAdjective) _conjugation(word),
    verbOrAdjective ? _conjugatedSounds(word) : _pronunciation(word),
    if (verbOrAdjective) _speechLevels(word) else _register(word),
    verbOrAdjective ? _quizInSentences(word) : _quiz(word),
    if (hasSentence) _sentenceExpressions,
    _similarWords(word),
    _anotherExample(word),
  ];

  static String _origin(String word) =>
      'Is "$word" Sino-Korean (Hanja) or native Korean?';

  static const _sentenceGrammar =
      "Break down this sentence's grammar and particles.";

  static const _sentenceSpeechLevel =
      'What speech level is this sentence in? Show the other levels.';

  static const _sentenceExpressions =
      'Other useful expressions in this sentence?';

  static String _register(String word) =>
      'What register is "$word"? Is there a more polite word for it?';

  static String _speechLevels(String word) =>
      'Show "$word" in the different speech levels.';

  static String _irregular(String word) =>
      'Is "$word" irregular? If so, how does it change?';

  /// Asks for the forms the learner will meet, in sentences, not a table.
  static String _conjugation(String word) =>
      'Show me sentences with how "$word" commonly conjugates.';

  static String _pronunciation(String word) =>
      'How is "$word" pronounced? Which sound rules apply?';

  static String _conjugatedSounds(String word) =>
      'Which sound rules affect "$word" when it conjugates?';

  static String _quiz(String word) =>
      'Quiz me on "$word" with 3 short questions.';

  static String _quizInSentences(String word) =>
      'Quiz me on "$word" in sentences, 3 questions.';

  static String _similarWords(String word) =>
      'How is "$word" different from similar words?';

  static String _anotherExample(String word) =>
      'Give me another example sentence with "$word".';
}
