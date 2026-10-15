import 'package:uuid/uuid.dart';

import 'srs_card.dart';

class VocabItem {
  String id;
  bool idIsExplicit;
  String targetWord;
  String translation;
  String pos; // Part of speech or category (e.g. nouns, verbs, adjectives)
  List<String> sectionPath;
  String? audioUrl;
  String notes; // Markdown / HTML formatted notes
  List<String> sentenceIds; // Reference to sentences in the pool
  SrsCard cardTargetToNative; // e.g. KO -> EN
  SrsCard cardNativeToTarget; // e.g. EN -> KO

  VocabItem({
    String? id,
    this.idIsExplicit = false,
    required this.targetWord,
    required this.translation,
    required this.pos,
    List<String>? sectionPath,
    this.audioUrl,
    this.notes = '',
    List<String>? sentenceIds,
    SrsCard? cardTargetToNative,
    SrsCard? cardNativeToTarget,
  }) : id = id ?? const Uuid().v4(),
       sectionPath = sectionPath ?? (pos.isEmpty ? [] : [pos]),
       sentenceIds = sentenceIds ?? [],
       cardTargetToNative =
           cardTargetToNative ??
           SrsCard(
             direction: CardDirection.targetToNative,
             isEnabled: !isVerbOrAdjective(pos),
           ),
       cardNativeToTarget =
           cardNativeToTarget ??
           SrsCard(
             direction: CardDirection.nativeToTarget,
             isEnabled: isVerbOrAdjective(pos),
           );

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
    'notes': notes,
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
    notes: json['notes'] as String? ?? '',
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
