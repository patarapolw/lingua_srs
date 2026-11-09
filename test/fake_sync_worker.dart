import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// The Worker's `/v1/account` and `/v1/changes`, in memory: the newest
/// `updatedAt` wins, and every stored change gets the next change number.
class FakeWorker {
  int createdAt = 1000;
  bool rejectSignIn = false;
  final rows = <String, Map<String, dynamic>>{};
  int seq = 0;
  int pushRequests = 0;

  /// Records the account may still write today, as `MAX_WRITES_PER_DAY`;
  /// a batch that would pass it is refused whole with `429 quota_exceeded`.
  int? writesLeft;

  http.Client client() => MockClient(_handle);

  Future<http.Response> _handle(http.Request request) async {
    http.Response json(Object body, [int status = 200]) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );
    if (rejectSignIn) return json({'error': 'invalid_credentials'}, 401);

    switch ((request.method, request.url.path)) {
      case ('GET', '/v1/account'):
        return json({
          'wrappedDataKey': 'unused',
          'kdf': {'alg': 'argon2id'},
          'createdAt': createdAt,
        });
      case ('GET', '/v1/changes'):
        final since = int.parse(request.url.queryParameters['since'] ?? '0');
        final limit = int.parse(request.url.queryParameters['limit'] ?? '500');
        final changed =
            rows.values.where((row) => (row['seq'] as int) > since).toList()
              ..sort((a, b) => (a['seq'] as int).compareTo(b['seq'] as int));
        final page = changed.take(limit).toList();
        return json({
          'records': [for (final row in page) Map.of(row)..remove('seq')],
          'cursor': page.isEmpty ? since : page.last['seq'],
          'hasMore': changed.length > limit,
        });
      case ('POST', '/v1/changes'):
        pushRequests++;
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final count = (body['records'] as List).length;
        if (writesLeft != null) {
          if (count > writesLeft!) {
            return json({'error': 'quota_exceeded'}, 429);
          }
          writesLeft = writesLeft! - count;
        }
        var accepted = 0;
        for (final record in body['records'] as List) {
          final row = Map<String, dynamic>.from(record as Map);
          final key = '${row['kind']}/${row['id']}';
          final existing = rows[key];
          if (existing != null &&
              (existing['updatedAt'] as int) >= (row['updatedAt'] as int)) {
            continue;
          }
          if (row['deleted'] == true) row['data'] = <String, dynamic>{};
          rows[key] = {...row, 'seq': ++seq};
          accepted++;
        }
        return json({'accepted': accepted});
    }
    return json({'error': 'not_found'}, 404);
  }

  bool isDeleted(String kind, String id) =>
      rows['$kind/$id']?['deleted'] == true;
}
