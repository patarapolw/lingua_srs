import 'srs_card.dart';

enum DetailOrigin { manual, imported }

class DetailMeta {
  const DetailMeta(this.origin, [this.lessonId]);
  final DetailOrigin origin;
  final String? lessonId;

  Map<String, dynamic> toJson() => {
    'origin': origin.name,
    'lessonId': lessonId,
  };

  factory DetailMeta.fromJson(Map<String, dynamic> json) => DetailMeta(
    DetailOrigin.values.firstWhere(
      (o) => o.name == json['origin'],
      orElse: () => DetailOrigin.imported,
    ),
    json['lessonId'] as String?,
  );
}

/// Details and SRS cards shared by every VocabItem with the same id.
class SharedVocab {
  static const audioField = 'audioUrl';
  static const notesField = 'notes';
  static const disambiguationField = 'disambiguation';
  static const detailFields = [audioField, notesField, disambiguationField];
  static const _maxAlternates = 5;

  String? audioUrl;
  String notes;
  String disambiguation;
  SrsCard cardTargetToNative;
  SrsCard cardNativeToTarget;
  final Map<String, DetailMeta> meta;
  final Map<String, List<String>> alternates;

  SharedVocab({
    this.audioUrl,
    this.notes = '',
    this.disambiguation = '',
    required this.cardTargetToNative,
    required this.cardNativeToTarget,
    Map<String, DetailMeta>? meta,
    Map<String, List<String>>? alternates,
  }) : meta = meta ?? {},
       alternates = alternates ?? {};

  static bool isBlank(String? value) => value == null || value.trim().isEmpty;

  String? valueOf(String field) {
    switch (field) {
      case audioField:
        return audioUrl;
      case notesField:
        return notes;
      case disambiguationField:
        return disambiguation;
    }
    throw ArgumentError.value(field, 'field');
  }

  void _write(String field, String? value) {
    switch (field) {
      case audioField:
        audioUrl = value;
      case notesField:
        notes = value ?? '';
      case disambiguationField:
        disambiguation = value ?? '';
      default:
        throw ArgumentError.value(field, 'field');
    }
  }

  /// A manual edit. Wins over imports; clearing a field locks it as empty.
  /// No-op when the value is unchanged, so saving a dialog does not lock fields.
  bool setManual(String field, String? value) {
    final next = isBlank(value) ? null : value;
    final currentRaw = valueOf(field);
    final current = isBlank(currentRaw) ? null : currentRaw;
    if (next == current) return false;
    _write(field, next);
    meta[field] = const DetailMeta(DetailOrigin.manual);
    return true;
  }

  /// An imported value. Returns true if the stored value changed.
  bool mergeImport(String field, String? incoming, {String? lessonId}) {
    if (isBlank(incoming)) return false;
    final current = valueOf(field);
    final m = meta[field];
    if (isBlank(current)) {
      if (m?.origin == DetailOrigin.manual) {
        _addAlternate(field, incoming!);
        return false;
      }
      _write(field, incoming);
      meta[field] = DetailMeta(DetailOrigin.imported, lessonId);
      return true;
    }
    if (current == incoming) return false;
    final ownedByThisLesson =
        lessonId != null &&
        m?.origin != DetailOrigin.manual &&
        m?.lessonId == lessonId;
    if (ownedByThisLesson) {
      _write(field, incoming);
      alternates[field]?.remove(incoming);
      return true;
    }
    _addAlternate(field, incoming!);
    return false;
  }

  /// Gives values with no recorded writer to [lessonId].
  void stampUnowned(String lessonId) {
    for (final field in detailFields) {
      if (!isBlank(valueOf(field)) && !meta.containsKey(field)) {
        meta[field] = DetailMeta(DetailOrigin.imported, lessonId);
      }
    }
  }

  /// Copies one field, its provenance and its alternates from [from] (undo).
  void restoreField(String field, SharedVocab from) {
    _write(field, from.valueOf(field));
    final m = from.meta[field];
    if (m == null) {
      meta.remove(field);
    } else {
      meta[field] = m;
    }
    final alt = from.alternates[field];
    if (alt == null) {
      alternates.remove(field);
    } else {
      alternates[field] = [...alt];
    }
  }

  void _addAlternate(String field, String value) {
    if (value == valueOf(field)) return;
    final list = alternates.putIfAbsent(field, () => []);
    if (list.contains(value)) return;
    list.add(value);
    while (list.length > _maxAlternates) {
      list.removeAt(0);
    }
  }

  /// Same details, fresh progress. Used when a vocab is split off by id change.
  SharedVocab detachedCopy() => SharedVocab(
    audioUrl: audioUrl,
    notes: notes,
    disambiguation: disambiguation,
    cardTargetToNative: SrsCard(
      direction: CardDirection.targetToNative,
      isEnabled: cardTargetToNative.isEnabled,
      backNotes: cardTargetToNative.backNotes,
      frontHint: cardTargetToNative.frontHint,
    ),
    cardNativeToTarget: SrsCard(
      direction: CardDirection.nativeToTarget,
      isEnabled: cardNativeToTarget.isEnabled,
      backNotes: cardNativeToTarget.backNotes,
      frontHint: cardNativeToTarget.frontHint,
    ),
    meta: {...meta},
    alternates: {
      for (final e in alternates.entries) e.key: [...e.value],
    },
  );

  Map<String, dynamic> toJson() => {
    'audioUrl': audioUrl,
    'notes': notes,
    'disambiguation': disambiguation,
    'cardTargetToNative': cardTargetToNative.toJson(),
    'cardNativeToTarget': cardNativeToTarget.toJson(),
    'meta': meta.map((k, v) => MapEntry(k, v.toJson())),
    'alternates': alternates,
  };

  factory SharedVocab.fromJson(Map<String, dynamic> json) => SharedVocab(
    audioUrl: json['audioUrl'] as String?,
    notes: json['notes'] as String? ?? '',
    disambiguation: json['disambiguation'] as String? ?? '',
    cardTargetToNative: SrsCard.fromJson(
      Map<String, dynamic>.from(json['cardTargetToNative'] as Map),
    ),
    cardNativeToTarget: SrsCard.fromJson(
      Map<String, dynamic>.from(json['cardNativeToTarget'] as Map),
    ),
    meta: {
      for (final e in (json['meta'] as Map? ?? const {}).entries)
        e.key as String: DetailMeta.fromJson(
          Map<String, dynamic>.from(e.value as Map),
        ),
    },
    alternates: {
      for (final e in (json['alternates'] as Map? ?? const {}).entries)
        e.key as String: (e.value as List).map((x) => x.toString()).toList(),
    },
  );
}
