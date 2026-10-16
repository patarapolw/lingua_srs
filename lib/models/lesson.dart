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
  String markdownContent;

  Lesson({
    String? id,
    required this.title,
    this.unitTitle,
    this.targetLanguage = 'ko',
    this.nativeLanguage = 'en',
    List<VocabItem>? vocabularies,
    this.markdownContent = '',
  }) : id = id ?? const Uuid().v4(),
       vocabularies = vocabularies ?? [];

  String? get effectiveUnitTitle {
    final explicitParts = _hierarchyParts(unitTitle);
    var titleParts = _hierarchyParts(title);
    var repeatsExplicitPath =
        explicitParts.isNotEmpty && titleParts.length >= explicitParts.length;
    for (
      var index = 0;
      repeatsExplicitPath && index < explicitParts.length;
      index++
    ) {
      repeatsExplicitPath =
          explicitParts[index].toLowerCase() == titleParts[index].toLowerCase();
    }
    if (repeatsExplicitPath) {
      titleParts = titleParts.skip(explicitParts.length).toList();
    }
    final folderParts = [
      ...explicitParts,
      ...titleParts.take(titleParts.isEmpty ? 0 : titleParts.length - 1),
    ];
    return folderParts.isEmpty ? null : folderParts.join(' / ');
  }

  String get displayTitle {
    final titleParts = _hierarchyParts(title);
    return titleParts.isEmpty ? title : titleParts.last;
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
    markdownContent: json['markdownContent'] as String? ?? '',
    vocabularies:
        (json['vocabularies'] as List<dynamic>?)
            ?.map(
              (v) => VocabItem.fromJson(Map<String, dynamic>.from(v as Map)),
            )
            .toList() ??
        [],
  );
}

List<String> _hierarchyParts(String? path) =>
    path
        ?.split(' / ')
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList() ??
    [];
