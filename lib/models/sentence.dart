import 'package:uuid/uuid.dart';

class Sentence {
  final String id;
  String targetText;
  String translationText;
  String? audioUrl;
  String? lessonId;

  Sentence({
    String? id,
    required this.targetText,
    required this.translationText,
    this.audioUrl,
    this.lessonId,
  }) : id = id ?? const Uuid().v4();

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

  /// Strips markdown and cloze syntax for clean Text-to-Speech
  static String cleanForSpeech(String text) {
    String clean = text.replaceAllMapped(RegExp(r'\*\*([^*]+)\*\*'), (m) => m[1] ?? '');
    clean = clean.replaceAll(RegExp(r'\[___*\]|\(___*_*\)'), '');
    clean = clean.replaceAll(RegExp(r'[#*_~`]'), '');
    return clean.trim();
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'targetText': targetText,
        'translationText': translationText,
        'audioUrl': audioUrl,
        'lessonId': lessonId,
      };

  factory Sentence.fromJson(Map<String, dynamic> json) => Sentence(
        id: json['id'] as String?,
        targetText: json['targetText'] as String? ?? '',
        translationText: json['translationText'] as String? ?? '',
        audioUrl: json['audioUrl'] as String?,
        lessonId: json['lessonId'] as String?,
      );
}
