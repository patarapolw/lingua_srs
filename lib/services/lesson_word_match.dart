import '../models/vocab_item.dart';

/// How a word of a lesson file was found among the words of its saved lesson.
enum WordMatchKind {
  /// The same `id`, written in the file or made from the word and its
  /// translation.
  id,

  /// The same word and translation.
  meaning,

  /// The word and translation the file had when it was last imported
  /// ([VocabItem.source]): the word was edited in the app since.
  source,

  /// The same word with another translation, or the same translation with
  /// a typo fixed in the word, and nothing else in the lesson could be
  /// meant: the entry was edited in the file.
  edited,
}

class WordMatch {
  final VocabItem word;
  final WordMatchKind kind;

  const WordMatch(this.word, this.kind);
}

/// Pairs the words of a lesson file with the words of the lesson saved from
/// it, for importing the file again and for writing the app's words back to
/// it.
class LessonWordMatch {
  /// The saved word each of [fileWords] is, for those that have one. A saved
  /// word is given to one file word at most.
  ///
  /// With [edits], an entry whose word or translation was corrected in the
  /// file is paired with the saved word it used to be
  /// ([WordMatchKind.edited]). That is only safe to ask of a file that is
  /// being imported: it is a guess about what changed in the file.
  static Map<VocabItem, WordMatch> match(
    List<VocabItem> fileWords,
    List<VocabItem> lessonWords, {
    bool edits = false,
  }) {
    final matches = Map<VocabItem, WordMatch>.identity();
    final taken = Set<VocabItem>.identity();
    Iterable<VocabItem> free() =>
        lessonWords.where((word) => !taken.contains(word));
    Iterable<VocabItem> unmatched() =>
        fileWords.where((word) => !matches.containsKey(word));
    void pair(VocabItem fileWord, VocabItem word, WordMatchKind kind) {
      matches[fileWord] = WordMatch(word, kind);
      taken.add(word);
    }

    for (final fileWord in unmatched().toList()) {
      final sameId = free().where((word) => word.id == fileWord.id).toList();
      if (sameId.isEmpty) continue;
      pair(
        fileWord,
        sameId.firstWhere(
          (word) => _sameSection(word, fileWord),
          orElse: () => sameId.first,
        ),
        WordMatchKind.id,
      );
    }

    // An `id` written in the file says the entry is not the word that merely
    // reads the same.
    for (final fileWord in unmatched().toList()) {
      if (fileWord.idIsExplicit) continue;
      final meaning = _meaning(fileWord.targetWord, fileWord.translation);
      for (final word in free()) {
        if (_meaning(word.targetWord, word.translation) != meaning) continue;
        pair(fileWord, word, WordMatchKind.meaning);
        break;
      }
    }

    // A saved word another entry of the file still names by id is that
    // entry's, whatever order the file lists them in.
    final fileIds = {for (final word in fileWords) word.id};
    for (final fileWord in unmatched().toList()) {
      final meaning = _meaning(fileWord.targetWord, fileWord.translation);
      for (final word in free()) {
        final source = word.source;
        if (source == null ||
            _meaning(source.targetWord, source.translation) != meaning) {
          continue;
        }
        // An `id` added in the file to an entry the app made its own id for
        // is still that entry. One saved with another `id` is another word.
        if (fileWord.idIsExplicit ? word.idIsExplicit : false) continue;
        if (fileIds.contains(word.id) && word.id != fileWord.id) continue;
        pair(fileWord, word, WordMatchKind.source);
        break;
      }
    }

    if (!edits) return matches;

    // What is left on both sides: entries the file did not have before, and
    // saved words the file no longer has. An entry and a word that share
    // the word or the translation, when neither could be paired with
    // anything else, are one entry that was edited.
    bool fromFile(VocabItem word) =>
        !word.idIsExplicit &&
        (word.source != null || word.id.startsWith('auto-'));
    final candidates = free().where(fromFile).toList();
    final entries = unmatched().where((word) => !word.idIsExplicit).toList();
    bool related(VocabItem fileWord, VocabItem word) {
      final source = word.source;
      final target = _normalize(source?.targetWord ?? word.targetWord);
      final translation = _normalize(source?.translation ?? word.translation);
      // A translation is reworded freely. A word is only corrected: another
      // word with the same translation is a synonym, not an edit.
      return target == _normalize(fileWord.targetWord) ||
          (translation == _normalize(fileWord.translation) &&
              _isCorrection(target, _normalize(fileWord.targetWord)));
    }

    for (final fileWord in entries) {
      final words = candidates
          .where((word) => related(fileWord, word))
          .toList();
      if (words.length != 1) continue;
      final rivals = entries.where((entry) => related(entry, words.single));
      if (rivals.length != 1) continue;
      pair(fileWord, words.single, WordMatchKind.edited);
    }
    return matches;
  }

  /// Whether [after] could be [before] with a typo fixed: one character in
  /// three at most was changed, added or removed, and at least one.
  static bool _isCorrection(String before, String after) {
    final a = before.runes.toList();
    final b = after.runes.toList();
    if (a.isEmpty || b.isEmpty) return false;
    var row = [for (var j = 0; j <= b.length; j++) j];
    for (var i = 1; i <= a.length; i++) {
      final next = [i];
      for (var j = 1; j <= b.length; j++) {
        final change = row[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1);
        final gap = (row[j] < next[j - 1] ? row[j] : next[j - 1]) + 1;
        next.add(change < gap ? change : gap);
      }
      row = next;
    }
    final longer = a.length > b.length ? a.length : b.length;
    final allowed = longer ~/ 3 < 1 ? 1 : longer ~/ 3;
    return row.last >= 1 && row.last <= allowed;
  }

  static bool _sameSection(VocabItem first, VocabItem second) {
    final a = first.effectiveSectionPath;
    final b = second.effectiveSectionPath;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].trim().toLowerCase() != b[i].trim().toLowerCase()) return false;
    }
    return true;
  }

  /// [word]'s word and translation, loosely: two words with the same key
  /// read the same.
  static String meaningKey(VocabItem word) =>
      _meaning(word.targetWord, word.translation);

  static String _meaning(String word, String translation) =>
      '${_normalize(word)}\u0000${_normalize(translation)}';

  static String _normalize(String word) =>
      word.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
}
