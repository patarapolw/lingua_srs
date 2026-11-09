import 'dart:convert';
import 'dart:collection';

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
    this.parts = 0,
    this.blocked = false,
    this.localOnly = false,
  });

  /// Hash of the contents, from [SyncSnapshot.hash]; empty once deleted.
  final String hash;

  /// Milliseconds since the epoch on this device's clock.
  final int updatedAt;
  final bool deleted;

  /// Changed since the last successful push.
  final bool pending;

  /// How many parts the record was split into when last pushed, 0 if it was
  /// not split, so parts it no longer needs can be deleted.
  final int parts;

  /// The server has a version written by a newer app (a newer schema). This
  /// device must not overwrite it until the app is updated.
  final bool blocked;

  /// The server has never had this record: it was made on this device and
  /// not sent yet, and no pull has shown it. Once gone, it is forgotten
  /// instead of sent as a deletion, which would cost a write and change
  /// nothing. False when not known, so the deletion is sent.
  final bool localOnly;

  SyncRecordState copyWith({bool? pending, int? parts, bool? localOnly}) =>
      SyncRecordState(
        hash: hash,
        updatedAt: updatedAt,
        deleted: deleted,
        pending: pending ?? this.pending,
        parts: parts ?? this.parts,
        blocked: blocked,
        localOnly: localOnly ?? this.localOnly,
      );

  Map<String, dynamic> toJson() => {
    'hash': hash,
    'updatedAt': updatedAt,
    if (deleted) 'deleted': true,
    if (pending) 'pending': true,
    if (parts > 0) 'parts': parts,
    if (blocked) 'blocked': true,
    if (localOnly) 'localOnly': true,
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
      parts: json['parts'] is int ? json['parts'] as int : 0,
      blocked: json['blocked'] == true,
      localOnly: json['localOnly'] == true,
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
    Map<SyncRecordKey, Map<int, String>>? heldParts,
    this.cursor = 0,
    this.hasPulled = false,
  }) : deviceId = deviceId ?? const Uuid().v4(),
       _records = records ?? {},
       _heldParts = heldParts ?? {};

  static const _version = 1;

  /// Random, made once per install. Names this device's activity records.
  final String deviceId;

  /// The `cursor` of the last pull: the next pull asks for changes after it.
  int cursor;

  /// This device has pulled from the account at least once since signing
  /// in. Until then its records are stamped with when they last really
  /// changed, so joining an account does not make them all the newest.
  bool hasPulled;

  final Map<SyncRecordKey, SyncRecordState> _records;

  /// Pulled parts of split records whose head has not been joined yet, by
  /// head, then part number, as base64.
  final Map<SyncRecordKey, Map<int, String>> _heldParts;

  /// A read-only view, not a copy: the engine looks records up in loops over
  /// the whole library.
  Map<SyncRecordKey, SyncRecordState> get records =>
      UnmodifiableMapView(_records);

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
  /// [SyncKinds.keptWhenUnused]. A gone record the server never had
  /// ([SyncRecordState.localOnly]) is forgotten, and not returned.
  ///
  /// The first run sees every record as new, which is how data from before
  /// sync was set up gets pushed. Before [hasPulled], a record seen for the
  /// first time is stamped by [stampNew] (when it last really changed, or 0
  /// when that is not known) instead of [now], if given.
  List<SyncRecordKey> track(
    Map<SyncRecordKey, Map<String, dynamic>> snapshot, {
    required int now,
    int Function(SyncRecordKey key, Map<String, dynamic> data)? stampNew,
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
        updatedAt: previous == null && !hasPulled && stampNew != null
            ? stampNew(entry.key, entry.value)
            : stamp(previous),
        parts: previous?.parts ?? 0,
        blocked: previous?.blocked ?? false,
        localOnly: previous == null || previous.localOnly,
      );
      changed.add(entry.key);
    }

    for (final key in _records.keys.toList()) {
      final previous = _records[key]!;
      if (previous.deleted || snapshot.containsKey(key)) continue;
      if (SyncKinds.keptWhenUnused.contains(key.kind)) continue;
      if (previous.localOnly) {
        // Such as a card or lesson merged into a pulled one on a first sync.
        _records.remove(key);
        continue;
      }
      _records[key] = SyncRecordState(
        hash: '',
        updatedAt: stamp(previous),
        deleted: true,
        parts: previous.parts,
        blocked: previous.blocked,
      );
      changed.add(key);
    }
    return changed;
  }

  /// Records that the server accepted [key] as it was at [updatedAt], split
  /// into [parts] parts (0 when not split). A change made since then stays
  /// pending.
  void markPushed(SyncRecordKey key, int updatedAt, {int? parts}) {
    final state = _records[key];
    if (state == null || state.updatedAt != updatedAt) return;
    _records[key] = state.copyWith(
      pending: false,
      parts: parts,
      localOnly: false,
    );
  }

  /// The server has, or may have, a version of [key]: it was pulled, or a
  /// push holding it was started, so a later deletion has to be sent.
  void markOnServer(SyncRecordKey key) {
    final state = _records[key];
    if (state == null || !state.localOnly) return;
    _records[key] = state.copyWith(localOnly: false);
  }

  /// Records a version pulled from the server, and now applied on this
  /// device, as the one this device has: [hash] of its contents as the app
  /// now holds them (empty when [deleted]), not pending.
  void acceptRemote(
    SyncRecordKey key, {
    required String hash,
    required int updatedAt,
    bool deleted = false,
    int parts = 0,
  }) {
    _records[key] = SyncRecordState(
      hash: hash,
      updatedAt: updatedAt,
      deleted: deleted,
      pending: false,
      parts: parts,
    );
  }

  /// Records a local version made at [updatedAt] that has to be pushed, such
  /// as AI discussion messages merged with a pulled version.
  void recordLocal(
    SyncRecordKey key, {
    required String hash,
    required int updatedAt,
  }) {
    final previous = _records[key];
    _records[key] = SyncRecordState(
      hash: hash,
      updatedAt: updatedAt,
      parts: previous?.parts ?? 0,
    );
  }

  /// The server has [key] from a newer app, at [updatedAt]. It is not pushed
  /// over until this app is updated and pulls it again.
  void block(SyncRecordKey key, int updatedAt) {
    final previous = _records[key];
    _records[key] = SyncRecordState(
      hash: previous?.hash ?? '',
      updatedAt: updatedAt,
      deleted: previous?.deleted ?? false,
      pending: false,
      parts: previous?.parts ?? 0,
      blocked: true,
    );
  }

  /// Keeps a pulled part until its head can be joined.
  void holdPart(SyncRecordKey head, int index, List<int> bytes) =>
      _heldParts.putIfAbsent(head, () => {})[index] = base64.encode(bytes);

  /// The held parts of [head], by part number.
  Map<int, List<int>> heldParts(SyncRecordKey head) => {
    for (final entry in (_heldParts[head] ?? const {}).entries)
      entry.key: base64.decode(entry.value),
  };

  /// Forgets the held parts of [head], once joined.
  void releaseParts(SyncRecordKey head) => _heldParts.remove(head);

  /// Forgets every record and the pull cursor, after signing out. The device
  /// id stays, so signing in again does not count this device's activity
  /// twice.
  void reset() {
    _records.clear();
    _heldParts.clear();
    cursor = 0;
    hasPulled = false;
  }

  Map<String, dynamic> toJson() => {
    'version': _version,
    'deviceId': deviceId,
    'cursor': cursor,
    if (hasPulled) 'pulled': true,
    'records': {
      for (final entry in _records.entries)
        entry.key.storageKey: entry.value.toJson(),
    },
    if (_heldParts.isNotEmpty)
      'heldParts': {
        for (final entry in _heldParts.entries)
          entry.key.storageKey: {
            for (final part in entry.value.entries) '${part.key}': part.value,
          },
      },
  };

  factory SyncChangeTracker.fromJson(Map<String, dynamic> json) {
    final version = json['version'];
    final deviceId = json['deviceId'];
    final cursor = json['cursor'];
    final records = json['records'];
    final heldParts = json['heldParts'] ?? const {};
    if (version != _version ||
        deviceId is! String ||
        deviceId.isEmpty ||
        cursor is! int ||
        records is! Map ||
        heldParts is! Map) {
      throw const FormatException('Invalid sync state.');
    }
    return SyncChangeTracker(
      deviceId: deviceId,
      cursor: cursor,
      // Saved before this was kept: a device that had pulled has a cursor.
      hasPulled: json['pulled'] == true || cursor > 0,
      records: {
        for (final entry in records.entries)
          SyncRecordKey.parse(entry.key as String): SyncRecordState.fromJson(
            Map<String, dynamic>.from(entry.value as Map),
          ),
      },
      heldParts: {
        for (final entry in heldParts.entries)
          SyncRecordKey.parse(entry.key as String): {
            for (final part in (entry.value as Map).entries)
              int.parse(part.key as String): part.value as String,
          },
      },
    );
  }
}
