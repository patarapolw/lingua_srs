import 'package:uuid/uuid.dart';

enum CardDirection {
  targetToNative, // e.g. KO -> EN
  nativeToTarget, // e.g. EN -> KO
}

enum SrsRating {
  again, // 1
  hard,  // 2
  good,  // 3
  easy,  // 4
}

enum SrsStatus {
  isNew,
  learning,
  review,
}

class SrsCard {
  final String id;
  final CardDirection direction;
  bool isEnabled;
  int interval; // in days
  int repetitions;
  double easeFactor;
  DateTime dueDate;
  DateTime? lastReviewed;
  SrsStatus status;

  SrsCard({
    String? id,
    required this.direction,
    this.isEnabled = true,
    this.interval = 0,
    this.repetitions = 0,
    this.easeFactor = 2.5,
    DateTime? dueDate,
    this.lastReviewed,
    this.status = SrsStatus.isNew,
  })  : id = id ?? const Uuid().v4(),
        dueDate = dueDate ?? DateTime.now();

  bool get isDue => isEnabled && (status == SrsStatus.isNew || dueDate.isBefore(DateTime.now()) || dueDate.difference(DateTime.now()).inHours <= 12);

  void resetProgress() {
    interval = 0;
    repetitions = 0;
    easeFactor = 2.5;
    dueDate = DateTime.now();
    lastReviewed = null;
    status = SrsStatus.isNew;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'direction': direction.name,
        'isEnabled': isEnabled,
        'interval': interval,
        'repetitions': repetitions,
        'easeFactor': easeFactor,
        'dueDate': dueDate.toIso8601String(),
        'lastReviewed': lastReviewed?.toIso8601String(),
        'status': status.name,
      };

  factory SrsCard.fromJson(Map<String, dynamic> json) => SrsCard(
        id: json['id'] as String?,
        direction: CardDirection.values.firstWhere(
          (e) => e.name == json['direction'],
          orElse: () => CardDirection.targetToNative,
        ),
        isEnabled: json['isEnabled'] as bool? ?? true,
        interval: json['interval'] as int? ?? 0,
        repetitions: json['repetitions'] as int? ?? 0,
        easeFactor: (json['easeFactor'] as num?)?.toDouble() ?? 2.5,
        dueDate: json['dueDate'] != null ? DateTime.parse(json['dueDate'] as String) : null,
        lastReviewed: json['lastReviewed'] != null ? DateTime.parse(json['lastReviewed'] as String) : null,
        status: SrsStatus.values.firstWhere(
          (e) => e.name == json['status'],
          orElse: () => SrsStatus.isNew,
        ),
      );
}
