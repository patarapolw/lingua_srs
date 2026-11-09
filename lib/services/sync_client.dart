import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// One synced row. [data] is opaque to the server. A delete is kept as a
/// tombstone (`deleted` true, empty data) so other devices learn about it.
class SyncRecord {
  final String kind;
  final String id;

  /// Milliseconds since the epoch on the device clock; the newest wins.
  final int updatedAt;
  final bool deleted;
  final Map<String, dynamic> data;

  const SyncRecord({
    required this.kind,
    required this.id,
    required this.updatedAt,
    this.deleted = false,
    this.data = const {},
  });

  const SyncRecord.tombstone({
    required this.kind,
    required this.id,
    required this.updatedAt,
  }) : deleted = true,
       data = const {};

  Map<String, dynamic> toJson() => {
    'kind': kind,
    'id': id,
    'updatedAt': updatedAt,
    'deleted': deleted,
    'data': data,
  };

  factory SyncRecord.fromJson(Object? json) {
    if (json is Map) {
      final kind = json['kind'];
      final id = json['id'];
      final updatedAt = json['updatedAt'];
      final deleted = json['deleted'];
      final data = json['data'];
      if (kind is String &&
          id is String &&
          updatedAt is int &&
          deleted is bool &&
          data is Map) {
        return SyncRecord(
          kind: kind,
          id: id,
          updatedAt: updatedAt,
          deleted: deleted,
          data: Map<String, dynamic>.from(data),
        );
      }
    }
    throw const FormatException('Invalid sync record.');
  }
}

/// Lesson-format text sent by another app (for example the dictionary app),
/// waiting to be previewed and imported.
class InboxItem {
  final String id;
  final String text;
  final int createdAt;

  const InboxItem({
    required this.id,
    required this.text,
    required this.createdAt,
  });

  factory InboxItem.fromJson(Object? json) {
    if (json is Map) {
      final id = json['id'];
      final text = json['text'];
      final createdAt = json['createdAt'];
      if (id is String && text is String && createdAt is int) {
        return InboxItem(id: id, text: text, createdAt: createdAt);
      }
    }
    throw const FormatException('Invalid inbox item.');
  }
}

class SyncPullResult {
  final List<SyncRecord> records;

  /// Pass this as `since` on the next pull.
  final int cursor;
  final bool hasMore;

  const SyncPullResult({
    required this.records,
    required this.cursor,
    required this.hasMore,
  });
}

class SyncException implements Exception {
  final String message;
  final int? statusCode;

  const SyncException(this.message, {this.statusCode});

  /// The key was rejected, so the device needs to be paired again.
  bool get isUnauthorized => statusCode == 401 || statusCode == 403;

  @override
  String toString() => message;
}

/// Talks to the sync Worker described in `docs/sync.md`. The account is
/// identified by HTTP Basic credentials: the [email] and an [authKey] derived
/// from the password on the device, never the password itself. Network
/// failures (`http.ClientException`, `TimeoutException`) are left to the
/// caller.
class SyncClient {
  static const maxPushBatch = 100;

  /// The Worker refuses a push body over 1 MB with `413 too_large`. Packs and
  /// split parts are close to 32 KB each, so a batch is also cut by size,
  /// with room left for the JSON around the records.
  static const maxPushBytes = 900 * 1024;
  static const _timeout = Duration(seconds: 30);

  final Uri endpoint;
  final String email;
  final String _authKey;
  final http.Client _client;

  SyncClient({
    required this.endpoint,
    required this.email,
    required this._authKey,
    http.Client? client,
  }) : _client = client ?? http.Client();

  void close() => _client.close();

  /// Starts account creation. The Worker answers identically for an eligible
  /// and an existing email.
  Future<void> createAccount({
    required String authKey,
    required String wrappedDataKey,
    required Map<String, Object?> kdf,
  }) async {
    await _send(
      'POST',
      ['accounts'],
      body: {
        'email': email,
        'authKey': authKey,
        'wrappedDataKey': wrappedDataKey,
        'kdf': kdf,
      },
      authenticated: false,
    );
  }

  Future<void> confirmAccount({
    required String authKey,
    required String code,
  }) async {
    await _send(
      'POST',
      ['accounts', 'confirm'],
      body: {'email': email, 'authKey': authKey, 'code': code},
      authenticated: false,
    );
  }

  /// The account's wrapped data key and key derivation settings, and
  /// `createdAt`, which identifies the account. Signing in is deterministic,
  /// so an account deleted and created again with the same email and
  /// password accepts the old credentials; only `createdAt` changes. It is
  /// null from a Worker that predates it.
  Future<({String wrappedDataKey, Map<String, dynamic> kdf, int? createdAt})>
  getAccount() async {
    final json = _object(await _send('GET', ['account']));
    final wrappedDataKey = json['wrappedDataKey'];
    final kdf = json['kdf'];
    final createdAt = json['createdAt'];
    if (wrappedDataKey is! String ||
        kdf is! Map ||
        (createdAt != null && createdAt is! int)) {
      throw _invalid();
    }
    return (
      wrappedDataKey: wrappedDataKey,
      kdf: Map<String, dynamic>.from(kdf),
      createdAt: createdAt as int?,
    );
  }

  Future<void> changePassword({
    required String authKey,
    required String wrappedDataKey,
    required Map<String, Object?> kdf,
  }) async {
    await _send(
      'PUT',
      ['account'],
      body: {'authKey': authKey, 'wrappedDataKey': wrappedDataKey, 'kdf': kdf},
    );
  }

  Future<String> createPairingInvite(String payload) async {
    final json = _object(
      await _send('POST', ['account', 'pairing'], body: {'payload': payload}),
    );
    final token = json['token'];
    if (token is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(token)) {
      throw _invalid();
    }
    return token;
  }

  Future<String> redeemPairingInvite(String token) async {
    final json = _object(
      await _send('GET', ['pairings', token], authenticated: false),
    );
    final payload = json['payload'];
    if (payload is! String) throw _invalid();
    return payload;
  }

  Future<void> deleteAccount() async {
    await _send('DELETE', ['account']);
  }

  /// One page of records changed after [since].
  Future<SyncPullResult> pull({int since = 0, int limit = 500}) async {
    final json = _object(
      await _send(
        'GET',
        ['changes'],
        query: {'since': '$since', 'limit': '$limit'},
      ),
    );
    final records = json['records'];
    final cursor = json['cursor'];
    final hasMore = json['hasMore'];
    if (records is! List || cursor is! int || hasMore is! bool) {
      throw _invalid();
    }
    try {
      return SyncPullResult(
        records: records.map(SyncRecord.fromJson).toList(),
        cursor: cursor,
        hasMore: hasMore,
      );
    } on FormatException {
      throw _invalid();
    }
  }

  /// Every record changed after [since], fetched page by page.
  Future<SyncPullResult> pullAll({int since = 0, int limit = 500}) async {
    final records = <SyncRecord>[];
    var cursor = since;
    while (true) {
      final page = await pull(since: cursor, limit: limit);
      records.addAll(page.records);
      if (!page.hasMore) {
        return SyncPullResult(
          records: records,
          cursor: page.cursor,
          hasMore: false,
        );
      }
      if (page.cursor <= cursor) {
        throw const SyncException('Sync server did not advance the cursor.');
      }
      cursor = page.cursor;
    }
  }

  /// Sends [records] in batches of at most [maxPushBatch] records and
  /// [maxPushBytes] of JSON. Returns how many the server kept; an older copy
  /// of a record it already has newer is not kept. [onBatch] is told how many
  /// records the server has taken so far after each batch, so a push stopped
  /// partway, such as by the daily write limit, keeps what got through.
  Future<int> push(
    List<SyncRecord> records, {
    void Function(int sent)? onBatch,
  }) async {
    var accepted = 0;
    var start = 0;
    while (start < records.length) {
      final batch = <Map<String, dynamic>>[];
      var bytes = 0;
      var end = start;
      while (end < records.length && batch.length < maxPushBatch) {
        final json = records[end].toJson();
        final size = utf8.encode(jsonEncode(json)).length + 1;
        if (batch.isNotEmpty && bytes + size > maxPushBytes) break;
        batch.add(json);
        bytes += size;
        end++;
      }
      final json = _object(
        await _send('POST', ['changes'], body: {'records': batch}),
      );
      final count = json['accepted'];
      if (count is! int) throw _invalid();
      accepted += count;
      start = end;
      onBatch?.call(end);
    }
    return accepted;
  }

  Future<List<InboxItem>> fetchInbox() async {
    final json = _object(await _send('GET', ['inbox']));
    final items = json['items'];
    if (items is! List) throw _invalid();
    try {
      return items.map(InboxItem.fromJson).toList();
    } on FormatException {
      throw _invalid();
    }
  }

  /// Removes an inbox item once it has been imported or dismissed.
  Future<void> ackInbox(String id) async {
    await _send('DELETE', ['inbox', id]);
  }

  Future<Object?> _send(
    String method,
    List<String> path, {
    Map<String, String>? query,
    Object? body,
    bool authenticated = true,
  }) async {
    final uri = endpoint.replace(
      pathSegments: [
        ...endpoint.pathSegments.where((segment) => segment.isNotEmpty),
        'v1',
        ...path,
      ],
      queryParameters: query,
    );
    final credentials = base64.encode(utf8.encode('$email:$_authKey'));
    final request = http.Request(method, uri)
      ..headers['Accept'] = 'application/json';
    if (authenticated) {
      request.headers['Authorization'] = 'Basic $credentials';
    }
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }

    final streamed = await _client.send(request).timeout(_timeout);
    final response = await http.Response.fromStream(streamed).timeout(_timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw SyncException(
        'Sync request failed (${response.statusCode}): ${response.body}',
        statusCode: response.statusCode,
      );
    }
    if (response.body.isEmpty) return null;
    try {
      return jsonDecode(response.body);
    } on FormatException {
      throw _invalid();
    }
  }

  static Map<String, dynamic> _object(Object? json) {
    if (json is Map) return Map<String, dynamic>.from(json);
    throw _invalid();
  }

  static SyncException _invalid() =>
      const SyncException('Sync server returned an invalid response.');
}
