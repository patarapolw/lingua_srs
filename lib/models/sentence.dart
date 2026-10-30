import 'dart:math' as math;

import 'package:uuid/uuid.dart';

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
  String get speechText =>
      ttsText == null || ttsText!.trim().isEmpty ? targetText : ttsText!.trim();

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
  /// With [skipBrackets] (the default) text in round brackets is dropped too,
  /// along with the space before it, or the voice would stutter over asides
  /// such as `먹다 (to eat)`. Callers that need every character, like the
  /// romanizer, pass `false`.
  static String cleanForSpeech(String text, {bool skipBrackets = true}) {
    String clean = text.replaceAllMapped(
      RegExp(r'\*\*([^*]+)\*\*'),
      (m) => m[1] ?? '',
    );
    clean = clean.replaceAll(RegExp(r'\[___*\]|\(___*_*\)'), '');
    if (skipBrackets) clean = clean.replaceAll(RegExp(r'\s*\(.+?\)'), '');
    clean = clean.replaceAll(RegExp(r'[#*_~`]'), '');
    return clean.trim();
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'targetText': targetText,
    'translationText': translationText,
    'audioUrl': audioUrl,
    'useAudio': useAudio,
    'ttsText': ttsText,
    'notes': notes,
    'lessonId': lessonId,
  };

  factory Sentence.fromJson(Map<String, dynamic> json) => Sentence(
    id: json['id'] as String?,
    targetText: json['targetText'] as String? ?? '',
    translationText: json['translationText'] as String? ?? '',
    audioUrl: json['audioUrl'] as String?,
    useAudio: json['useAudio'] as bool? ?? true,
    ttsText: json['ttsText'] as String?,
    notes: json['notes'] as String? ?? '',
    lessonId: json['lessonId'] as String?,
  );
}
