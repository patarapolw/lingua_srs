import 'sync_change_tracker.dart';
import 'sync_client.dart';
import 'sync_record_cipher.dart';
import 'sync_records.dart';

/// Where the engine reads the app's records and applies pulled ones.
abstract interface class SyncRecordStore {
  /// The contents of every synced record as the app holds them now, with
  /// this device's activity under [deviceId] (see [SyncSnapshot.build]).
  Map<SyncRecordKey, Map<String, dynamic>> snapshot(String deviceId);

  /// Applies pulled records: new contents, or null for a deleted record.
  Future<void> apply(Map<SyncRecordKey, Map<String, dynamic>?> changes);
}

enum SyncOutcome {
  /// Pulled and pushed everything.
  synced,

  /// The server no longer accepts this sign-in: the password was changed on
  /// another device, or the account was deleted. Nothing was changed.
  signInRejected,

  /// The account was deleted and created again with the same email and
  /// password. Nothing was changed; the person has to choose what to do.
  accountChanged,
}

class SyncResult {
  const SyncResult(
    this.outcome, {
    this.pulled = 0,
    this.pushed = 0,
    this.needsAppUpdate = const [],
    this.unreadable = 0,
  });

  final SyncOutcome outcome;

  /// Records changed on this device by the pull.
  final int pulled;

  /// Records sent to the server, not counting parts and old parts deleted.
  final int pushed;

  /// Records written by a newer version of the app, left as they are here
  /// and not overwritten on the server.
  final List<SyncRecordKey> needsAppUpdate;

  /// Pulled records that could not be decrypted or put together.
  final int unreadable;
}

/// One pulled record, decrypted.
class _Remote {
  const _Remote({
    required this.updatedAt,
    this.data,
    this.schema = SyncRecordCipher.schema,
    this.parts = 0,
  });

  final int updatedAt;

  /// Null when deleted.
  final Map<String, dynamic>? data;
  final int schema;
  final int parts;
}

/// Pulls and pushes the records of one account, as "Records" in
/// `docs/sync.md` describes. Each [sync] checks that the account is still the
/// one the data key belongs to, notes local changes, pulls, resolves each
/// record (the newer `updatedAt` wins; AI discussions are merged), applies
/// what came in, and pushes what is left.
class SyncEngine {
  SyncEngine({
    required this.client,
    required this.cipher,
    required this.store,
    required this.tracker,
    required this.accountCreatedAt,
    required this.save,
    int Function()? clock,
  }) : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final SyncClient client;
  final SyncRecordCipher cipher;
  final SyncRecordStore store;
  final SyncChangeTracker tracker;

  /// The `createdAt` of the account the data key was unlocked for.
  final int? accountCreatedAt;

  /// Saves [tracker]; called after the pull and after the push, so a failed
  /// push does not repeat the pull.
  final Future<void> Function() save;
  final int Function() _clock;

  Future<SyncResult> sync() async {
    try {
      final account = await client.getAccount();
      if (accountCreatedAt != null &&
          account.createdAt != null &&
          account.createdAt != accountCreatedAt) {
        return const SyncResult(SyncOutcome.accountChanged);
      }

      tracker.track(store.snapshot(tracker.deviceId), now: _clock());
      final pulled = await _pull();
      final pushed = await _push();
      return SyncResult(
        SyncOutcome.synced,
        pulled: pulled.changed,
        pushed: pushed,
        needsAppUpdate: pulled.needsAppUpdate,
        unreadable: pulled.unreadable,
      );
    } on SyncException catch (error) {
      if (error.isUnauthorized) {
        return const SyncResult(SyncOutcome.signInRejected);
      }
      rethrow;
    }
  }

  Future<({int changed, List<SyncRecordKey> needsAppUpdate, int unreadable})>
  _pull() async {
    final page = await client.pullAll(since: tracker.cursor);
    final local = store.snapshot(tracker.deviceId);
    final ids = await _knownIds(local.keys);
    final incoming = <SyncRecordKey, _Remote>{};
    var unreadable = 0;

    for (final record in page.records) {
      if (record.deleted) {
        final key = ids[record.id];
        if (key != null) incoming[key] = _Remote(updatedAt: record.updatedAt);
        continue;
      }
      final SyncPayload payload;
      try {
        payload = await cipher.decode(record);
      } on FormatException {
        unreadable++;
        continue;
      }
      switch (payload) {
        case SyncPart():
          tracker.holdPart(payload.head, payload.index, payload.bytes);
        case SyncSplitHead():
          final SyncContents joined;
          try {
            joined = cipher.join(payload, tracker.heldParts(payload.key));
          } on FormatException {
            tracker.releaseParts(payload.key);
            unreadable++;
            continue;
          }
          tracker.releaseParts(payload.key);
          incoming[payload.key] = _Remote(
            updatedAt: record.updatedAt,
            data: joined.data,
            schema: joined.schema,
            parts: payload.parts,
          );
        case SyncContents():
          incoming[payload.key] = _Remote(
            updatedAt: record.updatedAt,
            data: payload.data,
            schema: payload.schema,
          );
      }
    }

    final changes = <SyncRecordKey, Map<String, dynamic>?>{};
    final merged = <SyncRecordKey, int>{};
    final needsAppUpdate = <SyncRecordKey>[];
    for (final entry in incoming.entries) {
      final key = entry.key;
      final remote = entry.value;
      final state = tracker.records[key];

      // This device's own push coming back, or a version it already has.
      if (state != null &&
          !state.pending &&
          !state.blocked &&
          state.updatedAt == remote.updatedAt) {
        continue;
      }
      if (remote.schema > SyncRecordCipher.schema) {
        tracker.block(key, remote.updatedAt);
        needsAppUpdate.add(key);
        continue;
      }
      if (state != null && state.pending && !state.blocked) {
        final mine = local[key];
        if (key.kind == SyncKinds.discussion &&
            remote.data != null &&
            mine != null) {
          changes[key] = mergeDiscussions(mine, remote.data!);
          merged[key] = [
            _clock(),
            remote.updatedAt + 1,
            state.updatedAt + 1,
          ].reduce((a, b) => a > b ? a : b);
          continue;
        }
        // This device's change is newer, so it is pushed and wins there too.
        if (state.updatedAt > remote.updatedAt) continue;
      }
      if (remote.data == null && (state == null || state.deleted)) {
        tracker.acceptRemote(
          key,
          hash: '',
          updatedAt: remote.updatedAt,
          deleted: true,
        );
        continue;
      }
      changes[key] = remote.data;
    }

    if (changes.isNotEmpty) await store.apply(changes);
    final after = store.snapshot(tracker.deviceId);
    for (final key in changes.keys) {
      final data = after[key];
      final hash = data == null ? '' : SyncSnapshot.hash(data);
      final mergedAt = merged[key];
      if (mergedAt != null) {
        tracker.recordLocal(key, hash: hash, updatedAt: mergedAt);
      } else {
        tracker.acceptRemote(
          key,
          hash: hash,
          updatedAt: incoming[key]!.updatedAt,
          deleted: data == null,
          parts: incoming[key]!.parts,
        );
      }
    }
    tracker.cursor = page.cursor;
    await save();
    return (
      changed: changes.length,
      needsAppUpdate: needsAppUpdate,
      unreadable: unreadable,
    );
  }

  Future<int> _push() async {
    final snapshot = store.snapshot(tracker.deviceId);
    // Applying pulled records can change others, such as vocab added with a
    // lesson; those are pushed too.
    tracker.track(snapshot, now: _clock());

    final records = <SyncRecord>[];
    final sent = <({SyncRecordKey key, int updatedAt, int parts})>[];
    for (final key in tracker.pending) {
      final state = tracker.records[key]!;
      if (state.blocked) continue;
      var parts = 0;
      if (state.deleted) {
        records.add(await cipher.tombstone(key, updatedAt: state.updatedAt));
      } else {
        final data = snapshot[key];
        if (data == null) continue;
        final encoded = await cipher.encode(
          key,
          data,
          updatedAt: state.updatedAt,
        );
        parts = encoded.length > 1 ? encoded.length - 1 : 0;
        records.addAll(encoded);
      }
      for (var index = parts + 1; index <= state.parts; index++) {
        records.add(
          await cipher.tombstone(
            partKey(key, index),
            updatedAt: state.updatedAt,
          ),
        );
      }
      sent.add((key: key, updatedAt: state.updatedAt, parts: parts));
    }

    if (records.isNotEmpty) await client.push(records);
    for (final record in sent) {
      tracker.markPushed(record.key, record.updatedAt, parts: record.parts);
    }
    await save();
    return sent.length;
  }

  /// Server ids of every record this device knows, to recognize pulled
  /// deletions, which carry no contents.
  Future<Map<String, SyncRecordKey>> _knownIds(
    Iterable<SyncRecordKey> local,
  ) async {
    final keys = {...tracker.records.keys, ...local};
    return {for (final key in keys) await cipher.recordId(key): key};
  }

  /// The local key of part [index] of [key].
  static SyncRecordKey partKey(SyncRecordKey key, int index) => SyncRecordKey(
    key.kind,
    '${key.localId}${SyncRecordCipher.partSeparator}$index',
  );

  /// Both sides' messages of one AI discussion, each once, by time. Messages
  /// without a time keep their place before the timed ones.
  static Map<String, dynamic> mergeDiscussions(
    Map<String, dynamic> mine,
    Map<String, dynamic> theirs,
  ) {
    final seen = <String>{};
    final messages = <({int order, Map<String, dynamic> message})>[];
    for (final side in [mine, theirs]) {
      final list = side['messages'];
      if (list is! List) continue;
      for (final message in list) {
        if (message is! Map) continue;
        final json = Map<String, dynamic>.from(message);
        if (seen.add(SyncSnapshot.hash(json))) {
          messages.add((order: messages.length, message: json));
        }
      }
    }
    int time(Map<String, dynamic> message) {
      final createdAt = message['createdAt'];
      final parsed = createdAt is String ? DateTime.tryParse(createdAt) : null;
      return parsed?.millisecondsSinceEpoch ?? -1;
    }

    messages.sort((a, b) {
      final byTime = time(a.message).compareTo(time(b.message));
      return byTime != 0 ? byTime : a.order.compareTo(b.order);
    });
    return {
      ...mine,
      'messages': [for (final entry in messages) entry.message],
    };
  }
}
