import 'package:uuid/uuid.dart';

import 'shared_vocab.dart';
import 'srs_card.dart';

class VocabItem {
  String id;
  bool idIsExplicit;
  String targetWord;
  String translation;
  String pos; // Part of speech or category (e.g. nouns, verbs, adjectives)
  List<String> sectionPath;
  List<String> sentenceIds; // Reference to sentences in the pool
  /// Details and SRS cards shared by every VocabItem with the same [id].
  SharedVocab shared;

  VocabItem({
    String? id,
    this.idIsExplicit = false,
    required this.targetWord,
    required this.translation,
    required this.pos,
    List<String>? sectionPath,
    String? audioUrl,
    bool useAudio = true,
    String? ttsText,
    String notes = '',
    String disambiguation = '',
    List<String>? sentenceIds,
    SrsCard? cardTargetToNative,
    SrsCard? cardNativeToTarget,
  }) : id = id ?? const Uuid().v4(),
       sectionPath = sectionPath ?? (pos.isEmpty ? [] : [pos]),
       sentenceIds = sentenceIds ?? [],
       shared = SharedVocab(
         audioUrl: audioUrl,
         useAudio: useAudio,
         ttsText: ttsText,
         notes: notes,
         disambiguation: disambiguation,
         cardTargetToNative:
             cardTargetToNative ??
             SrsCard(
               direction: CardDirection.targetToNative,
               isEnabled: !isVerbOrAdjective(pos),
             ),
         cardNativeToTarget:
             cardNativeToTarget ??
             SrsCard(
               direction: CardDirection.nativeToTarget,
               isEnabled: isVerbOrAdjective(pos),
             ),
       );

  String? get audioUrl => shared.audioUrl;
  set audioUrl(String? v) {
    shared.setManual(SharedVocab.audioField, v);
  }

  bool get useAudio => shared.useAudio;
  set useAudio(bool v) => shared.useAudio = v;

  /// The recording to play, or null when there is none or it is switched off.
  String? get playableAudioUrl {
    final url = audioUrl?.trim();
    return useAudio && url != null && url.isNotEmpty ? url : null;
  }

  String? get ttsText => shared.ttsText;
  set ttsText(String? v) {
    shared.setManual(SharedVocab.ttsField, v);
  }

  /// What text-to-speech should say: [ttsText] when set, else [targetWord].
  String get speechText =>
      SharedVocab.isBlank(ttsText) ? targetWord : ttsText!.trim();

  String get notes => shared.notes;
  set notes(String v) {
    shared.setManual(SharedVocab.notesField, v);
  }

  String get disambiguation => shared.disambiguation;
  set disambiguation(String v) {
    shared.setManual(SharedVocab.disambiguationField, v);
  }

  SrsCard get cardTargetToNative => shared.cardTargetToNative;
  set cardTargetToNative(SrsCard v) => shared.cardTargetToNative = v;
  SrsCard get cardNativeToTarget => shared.cardNativeToTarget;
  set cardNativeToTarget(SrsCard v) => shared.cardNativeToTarget = v;

  /// Hint for the front of [direction]'s card: its own hint, else the general one.
  String frontHintFor(CardDirection direction) {
    final card = direction == CardDirection.targetToNative
        ? cardTargetToNative
        : cardNativeToTarget;
    final own = card.frontHint.trim();
    return own.isNotEmpty ? own : disambiguation;
  }

  static bool isVerbOrAdjective(String category) {
    final lower = category.toLowerCase().trim();
    return lower == 'verb' ||
        lower == 'verbs' ||
        lower == 'adjective' ||
        lower == 'adjectives' ||
        lower.contains('verb') ||
        lower.contains('adjective');
  }

  List<String> get effectiveSectionPath =>
      sectionPath.isEmpty ? (pos.isEmpty ? const [] : [pos]) : sectionPath;

  Map<String, dynamic> toJson() => {
    'id': id,
    'idIsExplicit': idIsExplicit,
    'targetWord': targetWord,
    'translation': translation,
    'pos': pos,
    'sectionPath': sectionPath,
    'audioUrl': audioUrl,
    'useAudio': useAudio,
    'ttsText': ttsText,
    'notes': notes,
    'disambiguation': disambiguation,
    'sentenceIds': sentenceIds,
    'cardTargetToNative': cardTargetToNative.toJson(),
    'cardNativeToTarget': cardNativeToTarget.toJson(),
  };

  factory VocabItem.fromJson(Map<String, dynamic> json) => VocabItem(
    id: json['id'] as String?,
    idIsExplicit: json['idIsExplicit'] as bool? ?? false,
    targetWord: json['targetWord'] as String? ?? '',
    translation: json['translation'] as String? ?? '',
    pos: json['pos'] as String? ?? 'general',
    sectionPath: (json['sectionPath'] as List<dynamic>?)
        ?.map((e) => e.toString())
        .toList(),
    audioUrl: json['audioUrl'] as String?,
    useAudio: json['useAudio'] as bool? ?? true,
    ttsText: json['ttsText'] as String?,
    notes: json['notes'] as String? ?? '',
    disambiguation: json['disambiguation'] as String? ?? '',
    sentenceIds:
        (json['sentenceIds'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .toList() ??
        [],
    cardTargetToNative: json['cardTargetToNative'] != null
        ? SrsCard.fromJson(
            Map<String, dynamic>.from(json['cardTargetToNative'] as Map),
          )
        : null,
    cardNativeToTarget: json['cardNativeToTarget'] != null
        ? SrsCard.fromJson(
            Map<String, dynamic>.from(json['cardNativeToTarget'] as Map),
          )
        : null,
  );
}
