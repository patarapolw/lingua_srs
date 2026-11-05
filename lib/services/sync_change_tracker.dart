import 'package:uuid/uuid.dart';

import 'sync_records.dart';

/// What this device knows about one record: a hash of its contents when it
/// was last seen, when it last changed, and whether that change still has to
/// be pushed.
class SyncRecordState {
  const SyncRecordState({
    required this.hash,
    required this.updatedAt,
    this.deleted = false,
    this.pending = true,
  });

  /// Hash of the contents, from [SyncSnapshot.hash]; empty once deleted.
  final String hash;

  /// Milliseconds since the epoch on this device's clock.
  final int updatedAt;
  final bool deleted;

  /// Changed since the last successful push.
  final bool pending;

  SyncRecordState copyWith({bool? pending}) => SyncRecordState(
    hash: hash,
    updatedAt: updatedAt,
    deleted: deleted,
    pending: pending ?? this.pending,
  );

  Map<String, dynamic> toJson() => {
    'hash': hash,
    'updatedAt': updatedAt,
    if (deleted) 'deleted': true,
    if (pending) 'pending': true,
  };

  factory SyncRecordState.fromJson(Map<String, dynamic> json) {
    final hash = json['hash'];
    final updatedAt = json['updatedAt'];
    if (hash is! String || updatedAt is! int) {
      throw const FormatException('Invalid sync record state.');
    }
    return SyncRecordState(
      hash: hash,
      updatedAt: updatedAt,
      deleted: json['deleted'] == true,
      pending: json['pending'] == true,
    );
  }
}

/// Notices which records changed on this device, by comparing the app's state
/// with what it was the last time, and remembers what still has to be pushed
/// and where the last pull ended. Kept on the device only, never in a backup.
///
/// Comparing contents, instead of marking changes where the app edits data,
/// means no edit can be missed. A record's `updatedAt` is when the change was
/// noticed, so [track] should run soon after edits.
class SyncChangeTracker {
  SyncChangeTracker({
    String? deviceId,
    Map<SyncRecordKey, SyncRecordState>? records,
    this.cursor = 0,
  }) : deviceId = deviceId ?? const Uuid().v4(),
       _records = records ?? {};

  static const _version = 1;

  /// Random, made once per install. Names this device's activity records.
  final String deviceId;

  /// The `cursor` of the last pull: the next pull asks for changes after it.
  int cursor;

  final Map<SyncRecordKey, SyncRecordState> _records;

  Map<SyncRecordKey, SyncRecordState> get records => Map.unmodifiable(_records);

  /// Records changed since the last push, oldest change first.
  List<SyncRecordKey> get pending {
    final keys = [
      for (final entry in _records.entries)
        if (entry.value.pending) entry.key,
    ];
    keys.sort(
      (a, b) => _records[a]!.updatedAt.compareTo(_records[b]!.updatedAt),
    );
    return keys;
  }

  /// Compares [snapshot] (from [SyncSnapshot.build]) with what was seen
  /// before, at [now] in milliseconds. New and changed records, and records
  /// that are gone, become pending, and are returned. A gone record is kept
  /// as deleted so the deletion syncs, except for kinds in
  /// [SyncKinds.keptWhenUnused].
  ///
  /// The first run sees every record as new, which is how data from before
  /// sync was set up gets pushed.
  List<SyncRecordKey> track(
    Map<SyncRecordKey, Map<String, dynamic>> snapshot, {
    required int now,
  }) {
    final changed = <SyncRecordKey>[];
    int stamp(SyncRecordState? previous) =>
        // A clock set back must not make a change older than the last one.
        previous != null && previous.updatedAt >= now
        ? previous.updatedAt + 1
        : now;

    for (final entry in snapshot.entries) {
      final hash = SyncSnapshot.hash(entry.value);
      final previous = _records[entry.key];
      if (previous != null && !previous.deleted && previous.hash == hash) {
        continue;
      }
      _records[entry.key] = SyncRecordState(
        hash: hash,
        updatedAt: stamp(previous),
      );
      changed.add(entry.key);
    }

    for (final key in _records.keys.toList()) {
      final previous = _records[key]!;
      if (previous.deleted || snapshot.containsKey(key)) continue;
      if (SyncKinds.keptWhenUnused.contains(key.kind)) continue;
      _records[key] = SyncRecordState(
        hash: '',
        updatedAt: stamp(previous),
        deleted: true,
      );
      changed.add(key);
    }
    return changed;
  }

  /// Records that the server accepted [key] as it was at [updatedAt]. A
  /// change made since then stays pending.
  void markPushed(SyncRecordKey key, int updatedAt) {
    final state = _records[key];
    if (state == null || state.updatedAt != updatedAt) return;
    _records[key] = state.copyWith(pending: false);
  }

  /// Forgets every record and the pull cursor, after signing out. The device
  /// id stays, so signing in again does not count this device's activity
  /// twice.
  void reset() {
    _records.clear();
    cursor = 0;
  }

  Map<String, dynamic> toJson() => {
    'version': _version,
    'deviceId': deviceId,
    'cursor': cursor,
    'records': {
      for (final entry in _records.entries)
        entry.key.storageKey: entry.value.toJson(),
    },
  };

  factory SyncChangeTracker.fromJson(Map<String, dynamic> json) {
    final version = json['version'];
    final deviceId = json['deviceId'];
    final cursor = json['cursor'];
    final records = json['records'];
    if (version != _version ||
        deviceId is! String ||
        deviceId.isEmpty ||
        cursor is! int ||
        records is! Map) {
      throw const FormatException('Invalid sync state.');
    }
    return SyncChangeTracker(
      deviceId: deviceId,
      cursor: cursor,
      records: {
        for (final entry in records.entries)
          SyncRecordKey.parse(entry.key as String): SyncRecordState.fromJson(
            Map<String, dynamic>.from(entry.value as Map),
          ),
      },
    );
  }
}
