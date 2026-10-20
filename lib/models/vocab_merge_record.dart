import '../models/vocab_item.dart';

/// One distinct vocabulary (shared id) with every lesson that uses it.
class VocabGroup {
  VocabGroup({required this.id, required this.entry, required this.reviews})
    : lessonTitles = [];

  final String id;
  final VocabItem entry; // representative entry
  final int reviews;
  final List<String> lessonTitles;

  String get label => '${entry.targetWord} — ${entry.translation}';
}

/// What an absorbed entry looked like before the merge.
class MergedEntrySnapshot {
  const MergedEntrySnapshot({
    required this.lessonId,
    required this.targetWord,
    required this.translation,
    required this.sectionPath,
    required this.previousId,
    required this.previousIdIsExplicit,
    required this.previousShared,
  });

  final String lessonId;
  final String targetWord;
  final String translation;
  final List<String> sectionPath;
  final String previousId;
  final bool previousIdIsExplicit;
  final Map<String, dynamic> previousShared; // SharedVocab.toJson()

  bool matches(String lessonId, VocabItem entry) {
    if (this.lessonId != lessonId ||
        targetWord != entry.targetWord ||
        translation != entry.translation) {
      return false;
    }
    final path = entry.effectiveSectionPath;
    if (path.length != sectionPath.length) return false;
    for (var i = 0; i < path.length; i++) {
      if (path[i] != sectionPath[i]) return false;
    }
    return true;
  }

  Map<String, dynamic> toJson() => {
    'lessonId': lessonId,
    'targetWord': targetWord,
    'translation': translation,
    'sectionPath': sectionPath,
    'previousId': previousId,
    'previousIdIsExplicit': previousIdIsExplicit,
    'previousShared': previousShared,
  };

  factory MergedEntrySnapshot.fromJson(Map<String, dynamic> json) =>
      MergedEntrySnapshot(
        lessonId: json['lessonId'] as String,
        targetWord: json['targetWord'] as String,
        translation: json['translation'] as String,
        sectionPath: (json['sectionPath'] as List).cast<String>(),
        previousId: json['previousId'] as String,
        previousIdIsExplicit: json['previousIdIsExplicit'] as bool,
        previousShared: Map<String, dynamic>.from(
          json['previousShared'] as Map,
        ),
      );
}

class VocabMergeRecord {
  const VocabMergeRecord({
    required this.id,
    required this.createdAt,
    required this.survivorId,
    required this.label,
    required this.source,
    required this.survivorBefore,
    required this.survivorAfter,
    required this.entries,
    this.reason = '',
  });

  final String id;
  final DateTime createdAt;
  final String survivorId;
  final String label; // "absorbed → survivor", for the history list
  final String source; // 'manual' | 'ai'
  final String reason;
  final Map<String, dynamic> survivorBefore; // SharedVocab.toJson()
  final Map<String, dynamic> survivorAfter;
  final List<MergedEntrySnapshot> entries;

  Map<String, dynamic> toJson() => {
    'id': id,
    'createdAt': createdAt.toIso8601String(),
    'survivorId': survivorId,
    'label': label,
    'source': source,
    'reason': reason,
    'survivorBefore': survivorBefore,
    'survivorAfter': survivorAfter,
    'entries': entries.map((e) => e.toJson()).toList(),
  };

  factory VocabMergeRecord.fromJson(
    Map<String, dynamic> json,
  ) => VocabMergeRecord(
    id: json['id'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String),
    survivorId: json['survivorId'] as String,
    label: json['label'] as String? ?? '',
    source: json['source'] as String? ?? 'manual',
    reason: json['reason'] as String? ?? '',
    survivorBefore: Map<String, dynamic>.from(json['survivorBefore'] as Map),
    survivorAfter: Map<String, dynamic>.from(json['survivorAfter'] as Map),
    entries: (json['entries'] as List)
        .map(
          (e) =>
              MergedEntrySnapshot.fromJson(Map<String, dynamic>.from(e as Map)),
        )
        .toList(),
  );
}

class VocabMergeUndoResult {
  const VocabMergeUndoResult({required this.restored, required this.missing});
  final int restored;
  final int missing; // entries that were deleted or edited since the merge
}
