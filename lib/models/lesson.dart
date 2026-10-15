import 'package:uuid/uuid.dart';

import 'vocab_item.dart';
import 'srs_card.dart';

class Lesson {
  final String id;
  String title;
  String? unitTitle;
  String targetLanguage; // e.g. 'ko', 'es', 'ja', 'fr'
  String nativeLanguage; // e.g. 'en'
  List<VocabItem> vocabularies;

  Lesson({
    String? id,
    required this.title,
    this.unitTitle,
    this.targetLanguage = 'ko',
    this.nativeLanguage = 'en',
    List<VocabItem>? vocabularies,
  }) : id = id ?? const Uuid().v4(),
       vocabularies = vocabularies ?? [];

  String? get effectiveUnitTitle {
    final explicitUnit = unitTitle?.trim();
    if (explicitUnit != null && explicitUnit.isNotEmpty) return explicitUnit;

    final match = RegExp(
      r'^(Unit\s+\d+)\s*[/\\]\s*(.+)$',
      caseSensitive: false,
    ).firstMatch(title.trim());
    return match?.group(1);
  }

  String get displayTitle {
    final match = RegExp(
      r'^Unit\s+\d+\s*[/\\]\s*(.+)$',
      caseSensitive: false,
    ).firstMatch(title.trim());
    return match?.group(1) ?? title;
  }

  int get activeCardsCount {
    int count = 0;
    final countedCards = <String>{};
    for (final v in vocabularies) {
      if (v.cardTargetToNative.isEnabled &&
          countedCards.add(v.cardTargetToNative.id)) {
        count++;
      }
      if (v.cardNativeToTarget.isEnabled &&
          countedCards.add(v.cardNativeToTarget.id)) {
        count++;
      }
    }
    return count;
  }

  int get dueCardsCount {
    int count = 0;
    final countedCards = <String>{};
    for (final v in vocabularies) {
      if (v.cardTargetToNative.isEnabled &&
          v.cardTargetToNative.isDue &&
          countedCards.add(v.cardTargetToNative.id)) {
        count++;
      }
      if (v.cardNativeToTarget.isEnabled &&
          v.cardNativeToTarget.isDue &&
          countedCards.add(v.cardNativeToTarget.id)) {
        count++;
      }
    }
    return count;
  }

  int get newCardsCount {
    int count = 0;
    final countedCards = <String>{};
    for (final v in vocabularies) {
      if (v.cardTargetToNative.isEnabled &&
          v.cardTargetToNative.status == SrsStatus.isNew &&
          countedCards.add(v.cardTargetToNative.id)) {
        count++;
      }
      if (v.cardNativeToTarget.isEnabled &&
          v.cardNativeToTarget.status == SrsStatus.isNew &&
          countedCards.add(v.cardNativeToTarget.id)) {
        count++;
      }
    }
    return count;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'unitTitle': unitTitle,
    'targetLanguage': targetLanguage,
    'nativeLanguage': nativeLanguage,
    'vocabularies': vocabularies.map((v) => v.toJson()).toList(),
  };

  factory Lesson.fromJson(Map<String, dynamic> json) => Lesson(
    id: json['id'] as String?,
    title: json['title'] as String? ?? 'Untitled Lesson',
    unitTitle: json['unitTitle'] as String?,
    targetLanguage: json['targetLanguage'] as String? ?? 'ko',
    nativeLanguage: json['nativeLanguage'] as String? ?? 'en',
    vocabularies:
        (json['vocabularies'] as List<dynamic>?)
            ?.map(
              (v) => VocabItem.fromJson(Map<String, dynamic>.from(v as Map)),
            )
            .toList() ??
        [],
  );
}
