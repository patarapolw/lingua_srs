/// Which kind of AI chat a question was typed in. A question typed in a word
/// chat is only offered in word chats, and one typed in a lesson chat only in
/// lesson chats: what is asked about a lesson rarely fits a word.
enum TypedQuestionScope {
  word,
  lesson;

  /// Stands for the word or the lesson title in [TypedQuestion.template].
  String get placeholder => '{$name}';
}

/// A question the learner typed in an AI chat, kept to be offered again.
///
/// The word or lesson the chat was about is replaced by its scope's
/// placeholder, so the question can be offered for any word or lesson. See
/// `TypedQuestions` for how questions are kept and chosen.
class TypedQuestion {
  const TypedQuestion({
    required this.language,
    required this.scope,
    required this.template,
    required this.uses,
    required this.lastUsed,
  });

  /// The language being learned, as a code such as `ko`.
  final String language;
  final TypedQuestionScope scope;

  /// The question, with the word or lesson title as [scope]'s placeholder.
  final String template;

  /// How many times it was sent.
  final int uses;
  final DateTime lastUsed;

  /// The question about [subject]: the word or lesson title of the chat it is
  /// offered in.
  String forSubject(String subject) =>
      template.replaceAll(scope.placeholder, subject);

  TypedQuestion copyWith({String? template, int? uses, DateTime? lastUsed}) =>
      TypedQuestion(
        language: language,
        scope: scope,
        template: template ?? this.template,
        uses: uses ?? this.uses,
        lastUsed: lastUsed ?? this.lastUsed,
      );

  Map<String, dynamic> toJson() => {
    'language': language,
    'scope': scope.name,
    'template': template,
    'uses': uses,
    'lastUsed': lastUsed.toUtc().toIso8601String(),
  };

  factory TypedQuestion.fromJson(Map<String, dynamic> json) {
    final language = json['language'];
    final scope = json['scope'];
    final template = json['template'];
    final uses = json['uses'];
    final lastUsed = json['lastUsed'];
    final parsedScope = TypedQuestionScope.values
        .where((value) => value.name == scope)
        .firstOrNull;
    final parsedLastUsed = lastUsed is String
        ? DateTime.tryParse(lastUsed)
        : null;
    if (language is! String ||
        language.isEmpty ||
        parsedScope == null ||
        template is! String ||
        template.trim().isEmpty ||
        uses is! int ||
        uses < 1 ||
        parsedLastUsed == null) {
      throw const FormatException('Invalid typed question.');
    }
    return TypedQuestion(
      language: language,
      scope: parsedScope,
      template: template,
      uses: uses,
      lastUsed: parsedLastUsed,
    );
  }
}
