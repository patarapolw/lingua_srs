import 'dart:math' as math;

import 'package:uuid/uuid.dart';

import 'shared_vocab.dart';
import '../services/tts_text.dart';

/// One word's own `**` marking of a pool sentence.
///
/// A pool [Sentence] is plain text and may be shared by several words, but the
/// part of it that matters is different for each word, so each word keeps its
/// own marked copy of the target sentence and of its translation. Without the
/// `**` markers each copy equals the sentence's own text; see
/// [Sentence.carryEmphasis] for when the sentence has been edited since.
class SentenceEmphasis {
  final String target;
  final String translation;

  const SentenceEmphasis({required this.target, required this.translation});

  Map<String, dynamic> toJson() => {
    'target': target,
    'translation': translation,
  };

  factory SentenceEmphasis.fromJson(Map<String, dynamic> json) =>
      SentenceEmphasis(
        target: json['target'] as String? ?? '',
        translation: json['translation'] as String? ?? '',
      );

  @override
  bool operator ==(Object other) =>
      other is SentenceEmphasis &&
      other.target == target &&
      other.translation == translation;

  @override
  int get hashCode => Object.hash(target, translation);

  @override
  String toString() => 'SentenceEmphasis($target | $translation)';
}

class Sentence {
  final String id;
  String targetText;
  String translationText;
  String? audioUrl;

  /// False when the recorded [audioUrl] is not good enough: playback then uses
  /// text-to-speech while the URL stays saved.
  bool useAudio;

  /// Alternate text spoken by text-to-speech instead of [targetText].
  String? ttsText;
  String notes;
  String? lessonId;

  Sentence({
    String? id,
    required this.targetText,
    required this.translationText,
    this.audioUrl,
    this.useAudio = true,
    this.ttsText,
    this.notes = '',
    this.lessonId,
  }) : id = id ?? const Uuid().v4();

  /// Whether a recording is saved, whether or not it is switched on.
  bool get hasAudioUrl => audioUrl?.trim().isNotEmpty ?? false;

  /// The recording to play, or null when there is none or it is switched off.
  String? get playableAudioUrl {
    final url = audioUrl?.trim();
    return useAudio && url != null && url.isNotEmpty ? url : null;
  }

  /// What text-to-speech should say: [ttsText] when set, else [targetText].
  /// A [ttsText] that is only a locale prefix (`zh-TW:`) says [targetText] in
  /// that locale.
  String get speechText => TtsText.speechOf(ttsText, targetText);

  /// What makes two sentences the same one: their text and translation,
  /// whatever the `**` marking, letter case and spacing.
  String get signature {
    String normalize(String text) =>
        withoutEmphasis(text)
            .trim()
            .toLowerCase()
            .replaceAll(RegExp(r'\s+'), ' ');
    return '${normalize(targetText)}\u0000${normalize(translationText)}';
  }

  static String withoutEmphasis(String text) => text
      .replaceAllMapped(RegExp(r'\*\*([^*]+)\*\*'), (match) => match[1] ?? '')
      .replaceAllMapped(RegExp(r'__([^_]+)__'), (match) => match[1] ?? '');

  /// Wraps [vocabulary] in `**` for every place it appears in [text]. A
  /// translation may list several meanings (`a, b` or `a/b`); each one found is
  /// emphasized, so a sentence can end up with several segments. Text that
  /// already has `**` is returned unchanged.
  static String suggestEmphasis(
    String text,
    String vocabulary, {
    bool korean = false,
  }) {
    if (text.contains('**')) return text;
    final candidates = korean
        ? [vocabulary.trim()]
        : vocabulary
              .split(RegExp(r'[,;/]'))
              .map((candidate) => candidate.trim())
              .where((candidate) => candidate.isNotEmpty)
              .toList();

    final ranges = <List<int>>[];
    for (final candidate in candidates) {
      if (candidate.isEmpty) continue;
      var matches = RegExp(
        RegExp.escape(candidate),
        caseSensitive: false,
      ).allMatches(text).toList();
      if (matches.isEmpty && korean) {
        final stem = candidate.endsWith('하다')
            ? candidate.substring(0, candidate.length - 2)
            : candidate.endsWith('다')
            ? candidate.substring(0, candidate.length - 1)
            : candidate;
        if (stem.isEmpty) continue;
        matches = RegExp(
          '${RegExp.escape(stem)}[가-힣]*',
          caseSensitive: false,
        ).allMatches(text).toList();
      }
      for (final match in matches) {
        ranges.add([match.start, match.end]);
      }
    }
    if (ranges.isEmpty) return text;

    ranges.sort((a, b) => a[0].compareTo(b[0]));
    final merged = <List<int>>[ranges.first];
    for (final range in ranges.skip(1)) {
      if (range[0] <= merged.last[1]) {
        if (range[1] > merged.last[1]) merged.last[1] = range[1];
      } else {
        merged.add(range);
      }
    }
    final out = StringBuffer();
    var cursor = 0;
    for (final range in merged) {
      out
        ..write(text.substring(cursor, range[0]))
        ..write('**')
        ..write(text.substring(range[0], range[1]))
        ..write('**');
      cursor = range[1];
    }
    out.write(text.substring(cursor));
    return out.toString();
  }

  static final RegExp _emphasisPattern = RegExp(r'\*\*([^*]+)\*\*');

  /// Removes the `**` markers from [text] and keeps what they surround. Unlike
  /// [withoutEmphasis] it leaves `__` alone: only `**` is emphasis.
  static String stripEmphasis(String text) =>
      text.replaceAllMapped(_emphasisPattern, (match) => match[1] ?? '');

  /// Whether [text] has at least one complete `**emphasis**` segment.
  static bool hasEmphasis(String text) => _emphasisPattern.hasMatch(text);

  /// The emphasized ranges of [marked], counted in the characters of
  /// [stripEmphasis] applied to it.
  static List<({int start, int end})> emphasisRanges(String marked) {
    final ranges = <({int start, int end})>[];
    var removed = 0;
    for (final match in _emphasisPattern.allMatches(marked)) {
      final start = match.start - removed;
      ranges.add((start: start, end: start + match[1]!.length));
      removed += 4;
    }
    return ranges;
  }

  /// Wraps each of [ranges] (sorted, not overlapping) of [plain] in `**`.
  static String markEmphasis(
    String plain,
    Iterable<({int start, int end})> ranges,
  ) {
    final out = StringBuffer();
    var cursor = 0;
    for (final range in ranges) {
      out
        ..write(plain.substring(cursor, range.start))
        ..write('**')
        ..write(plain.substring(range.start, range.end))
        ..write('**');
      cursor = range.end;
    }
    out.write(plain.substring(cursor));
    return out.toString();
  }

  /// Moves the `**` emphasis of [marked] onto [newPlain], the same sentence
  /// after an edit.
  ///
  /// Only the stretch that changed is treated as new: an emphasized segment
  /// wholly before it or wholly after it stays where it was (shifted for the
  /// text in front of it), and a segment the edit touched is dropped. Returns
  /// null when no segment survives, so the caller can fall back to suggesting
  /// emphasis again. A [newPlain] equal to the text of [marked] returns
  /// [marked] unchanged.
  static String? carryEmphasis(String marked, String newPlain) {
    final oldPlain = stripEmphasis(marked);
    if (oldPlain == newPlain) return marked;

    final shortest = math.min(oldPlain.length, newPlain.length);
    var prefix = 0;
    while (prefix < shortest &&
        oldPlain.codeUnitAt(prefix) == newPlain.codeUnitAt(prefix)) {
      prefix++;
    }
    var suffix = 0;
    while (suffix < shortest - prefix &&
        oldPlain.codeUnitAt(oldPlain.length - 1 - suffix) ==
            newPlain.codeUnitAt(newPlain.length - 1 - suffix)) {
      suffix++;
    }

    final shift = newPlain.length - oldPlain.length;
    final kept = <({int start, int end})>[];
    for (final range in emphasisRanges(marked)) {
      if (range.end <= prefix) {
        kept.add(range);
      } else if (range.start >= oldPlain.length - suffix) {
        kept.add((start: range.start + shift, end: range.end + shift));
      }
    }
    return kept.isEmpty ? null : markEmphasis(newPlain, kept);
  }

  /// Turns `**` emphasis on or off for the selection [start]–[end] of
  /// [marked], counted in the characters of [marked] itself (as a text field
  /// selects them), without changing the text.
  ///
  /// - A selection wholly inside emphasis loses its emphasis; the rest of the
  ///   segment stays emphasized.
  /// - Any other selection is emphasized, joining any segment it overlaps or
  ///   touches. Spaces at either end of it are left out.
  /// - With nothing selected, the segment at the cursor loses its emphasis,
  ///   or else the word at the cursor (up to spaces) is emphasized.
  ///
  /// Returns the new text and the selection on it, which covers the same
  /// characters as before. A selection of nothing but spaces, or one that
  /// includes a `*`, is returned unchanged.
  static ({String text, int start, int end}) toggleEmphasis(
    String marked,
    int start,
    int end,
  ) {
    final unchanged = (text: marked, start: start, end: end);
    if (start > end) {
      final first = end;
      end = start;
      start = first;
    }
    final plain = stripEmphasis(marked);
    final ranges = emphasisRanges(marked);
    var from = _plainOffset(marked, start);
    var to = _plainOffset(marked, end);

    bool inside(({int start, int end}) range) =>
        range.start <= from && to <= range.end;

    List<({int start, int end})> result;
    if (from == to) {
      final at = ranges.where(inside).firstOrNull;
      if (at != null) {
        result = [...ranges]..remove(at);
      } else {
        final space = RegExp(r'\s');
        while (from > 0 && !space.hasMatch(plain[from - 1])) {
          from--;
        }
        while (to < plain.length && !space.hasMatch(plain[to])) {
          to++;
        }
        if (from == to || plain.substring(from, to).contains('*')) {
          return unchanged;
        }
        result = _addRange(ranges, from, to);
      }
    } else if (_covered(ranges, from, to)) {
      result = [
        for (final range in ranges)
          if (range.end <= from || range.start >= to)
            range
          else ...[
            if (range.start < from) (start: range.start, end: from),
            if (range.end > to) (start: to, end: range.end),
          ],
      ];
    } else {
      while (from < to && plain[from].trim().isEmpty) {
        from++;
      }
      while (to > from && plain[to - 1].trim().isEmpty) {
        to--;
      }
      if (from == to || plain.substring(from, to).contains('*')) {
        return unchanged;
      }
      result = _addRange(ranges, from, to);
    }

    final text = markEmphasis(plain, result);
    final newStart = _markedOffset(from, result, isEnd: false);
    return (
      text: text,
      start: newStart,
      end: from == to ? newStart : _markedOffset(to, result, isEnd: true),
    );
  }

  /// Whether all of the selection [start]–[end] of [marked] (counted as in
  /// [toggleEmphasis]) is already emphasized, so toggling it takes the
  /// emphasis away. An empty selection never is.
  static bool isEmphasized(String marked, int start, int end) {
    final from = _plainOffset(marked, start < end ? start : end);
    final to = _plainOffset(marked, start < end ? end : start);
    return from < to && _covered(emphasisRanges(marked), from, to);
  }

  /// Where [offset] of [marked] falls in its text without `**`. An offset on
  /// a marker counts as the edge of the text it marks.
  static int _plainOffset(String marked, int offset) {
    var removed = 0;
    for (final match in _emphasisPattern.allMatches(marked)) {
      if (offset <= match.start) break;
      if (offset <= match.start + 2) return match.start - removed;
      if (offset <= match.end - 2) return offset - removed - 2;
      if (offset < match.end) return match.end - removed - 4;
      removed += 4;
    }
    return offset - removed;
  }

  /// Where [plainOffset] falls once [ranges] are wrapped in `**`: inside a
  /// segment it starts or ends, as a selection of that segment would be.
  static int _markedOffset(
    int plainOffset,
    List<({int start, int end})> ranges, {
    required bool isEnd,
  }) {
    var offset = plainOffset;
    for (final range in ranges) {
      if (range.end < plainOffset || (range.end == plainOffset && !isEnd)) {
        offset += 4;
      } else if (range.start < plainOffset ||
          (range.start == plainOffset && !isEnd)) {
        offset += 2;
      }
    }
    return offset;
  }

  /// Whether every character from [from] to [to] is inside one of [ranges].
  static bool _covered(List<({int start, int end})> ranges, int from, int to) {
    var cursor = from;
    for (final range in ranges) {
      if (range.end <= cursor) continue;
      if (range.start > cursor) return false;
      cursor = range.end;
      if (cursor >= to) return true;
    }
    return cursor >= to;
  }

  /// [ranges] with [from]–[to] added, merging the ones that overlap or touch.
  static List<({int start, int end})> _addRange(
    List<({int start, int end})> ranges,
    int from,
    int to,
  ) {
    final result = <({int start, int end})>[];
    for (final range in ranges) {
      if (range.end < from || range.start > to) {
        result.add(range);
      } else {
        from = math.min(from, range.start);
        to = math.max(to, range.end);
      }
    }
    result
      ..add((start: from, end: to))
      ..sort((a, b) => a.start.compareTo(b.start));
    return result;
  }

  /// Generates cloze deletion sentence for target word.
  /// 1. If target word is wrapped in markdown bold (**word**), replaces **word** with (___).
  /// 2. If targetWord matches directly, replaces with (___).
  /// 3. If targetWord is a verb/adjective with a stem (e.g. 도착하다 -> stem 도착),
  ///    replaces the conjugated word with (___).
  ///
  /// This blanks the `**` of the sentence's own text. A pool sentence is plain,
  /// so a review blanks a word's own marking instead: see
  /// `VocabItem.clozeFor`.
  String toCloze({String? targetWord}) =>
      clozeOf(targetText, targetWord: targetWord);

  /// The cloze of [text], as [toCloze] describes.
  static String clozeOf(String text, {String? targetWord}) {
    // 1. If sentence has bold markdown like **word**, replace all bold segments
    final boldRegex = RegExp(r'\*\*([^*]+)\*\*');
    if (boldRegex.hasMatch(text)) {
      return text.replaceAllMapped(boldRegex, (match) {
        return '(___)';
      });
    }

    // 2. Otherwise replace targetWord directly if available
    if (targetWord != null && targetWord.trim().isNotEmpty) {
      final cleanWord = targetWord.trim();
      if (text.contains(cleanWord)) {
        return text.replaceAll(cleanWord, '(___)');
      }

      // 3. Korean verb/adjective stem matching (e.g. 도착하다 -> 도착, 복잡하다 -> 복잡)
      String stem = cleanWord;
      if (cleanWord.endsWith('하다') && cleanWord.length > 2) {
        stem = cleanWord.substring(0, cleanWord.length - 2);
      } else if (cleanWord.endsWith('다') && cleanWord.length > 1) {
        stem = cleanWord.substring(0, cleanWord.length - 1);
      }

      if (stem.isNotEmpty && text.contains(stem)) {
        // Replace stem + following Korean letters
        final stemRegex = RegExp('$stem[가-힣]*');
        return text.replaceAll(stemRegex, '(___)');
      }
    }

    return text;
  }

  /// Strips markdown and cloze syntax for clean Text-to-Speech.
  ///
  /// With [skipBrackets] (the default) the text is also made fit to be said
  /// aloud, or the voice would stutter over asides or read out the marks:
  ///
  /// - Asides in brackets are dropped, along with the space before them:
  ///   round `(…)` and full-width `（…）`, square `[…]` and `［…］`, and
  ///   lenticular `【…】`, as in `먹다 (to eat)` or `垃圾（lājī）`. A markdown
  ///   link `[text](url)` keeps its text.
  /// - Marks between alternatives, `/`, `／`, `|` and `｜`, become a pause
  ///   (`, `): `은/는` is said as `은, 는`, not "은 slash 는". A slash between
  ///   digits (`1/2`) is kept, for the voice to read as a number or date.
  /// - Arrows (`→`, `←`, `↔`, `⇒`) become a pause too.
  /// - Runs of spaces are collapsed, and a pause left at either end goes.
  ///
  /// Callers that need every character, like the romanizer, pass `false`:
  /// only markdown and cloze blanks are removed then.
  static String cleanForSpeech(String text, {bool skipBrackets = true}) {
    String clean = text.replaceAllMapped(
      RegExp(r'\*\*([^*]+)\*\*'),
      (m) => m[1] ?? '',
    );
    clean = clean.replaceAll(RegExp(r'\[___*\]|\(___*_*\)'), '');
    if (!skipBrackets) {
      return clean.replaceAll(RegExp(r'[#*_~`]'), '').trim();
    }
    clean = clean.replaceAllMapped(_markdownLink, (m) => m[1] ?? '');
    clean = clean.replaceAll(_speechAside, '');
    clean = clean.replaceAll(RegExp(r'[#*_~`]'), '');
    final marked = clean;
    clean = marked.replaceAllMapped(_alternativeMark, (m) {
      final before = m.start > 0 ? marked[m.start - 1] : '';
      final after = m.end < marked.length ? marked[m.end] : '';
      final isNumber =
          m[0]!.contains(RegExp('[/／]')) &&
          _digit.hasMatch(before) &&
          _digit.hasMatch(after);
      return isNumber ? m[0]! : ', ';
    });
    clean = clean.replaceAll(RegExp(r'[ \t]{2,}'), ' ');
    clean = clean.replaceAll(RegExp(r',(\s*,)+'), ',');
    clean = clean.replaceAll(RegExp(r'\s+([,，、。.!?！？])'), r'$1');
    clean = clean.replaceAll(RegExp(r'^[\s,]+|[\s,]+$'), '');
    return clean;
  }

  static final _markdownLink = RegExp(r'\[([^\]]*)\]\([^)]*\)');
  static final _speechAside = RegExp(
    r'\s*(?:\(.+?\)|（.+?）|\[.+?\]|［.+?］|【.+?】)',
  );
  static final _alternativeMark = RegExp(r'\s*[/／|｜→←↔⇒]\s*');
  static final _digit = RegExp(r'[0-9０-９]');

  Map<String, dynamic> toJson() => {
    'id': id,
    'targetText': targetText,
    'translationText': translationText,
    'audioUrl': audioUrl,
    'useAudio': useAudio,
    SharedVocab.ttsField: ttsText,
    'notes': notes,
    'lessonId': lessonId,
  };

  factory Sentence.fromJson(Map<String, dynamic> json) => Sentence(
    id: json['id'] as String?,
    targetText: json['targetText'] as String? ?? '',
    translationText: json['translationText'] as String? ?? '',
    audioUrl: json['audioUrl'] as String?,
    useAudio: json['useAudio'] as bool? ?? true,
    ttsText: SharedVocab.ttsFromJson(json),
    notes: json['notes'] as String? ?? '',
    lessonId: json['lessonId'] as String?,
  );
}
