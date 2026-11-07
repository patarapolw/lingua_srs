import '../models/typed_question.dart';
import 'ai_question_suggestions.dart';

/// Questions the learner typed in AI chats, kept so they can be offered again
/// as buttons next to the fixed and AI-suggested ones.
///
/// A question is kept with the word or lesson title it names replaced by a
/// placeholder, so "How is 먹다 used in polite speech?" is offered for every
/// word. A question that still names something in the language being learned,
/// or quotes something, is about that one card and is not kept. Two questions
/// that differ only in case, spacing or punctuation are one question.
abstract final class TypedQuestions {
  /// Longest question that is kept. Longer ones are rarely asked again, and
  /// would make a large button.
  static const maxLength = 120;

  /// Most questions kept per language and chat kind. When there are more,
  /// the ones used longest ago are dropped.
  static const maxKept = 100;

  /// The id of [question]: its language, chat kind and normalized text. A
  /// question used again has the same id, so it is counted, not added again.
  static String id(TypedQuestion question) =>
      idFor(question.language, question.scope, question.template);

  static String idFor(
    String language,
    TypedQuestionScope scope,
    String template,
  ) => [
    AiQuestionSuggestions.languageCode(language),
    scope.name,
    // The placeholder is kept apart from the words around it, so a question
    // that types the placeholder's name is not the same question.
    template
        .split(scope.placeholder)
        .map(AiQuestionSuggestions.questionKey)
        .join('{}'),
  ].join(':');

  /// [question] as asked about [subject] (the word, or the lesson title), with
  /// [subject] replaced by the placeholder of [scope]. Null when it is not
  /// kept: when it is empty, long or several lines, or still names or quotes
  /// something only one card has.
  static String? template({
    required String question,
    required String subject,
    required String language,
    required TypedQuestionScope scope,
  }) {
    final text = question.trim().replaceAll(RegExp(r'[ \t]+'), ' ');
    if (text.isEmpty || text.length > maxLength || text.contains('\n')) {
      return null;
    }
    final name = subject.trim();
    final template = name.isEmpty
        ? text
        : text.replaceAll(
            RegExp(RegExp.escape(name), caseSensitive: false),
            scope.placeholder,
          );
    // What is left once the word, with any quotes around it, is taken out.
    final rest = template.replaceAll(
      RegExp('["“「『«]?${RegExp.escape(scope.placeholder)}["”」』»]?'),
      '',
    );
    if (AiQuestionSuggestions.questionKey(rest).isEmpty) return null;
    if (AiQuestionSuggestions.hasTargetText(language: language, text: rest)) {
      return null;
    }
    if (_quoted.hasMatch(rest)) return null;
    return template;
  }

  /// Text in quotes, such as a phrase from the example sentence.
  static final _quoted = RegExp(r'"[^"]+"|“[^”]+”|「[^」]+」|『[^』]+』|«[^»]+»');

  /// [kept] with [question], asked about [subject], used once more at [now].
  /// [kept] is returned unchanged when the question is not kept (see
  /// [template]).
  static Map<String, TypedQuestion> recordUse(
    Map<String, TypedQuestion> kept, {
    required String question,
    required String subject,
    required String language,
    required TypedQuestionScope scope,
    required DateTime now,
  }) {
    final text = template(
      question: question,
      subject: subject,
      language: language,
      scope: scope,
    );
    if (text == null) return kept;
    final code = AiQuestionSuggestions.languageCode(language);
    final key = idFor(code, scope, text);
    final existing = kept[key];
    final next = {
      ...kept,
      key:
          existing?.copyWith(
            template: text,
            uses: existing.uses + 1,
            lastUsed: now,
          ) ??
          TypedQuestion(
            language: code,
            scope: scope,
            template: text,
            uses: 1,
            lastUsed: now,
          ),
    };
    return _prune(next, code, scope);
  }

  /// Drops the questions of [language] and [scope] used longest ago, past
  /// [maxKept].
  static Map<String, TypedQuestion> _prune(
    Map<String, TypedQuestion> kept,
    String language,
    TypedQuestionScope scope,
  ) {
    final same = [
      for (final entry in kept.entries)
        if (entry.value.language == language && entry.value.scope == scope)
          entry,
    ];
    if (same.length <= maxKept) return kept;
    same.sort((a, b) => b.value.lastUsed.compareTo(a.value.lastUsed));
    final dropped = {for (final entry in same.skip(maxKept)) entry.key};
    return {
      for (final entry in kept.entries)
        if (!dropped.contains(entry.key)) entry.key: entry.value,
    };
  }

  /// Up to [max] questions to offer in a chat about [subject], taken in turn
  /// from the most used and the most recently used. Questions whose text is
  /// in [leaveOut] (asked already in this chat, say) are not offered. Each
  /// comes with its id, so it can be removed.
  static List<({String id, String question})> offer(
    Map<String, TypedQuestion> kept, {
    required String language,
    required TypedQuestionScope scope,
    required String subject,
    Iterable<String> leaveOut = const [],
    int max = AiQuestionSuggestions.maxTypedQuestions,
  }) {
    final code = AiQuestionSuggestions.languageCode(language);
    final leaveOutKeys = {
      for (final question in leaveOut)
        AiQuestionSuggestions.questionKey(question),
    };
    final candidates = [
      for (final entry in kept.entries)
        if (entry.value.language == code && entry.value.scope == scope)
          (
            id: entry.key,
            item: entry.value,
            question: entry.value.forSubject(subject),
          ),
    ];
    candidates.removeWhere(
      (candidate) => leaveOutKeys.contains(
        AiQuestionSuggestions.questionKey(candidate.question),
      ),
    );
    final mostUsed = [...candidates]
      ..sort((a, b) {
        final byUses = b.item.uses.compareTo(a.item.uses);
        return byUses != 0
            ? byUses
            : b.item.lastUsed.compareTo(a.item.lastUsed);
      });
    final mostRecent = [...candidates]
      ..sort((a, b) => b.item.lastUsed.compareTo(a.item.lastUsed));

    // Both lists hold the same questions, so they run out together.
    final offered = <({String id, String question})>[];
    final keys = <String>{};
    final chosen = <String>{};
    while (offered.length < max) {
      final list = offered.length.isEven ? mostUsed : mostRecent;
      final next = list.where((c) => !chosen.contains(c.id)).firstOrNull;
      if (next == null) break;
      chosen.add(next.id);
      // Two kept questions can read the same once the subject is put in.
      if (keys.add(AiQuestionSuggestions.questionKey(next.question))) {
        offered.add((id: next.id, question: next.question));
      }
    }
    return offered;
  }
}
