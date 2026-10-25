import 'package:uuid/uuid.dart';

enum CardDirection {
  targetToNative, // e.g. KO -> EN
  nativeToTarget, // e.g. EN -> KO
}

enum SrsRating {
  again, // 1
  hard, // 2
  good, // 3
  easy, // 4
}

enum SrsStatus { isNew, learning, review }

class SrsCard {
  final String id;
  final CardDirection direction;
  bool isEnabled;
  String backNotes;
  String frontHint;
  int interval; // in days
  int repetitions;
  double easeFactor;
  DateTime dueDate;
  DateTime? lastReviewed;
  SrsStatus status;
  int lapses;
  DateTime? lastMistakeDate;
  SrsRating? lastRating;
  DateTime? mistakesClearedAt;

  /// When the card was first reviewed; null while it is still new. Drives the
  /// rolling new-cards-per-day limit.
  DateTime? introducedAt;

  SrsCard({
    String? id,
    required this.direction,
    this.isEnabled = true,
    this.backNotes = '',
    this.frontHint = '',
    this.interval = 0,
    this.repetitions = 0,
    this.easeFactor = 2.5,
    DateTime? dueDate,
    this.lastReviewed,
    this.status = SrsStatus.isNew,
    this.lapses = 0,
    this.lastMistakeDate,
    this.lastRating,
    this.mistakesClearedAt,
    this.introducedAt,
  }) : id = id ?? const Uuid().v4(),
       dueDate = dueDate ?? DateTime.now();

  /// Never reviewed. New cards are not "due": they have their own daily limit.
  bool get isNewCard => isEnabled && status == SrsStatus.isNew;

  /// Already learned or being learned, and scheduled for now or earlier.
  bool get isDue =>
      isEnabled &&
      status != SrsStatus.isNew &&
      !dueDate.isAfter(DateTime.now());

  /// Can be studied now: due, or new.
  bool get isAvailable => isNewCard || isDue;

  bool get hasRecentMistake {
    if (!isEnabled) return false;
    bool counts(DateTime d) =>
        mistakesClearedAt == null || d.isAfter(mistakesClearedAt!);
    if (lastMistakeDate != null && counts(lastMistakeDate!)) {
      final hours = DateTime.now().difference(lastMistakeDate!).inHours;
      if (hours <= 48 &&
          (lastRating == SrsRating.again || status == SrsStatus.learning)) {
        return true;
      }
    }
    if (status == SrsStatus.learning &&
        lastReviewed != null &&
        counts(lastReviewed!)) {
      final hours = DateTime.now().difference(lastReviewed!).inHours;
      if (hours <= 48) return true;
    }
    return false;
  }

  void resetProgress() {
    interval = 0;
    repetitions = 0;
    easeFactor = 2.5;
    dueDate = DateTime.now();
    lastReviewed = null;
    status = SrsStatus.isNew;
    lapses = 0;
    lastMistakeDate = null;
    lastRating = null;
    mistakesClearedAt = null;
    introducedAt = null;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'direction': direction.name,
    'isEnabled': isEnabled,
    'backNotes': backNotes,
    'frontHint': frontHint,
    'interval': interval,
    'repetitions': repetitions,
    'easeFactor': easeFactor,
    'dueDate': dueDate.toIso8601String(),
    'lastReviewed': lastReviewed?.toIso8601String(),
    'status': status.name,
    'lapses': lapses,
    'lastMistakeDate': lastMistakeDate?.toIso8601String(),
    'lastRating': lastRating?.name,
    'mistakesClearedAt': mistakesClearedAt?.toIso8601String(),
    'introducedAt': introducedAt?.toIso8601String(),
  };

  factory SrsCard.fromJson(Map<String, dynamic> json) => SrsCard(
    mistakesClearedAt: json['mistakesClearedAt'] != null
        ? DateTime.parse(json['mistakesClearedAt'] as String)
        : null,
    introducedAt: json['introducedAt'] != null
        ? DateTime.parse(json['introducedAt'] as String)
        : null,
    id: json['id'] as String?,
    direction: CardDirection.values.firstWhere(
      (e) => e.name == json['direction'],
      orElse: () => CardDirection.targetToNative,
    ),
    isEnabled: json['isEnabled'] as bool? ?? true,
    backNotes: json['backNotes'] as String? ?? '',
    frontHint: json['frontHint'] as String? ?? '',
    interval: json['interval'] as int? ?? 0,
    repetitions: json['repetitions'] as int? ?? 0,
    easeFactor: (json['easeFactor'] as num?)?.toDouble() ?? 2.5,
    dueDate: json['dueDate'] != null
        ? DateTime.parse(json['dueDate'] as String)
        : null,
    lastReviewed: json['lastReviewed'] != null
        ? DateTime.parse(json['lastReviewed'] as String)
        : null,
    status: SrsStatus.values.firstWhere(
      (e) => e.name == json['status'],
      orElse: () => SrsStatus.isNew,
    ),
    lapses: json['lapses'] as int? ?? 0,
    lastMistakeDate: json['lastMistakeDate'] != null
        ? DateTime.parse(json['lastMistakeDate'] as String)
        : null,
    lastRating: json['lastRating'] != null
        ? SrsRating.values.firstWhere(
            (e) => e.name == json['lastRating'],
            orElse: () => SrsRating.again,
          )
        : null,
  );
}
