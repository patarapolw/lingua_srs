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

  /// Folder segments containing this lesson, from [unitTitle] plus any leading
  /// segments of [title].
  List<String> get folderPath {
    final explicitParts = splitHierarchyPath(unitTitle);
    var titleParts = splitHierarchyPath(title);
    if (isHierarchyPathWithin(titleParts, explicitParts)) {
      titleParts = titleParts.skip(explicitParts.length).toList();
    }
    return [
      ...explicitParts,
      ...titleParts.take(titleParts.isEmpty ? 0 : titleParts.length - 1),
    ];
  }

  /// Display-only form of [folderPath].
  String? get effectiveUnitTitle {
    final path = folderPath;
    return path.isEmpty ? null : formatHierarchyPath(path);
  }

  String get displayTitle {
    final titleParts = splitHierarchyPath(title);
    return titleParts.isEmpty ? title : titleParts.last;
  }

  void moveToFolder(List<String> folder) {
    final leafTitle = displayTitle;
    unitTitle = folder.isEmpty ? null : joinHierarchyPath(folder);
    title = leafTitle;
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

const hierarchySeparator = '::';

/// The only place a stored/typed path string is split. Everything else passes
/// `List<String>` so segments containing `/` or spaces are never mangled.
List<String> splitHierarchyPath(String? path) =>
    path
        ?.split(hierarchySeparator)
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList() ??
    [];

String joinHierarchyPath(Iterable<String> path) =>
    path.join(hierarchySeparator);

String formatHierarchyPath(Iterable<String> path) => path.join(' › ');

String hierarchyFolderKey(Iterable<String> path) =>
    'folder:${path.map((part) => part.toLowerCase()).join(hierarchySeparator)}';

/// Whether [path] equals [ancestor] or is nested beneath it (case-insensitive).
bool isHierarchyPathWithin(List<String> path, List<String> ancestor) {
  if (ancestor.isEmpty || path.length < ancestor.length) return false;
  for (var index = 0; index < ancestor.length; index++) {
    if (path[index].toLowerCase() != ancestor[index].toLowerCase()) {
      return false;
    }
  }
  return true;
}

bool isSameHierarchyPath(List<String> a, List<String> b) =>
    a.length == b.length && (a.isEmpty || isHierarchyPathWithin(a, b));
