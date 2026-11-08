import 'ai_question_suggestions.dart';
import 'yaml_parser_service.dart';

/// A suggested word the learner may want to edit out before adding it, and
/// the other form of it that makes it so.
typedef SuggestedVocabularyHint = ({
  String word,
  String other,

  /// Whether [other] is earlier in the same suggested list, rather than a word
  /// the learner has.
  bool inList,
});

/// Words in vocabulary an AI suggested that are another form of a word the
/// learner has, or of an earlier word in the same list. They are not left
/// out, only pointed out, since they can still be worth a card.
///
/// Only Korean has such forms here. Words are compared by how they are
/// written, ignoring spaces (공부 하다 is 공부하다). Nothing else is taken as
/// the same: translations are not reliable enough to go by, and words written
/// alike but for punctuation or a note in parentheses can be different words
/// that sound or are spelled alike.
///
/// Two words are forms of each other when they share a root, where the root
/// is the word itself (a noun) or what is left without one of
/// [_koreanSuffixes]:
/// - 하다, 되다, 시키다: 공부 ↔ 공부하다 ↔ 공부되다 ↔ 공부시키다
/// - 스럽다, 롭다, 답다: 자연 ↔ 자연스럽다, 자유 ↔ 자유롭다
/// - 있다, 없다: 맛 ↔ 맛있다 ↔ 맛없다
/// - 적 and the adverb 히, after a root of 2 syllables or more: 경제 ↔
///   경제적, 조용하다 ↔ 조용히
/// - the adverb 이 only against 하다, as 깨끗이 ↔ 깨끗하다; against a noun it
///   would take 오이 for a form of 오.
///
/// A suffix is only taken off a word longer than it, so 하다 and 되다 have
/// no root. Endings that are too often part of an unrelated word are left
/// out: -기 (감기 is not a form of 감다), -게 (가게 is not 가다), and -이
/// after a verb (나이 is not 나다).
class SuggestedVocabularyHints {
  static const _koreanSuffixes = [
    '시키다',
    '스럽다',
    '하다',
    '되다',
    '롭다',
    '답다',
    '있다',
    '없다',
  ];

  /// Endings that make an adverb or adjective from a root of at least
  /// 2 syllables, and match any other form of that root.
  static const _koreanLongRootEndings = ['적', '히'];

  /// The hints for [entries], the kept entries of suggested vocabulary in
  /// [language], against [known], the words the learner has. At most one hint
  /// per suggested word, naming a word the learner has before one earlier in
  /// the list. None for a language other than Korean.
  static List<SuggestedVocabularyHint> forEntries({
    required String language,
    required Iterable<KeptVocabularyEntry> entries,
    required Iterable<String> known,
  }) {
    if (AiQuestionSuggestions.languageCode(language) != 'ko') return const [];
    final roots = <String, List<({_Word word, String suffix})>>{};
    void add(String word, {required bool inList}) {
      final entry = (word: word.trim(), inList: inList);
      for (final (root, suffix) in _koreanRoots(_compact(word))) {
        (roots[root] ??= []).add((word: entry, suffix: suffix));
      }
    }

    for (final word in known) {
      add(word, inList: false);
    }

    final hints = <SuggestedVocabularyHint>[];
    final hinted = <String>{};
    for (final entry in entries) {
      final word = entry.word.trim();
      final compact = _compact(word);
      if (compact.isEmpty) continue;
      _Word? form;
      for (final (root, suffix) in _koreanRoots(compact)) {
        for (final candidate in roots[root] ?? const []) {
          if (_compact(candidate.word.word) == compact ||
              !_formsOfEachOther(suffix, candidate.suffix)) {
            continue;
          }
          // A word the learner has beats one earlier in the list.
          if (form == null || (form.inList && !candidate.word.inList)) {
            form = candidate.word;
          }
        }
      }
      if (form != null && hinted.add(YamlParserService.vocabularyKey(word))) {
        hints.add((word: word, other: form.word, inList: form.inList));
      }
      add(word, inList: true);
    }
    return hints;
  }

  /// [hints] as one line: "공부 (you have 공부하다), 조용히 (also listed:
  /// 조용하다)".
  static String summary(Iterable<SuggestedVocabularyHint> hints) =>
      hints.map((hint) => '${hint.word} (${describe(hint)})').join(', ');

  /// What a hint says after its word, such as "you have 공부하다".
  static String describe(SuggestedVocabularyHint hint) =>
      hint.inList ? 'also listed: ${hint.other}' : 'you have ${hint.other}';

  /// [word] without spaces: 공부 하다 is 공부하다.
  static String _compact(String word) => word.replaceAll(RegExp(r'\s+'), '');

  /// The roots of a compact Korean [word], each with what it was taken from:
  /// the word itself (''), or the suffix or ending taken off.
  static Iterable<(String root, String suffix)> _koreanRoots(
    String word,
  ) sync* {
    if (word.isEmpty) return;
    yield (word, '');
    for (final suffix in _koreanSuffixes) {
      if (word.length > suffix.length && word.endsWith(suffix)) {
        yield (word.substring(0, word.length - suffix.length), suffix);
      }
    }
    if (word.length >= 3) {
      final root = word.substring(0, word.length - 1);
      final ending = word.substring(word.length - 1);
      if (_koreanLongRootEndings.contains(ending) || ending == '이') {
        yield (root, ending);
      }
    }
  }

  /// Whether two different words that share a root, taken off as [a] and
  /// [b], are forms of each other.
  static bool _formsOfEachOther(String a, String b) {
    if (a == b) return false; // Two words of one kind, such as two nouns.
    if (a == '이') return b == '하다';
    if (b == '이') return a == '하다';
    return true;
  }
}

typedef _Word = ({String word, bool inList});
