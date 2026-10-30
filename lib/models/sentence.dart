import 'package:uuid/uuid.dart';

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

  /// True when [edited] differs from [original] only by `**` emphasis. A
  /// sentence is identified by its text without emphasis, so anything else
  /// would turn it into a different sentence.
  static bool sameExceptEmphasis(String original, String edited) =>
      withoutEmphasis(original) == withoutEmphasis(edited);

  /// Generates cloze deletion sentence for target word.
  /// 1. If target word is wrapped in markdown bold (**word**), replaces **word** with (___).
  /// 2. If targetWord matches directly, replaces with (___).
  /// 3. If targetWord is a verb/adjective with a stem (e.g. 도착하다 -> stem 도착),
  ///    replaces the conjugated word with (___).
  String toCloze({String? targetWord}) {
    // 1. If sentence has bold markdown like **word**, replace all bold segments
    final boldRegex = RegExp(r'\*\*([^*]+)\*\*');
    if (boldRegex.hasMatch(targetText)) {
      return targetText.replaceAllMapped(boldRegex, (match) {
        return '(___)';
      });
    }

    // 2. Otherwise replace targetWord directly if available
    if (targetWord != null && targetWord.trim().isNotEmpty) {
      final cleanWord = targetWord.trim();
      if (targetText.contains(cleanWord)) {
        return targetText.replaceAll(cleanWord, '(___)');
      }

      // 3. Korean verb/adjective stem matching (e.g. 도착하다 -> 도착, 복잡하다 -> 복잡)
      String stem = cleanWord;
      if (cleanWord.endsWith('하다') && cleanWord.length > 2) {
        stem = cleanWord.substring(0, cleanWord.length - 2);
      } else if (cleanWord.endsWith('다') && cleanWord.length > 1) {
        stem = cleanWord.substring(0, cleanWord.length - 1);
      }

      if (stem.isNotEmpty && targetText.contains(stem)) {
        // Replace stem + following Korean letters
        final stemRegex = RegExp('$stem[가-힣]*');
        return targetText.replaceAll(stemRegex, '(___)');
      }
    }

    return targetText;
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
