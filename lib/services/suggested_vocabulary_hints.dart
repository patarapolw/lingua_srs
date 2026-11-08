import '../models/vocab_item.dart';
import 'ai_question_suggestions.dart';
import 'yaml_parser_service.dart';

/// A suggested word the learner may want to edit out before adding it, and
/// the word they already have that makes it so.
typedef SuggestedVocabularyHint = ({String word, String known});

/// Words in vocabulary an AI suggested that are not the same as a word the
/// learner has, so they are not left out, but are close enough that the
/// learner may not want them. They are only pointed out.
class SuggestedVocabularyHints {
  /// The hints for [entries], the kept entries of suggested vocabulary in
  /// [language], given [known], the keys
  /// ([YamlParserService.vocabularyKey]) of the words the learner has.
  ///
  /// Korean: a noun whose 하다 verb is known, such as 공부 when 공부하다 is in
  /// a lesson, since the verb already teaches the noun. An entry listed under
  /// verbs or adjectives, or ending in 다, is not a noun. Other languages have
  /// no hints.
  static List<SuggestedVocabularyHint> forEntries({
    required String language,
    required Iterable<({String word, String section})> entries,
    required Set<String> known,
  }) {
    if (AiQuestionSuggestions.languageCode(language) != 'ko') return const [];
    final hints = <SuggestedVocabularyHint>[];
    final seen = <String>{};
    for (final entry in entries) {
      final word = entry.word.trim();
      if (word.isEmpty ||
          word.endsWith('다') ||
          VocabItem.isVerbOrAdjective(entry.section)) {
        continue;
      }
      final verb = '$word하다';
      if (known.contains(YamlParserService.vocabularyKey(verb)) &&
          seen.add(word)) {
        hints.add((word: word, known: verb));
      }
    }
    return hints;
  }
}
