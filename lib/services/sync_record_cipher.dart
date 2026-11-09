import 'dart:convert';
import 'dart:io' show gzip;

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography_plus/cryptography_plus.dart';

import 'sync_client.dart';
import 'sync_pairing.dart';
import 'sync_records.dart';

/// The account's data key, unlocked with the password, for one sign-in. Kept
/// in the keychain so a sync does not have to derive keys from the password.
class SyncDataKey {
  const SyncDataKey({
    required this.endpoint,
    required this.email,
    required this.createdAt,
    required this.key,
    this.authKey,
  });

  final Uri endpoint;
  final String email;

  /// Identifies the account the key belongs to (see `docs/sync.md`); null
  /// from a Worker that does not send it.
  final int? createdAt;
  final List<int> key;

  /// The derived key the server checks at sign-in, kept so a sync does not
  /// derive keys from the password every time. Null in a key saved before it
  /// was kept; the key is then unlocked again.
  final String? authKey;

  /// Whether this key was unlocked for [pairing]'s server and email.
  bool belongsTo(SyncPairing pairing) =>
      endpoint == pairing.endpoint && email == pairing.email;

  Map<String, dynamic> toJson() => {
    'endpoint': endpoint.toString(),
    'email': email,
    'createdAt': createdAt,
    'key': base64Url.encode(key),
    if (authKey != null) 'authKey': authKey,
  };

  factory SyncDataKey.fromJson(Map<String, dynamic> json) {
    final endpoint = json['endpoint'];
    final email = json['email'];
    final createdAt = json['createdAt'];
    final key = json['key'];
    final authKey = json['authKey'];
    if (endpoint is! String ||
        email is! String ||
        (createdAt != null && createdAt is! int) ||
        key is! String ||
        (authKey != null && authKey is! String)) {
      throw const FormatException('Invalid sync data key.');
    }
    final bytes = base64Url.decode(base64Url.normalize(key));
    if (bytes.length != 32) {
      throw const FormatException('Invalid sync data key.');
    }
    return SyncDataKey(
      endpoint: Uri.parse(endpoint),
      email: email,
      createdAt: createdAt as int?,
      key: bytes,
      authKey: authKey as String?,
    );
  }
}

/// What a pulled record holds, once decrypted.
sealed class SyncPayload {
  const SyncPayload(this.key);

  final SyncRecordKey key;
}

/// A whole record.
class SyncContents extends SyncPayload {
  const SyncContents(super.key, {required this.schema, required this.data});

  final int schema;
  final Map<String, dynamic> data;
}

/// A record too large for one server record. Its contents are in [parts]
/// part records; [SyncRecordCipher.join] puts them together.
class SyncSplitHead extends SyncPayload {
  const SyncSplitHead(
    super.key, {
    required this.schema,
    required this.parts,
    required this.sha256,
  });

  final int schema;
  final int parts;

  /// Hash of the whole compressed contents, to check the parts belong to it.
  final String sha256;
}

/// Part [index] (from 1) of the split record [head].
class SyncPart extends SyncPayload {
  const SyncPart(
    super.key, {
    required this.head,
    required this.index,
    required this.bytes,
  });

  final SyncRecordKey head;
  final int index;
  final List<int> bytes;
}

/// One record inside a [SyncPack].
class SyncPackEntry {
  const SyncPackEntry(
    this.key, {
    required this.updatedAt,
    required this.data,
    this.schema = SyncRecordCipher.schema,
  });

  final SyncRecordKey key;
  final int updatedAt;
  final int schema;
  final Map<String, dynamic> data;
}

/// Many records sent as one server record, for a large push. Each keeps its
/// own `updatedAt`; a pulled record replaces another only when it is newer,
/// so an old copy in a pack never wins over a newer one.
class SyncPack extends SyncPayload {
  const SyncPack(super.key, this.entries);

  final List<SyncPackEntry> entries;
}

/// Encrypts records for the server and decrypts them, as "Records" in
/// `docs/sync.md` describes: AES-256-GCM over gzip(JSON) with the data key,
/// the kind and server id as associated data, and server ids that are keyed
/// hashes of the local ids.
class SyncRecordCipher {
  SyncRecordCipher._(this._dataKey, this._idKey);

  /// Contents format version written into every record. A record with a newer
  /// one is from a newer app and must not be overwritten.
  static const schema = 1;

  /// The Worker refuses `data` larger than this, in bytes of JSON.
  static const maxEnvelopeBytes = 32 * 1024;

  /// Compressed bytes per part. Each part is sent as base64 inside the
  /// encrypted JSON, then as base64 again in the envelope, so this leaves
  /// room under [maxEnvelopeBytes].
  static const partBytes = 16 * 1024;

  /// Joins a split record's local id and a part number. Ids never contain
  /// it, so a part cannot have the same id as another record.
  static const partSeparator = '\u0000';

  /// Schema written into packs. It is newer than [schema], so an app from
  /// before packs reports that it needs an update instead of misreading one.
  static const packSchema = 2;

  /// JSON bytes of records first tried in one pack. gzip shrinks a pack of
  /// similar records several times; one that is still too large is halved.
  static const _packJsonBytes = 128 * 1024;

  static const _envelopeVersion = 1;
  static final _aes = AesGcm.with256bits();
  static final _hmac = Hmac.sha256();

  final SecretKey _dataKey;
  final SecretKey _idKey;

  static Future<SyncRecordCipher> create(List<int> dataKey) async {
    if (dataKey.length != 32) {
      throw ArgumentError.value(dataKey.length, 'dataKey', 'must be 32 bytes');
    }
    final idKey = await Hkdf(hmac: _hmac, outputLength: 32).deriveKey(
      secretKey: SecretKey(dataKey),
      nonce: List.filled(32, 0),
      info: utf8.encode('record-id'),
    );
    return SyncRecordCipher._(SecretKey(dataKey), idKey);
  }

  /// The id the server sees for [key]: 43 base64url characters that only a
  /// device with the data key can compute.
  Future<String> recordId(SyncRecordKey key) async {
    final mac = await _hmac.calculateMac(
      utf8.encode('${key.kind}:${key.localId}'),
      secretKey: _idKey,
    );
    return _base64(mac.bytes);
  }

  /// The server records for [key] with [data], changed at [updatedAt]: one
  /// record, or a split head and its parts when it is too large, parts first.
  /// [schemaVersion] is only changed by tests, to act as a newer app.
  Future<List<SyncRecord>> encode(
    SyncRecordKey key,
    Map<String, dynamic> data, {
    required int updatedAt,
    int schemaVersion = schema,
  }) async {
    final compressed = gzip.encode(
      utf8.encode(
        jsonEncode({
          'localId': key.localId,
          'schema': schemaVersion,
          'data': data,
        }),
      ),
    );
    final whole = await _record(key, compressed, updatedAt);
    if (_size(whole) <= maxEnvelopeBytes) return [whole];

    final parts = <SyncRecord>[];
    for (var start = 0; start < compressed.length; start += partBytes) {
      final end = start + partBytes < compressed.length
          ? start + partBytes
          : compressed.length;
      final index = parts.length + 1;
      final partKey = SyncRecordKey(
        key.kind,
        '${key.localId}$partSeparator$index',
      );
      parts.add(
        await _record(
          partKey,
          gzip.encode(
            utf8.encode(
              jsonEncode({
                'localId': partKey.localId,
                'part': base64.encode(compressed.sublist(start, end)),
              }),
            ),
          ),
          updatedAt,
        ),
      );
    }
    final head = await _record(
      key,
      gzip.encode(
        utf8.encode(
          jsonEncode({
            'localId': key.localId,
            'schema': schemaVersion,
            'parts': parts.length,
            'sha256': crypto.sha256.convert(compressed).toString(),
          }),
        ),
      ),
      updatedAt,
    );
    return [...parts, head];
  }

  /// Packs [entries] into as few server records as fit, named [packId]
  /// followed by a number. Returns them with the entries each holds. An entry
  /// too large for a pack of its own is returned in `tooLarge`, to be sent
  /// on its own.
  Future<
    ({
      List<({SyncRecord record, List<SyncPackEntry> entries})> packs,
      List<SyncPackEntry> tooLarge,
    })
  >
  pack(
    String packId,
    List<SyncPackEntry> entries, {
    required int updatedAt,
  }) async {
    final packs = <({SyncRecord record, List<SyncPackEntry> entries})>[];
    final tooLarge = <SyncPackEntry>[];
    final encoded = [for (final entry in entries) _packEntryJson(entry)];

    Future<void> add(int start, int end) async {
      final key = SyncRecordKey(SyncKinds.pack, '$packId/${packs.length}');
      final record = await _record(
        key,
        gzip.encode(
          utf8.encode(
            jsonEncode({
              'localId': key.localId,
              'schema': packSchema,
              'data': {'records': encoded.sublist(start, end)},
            }),
          ),
        ),
        updatedAt,
      );
      if (_size(record) <= maxEnvelopeBytes) {
        packs.add((record: record, entries: entries.sublist(start, end)));
      } else if (end - start == 1) {
        tooLarge.add(entries[start]);
      } else {
        final middle = start + (end - start) ~/ 2;
        await add(start, middle);
        await add(middle, end);
      }
    }

    var start = 0;
    var bytes = 0;
    for (var index = 0; index < entries.length; index++) {
      final size = jsonEncode(encoded[index]).length;
      if (index > start && bytes + size > _packJsonBytes) {
        await add(start, index);
        start = index;
        bytes = 0;
      }
      bytes += size;
    }
    if (start < entries.length) await add(start, entries.length);
    return (packs: packs, tooLarge: tooLarge);
  }

  static Map<String, dynamic> _packEntryJson(SyncPackEntry entry) => {
    'kind': entry.key.kind,
    'localId': entry.key.localId,
    'updatedAt': entry.updatedAt,
    'schema': entry.schema,
    'data': entry.data,
  };

  static SyncPack _readPack(SyncRecordKey key, Map data) {
    final records = data['records'];
    if (records is! List) {
      throw const FormatException('Invalid sync pack.');
    }
    return SyncPack(key, [
      for (final entry in records)
        if (entry is Map &&
            entry['kind'] is String &&
            entry['kind'] != SyncKinds.pack &&
            entry['localId'] is String &&
            entry['updatedAt'] is int &&
            entry['schema'] is int &&
            entry['data'] is Map)
          SyncPackEntry(
            SyncRecordKey(entry['kind'] as String, entry['localId'] as String),
            updatedAt: entry['updatedAt'] as int,
            schema: entry['schema'] as int,
            data: Map<String, dynamic>.from(entry['data'] as Map),
          )
        else
          throw const FormatException('Invalid sync pack entry.'),
    ]);
  }

  /// A deletion of [key], to push.
  Future<SyncRecord> tombstone(
    SyncRecordKey key, {
    required int updatedAt,
  }) async => SyncRecord.tombstone(
    kind: key.kind,
    id: await recordId(key),
    updatedAt: updatedAt,
  );

  /// Decrypts a pulled record that is not deleted. Throws a [FormatException]
  /// for a record this key cannot open, or one that does not match its id.
  Future<SyncPayload> decode(SyncRecord record) async {
    if (record.deleted) {
      throw ArgumentError.value(record.id, 'record', 'is deleted');
    }
    final envelope = record.data;
    final nonce = envelope['n'];
    final cipherText = envelope['c'];
    if (envelope['v'] != _envelopeVersion ||
        nonce is! String ||
        cipherText is! String) {
      throw const FormatException('Unknown sync record format.');
    }
    final List<int> clearText;
    try {
      final bytes = _unbase64(cipherText);
      final macLength = _aes.macAlgorithm.macLength;
      if (bytes.length < macLength) throw const FormatException('Too short.');
      clearText = await _aes.decrypt(
        SecretBox(
          bytes.sublist(0, bytes.length - macLength),
          nonce: _unbase64(nonce),
          mac: Mac(bytes.sublist(bytes.length - macLength)),
        ),
        secretKey: _dataKey,
        aad: _aad(record.kind, record.id),
      );
    } on SecretBoxAuthenticationError {
      throw const FormatException('This sync record cannot be decrypted.');
    }

    final json = jsonDecode(utf8.decode(gzip.decode(clearText)));
    if (json is! Map || json['localId'] is! String) {
      throw const FormatException('Invalid sync record contents.');
    }
    final key = SyncRecordKey(record.kind, json['localId'] as String);
    if (await recordId(key) != record.id) {
      throw const FormatException('A sync record does not match its id.');
    }

    final part = json['part'];
    if (part is String) {
      final split = key.localId.lastIndexOf(partSeparator);
      final index = int.tryParse(key.localId.substring(split + 1));
      if (split < 0 || index == null || index < 1) {
        throw const FormatException('Invalid sync record part.');
      }
      return SyncPart(
        key,
        head: SyncRecordKey(key.kind, key.localId.substring(0, split)),
        index: index,
        bytes: base64.decode(part),
      );
    }

    final schema = json['schema'];
    if (schema is! int) {
      throw const FormatException('Invalid sync record contents.');
    }
    final parts = json['parts'];
    final sha256 = json['sha256'];
    if (parts is int && sha256 is String) {
      return SyncSplitHead(key, schema: schema, parts: parts, sha256: sha256);
    }
    final data = json['data'];
    if (data is! Map) {
      throw const FormatException('Invalid sync record contents.');
    }
    // A pack from a newer app stays contents with its newer schema, which
    // the engine reports as needing an update.
    if (key.kind == SyncKinds.pack && schema == packSchema) {
      return _readPack(key, data);
    }
    return SyncContents(
      key,
      schema: schema,
      data: Map<String, dynamic>.from(data),
    );
  }

  /// Puts a split record together from its [parts], by index. Throws a
  /// [FormatException] when a part is missing or they do not match [head].
  SyncContents join(SyncSplitHead head, Map<int, List<int>> parts) {
    final compressed = <int>[];
    for (var index = 1; index <= head.parts; index++) {
      final bytes = parts[index];
      if (bytes == null) {
        throw FormatException('Part $index of ${head.key} is missing.');
      }
      compressed.addAll(bytes);
    }
    if (crypto.sha256.convert(compressed).toString() != head.sha256) {
      throw FormatException('The parts of ${head.key} do not match.');
    }
    final json = jsonDecode(utf8.decode(gzip.decode(compressed)));
    if (json is! Map ||
        json['localId'] != head.key.localId ||
        json['schema'] is! int ||
        json['data'] is! Map) {
      throw FormatException('Invalid contents for ${head.key}.');
    }
    return SyncContents(
      head.key,
      schema: json['schema'] as int,
      data: Map<String, dynamic>.from(json['data'] as Map),
    );
  }

  Future<SyncRecord> _record(
    SyncRecordKey key,
    List<int> clearText,
    int updatedAt,
  ) async {
    final id = await recordId(key);
    final box = await _aes.encrypt(
      clearText,
      secretKey: _dataKey,
      aad: _aad(key.kind, id),
    );
    return SyncRecord(
      kind: key.kind,
      id: id,
      updatedAt: updatedAt,
      data: {
        'v': _envelopeVersion,
        'n': _base64(box.nonce),
        'c': _base64([...box.cipherText, ...box.mac.bytes]),
      },
    );
  }

  static List<int> _aad(String kind, String id) =>
      utf8.encode('$kind\u0000$id');

  static int _size(SyncRecord record) =>
      utf8.encode(jsonEncode(record.data)).length;

  static String _base64(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');

  static List<int> _unbase64(String text) =>
      base64Url.decode(base64Url.normalize(text));
}
