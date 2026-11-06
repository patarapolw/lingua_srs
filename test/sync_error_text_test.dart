import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:lingua_srs/services/sync_client.dart';
import 'package:lingua_srs/services/sync_error_text.dart';

SyncException _error(int status, [String body = '{"error":"x"}']) =>
    SyncException('Sync request failed ($status): $body', statusCode: status);

void main() {
  group('describeSyncError', () {
    test('a 401 when typing a sign-in is a wrong email or password', () {
      final text = describeSyncError(_error(401));

      expect(text, contains('Wrong email or password'));
      expect(text, contains('does not exist'));
    });

    test('a 401 on a signed-in device says the sign-in was rejected', () {
      final text = describeSyncError(_error(401), signedIn: true);

      // The server cannot tell a deleted account from a changed password.
      expect(text, contains('no longer accepts this sign-in'));
      expect(text, contains('deleted'));
      expect(text, contains('password changed on another device'));
      // And it reassures that nothing was lost.
      expect(text, contains('still on this device'));
    });

    test('shows what the person can do, not the status or the JSON', () {
      for (final status in [400, 401, 403, 429, 502]) {
        final text = describeSyncError(_error(status, '{"error":"secret"}'));
        if (status != 400) {
          expect(text, isNot(contains('{')), reason: 'status $status');
          expect(text, isNot(contains('Sync request failed')));
        }
      }
      expect(describeSyncError(_error(403)), contains('email confirmation'));
      expect(describeSyncError(_error(429)), contains('Try again later'));
      expect(describeSyncError(_error(502)), contains('email could not'));
    });

    test('a refused code is a wrong or expired code', () {
      final text = describeSyncError(_error(400, '{"error":"invalid_code"}'));

      expect(text, contains('wrong or has expired'));
    });

    test('other errors keep the message from the client', () {
      const error = SyncException('Sync request failed (500): oops');

      expect(describeSyncError(error), error.message);
      expect(
        describeSyncError(const FormatException('Bad link.')),
        'Bad link.',
      );
      expect(describeSyncError(StateError('boom')), contains('boom'));
    });

    test('network problems say the server could not be reached', () {
      for (final error in [
        const SocketException('no route'),
        TimeoutException('too slow'),
        http.ClientException('closed'),
      ]) {
        expect(describeSyncError(error), contains('Could not reach'));
      }
    });
  });

  group('isSyncRetryable', () {
    test('a lost connection or a failing server is tried again', () {
      expect(isSyncRetryable(const SocketException('offline')), isTrue);
      expect(isSyncRetryable(TimeoutException('slow')), isTrue);
      expect(isSyncRetryable(_error(503)), isTrue);
    });

    test('a rejected sign-in or a bad request is not', () {
      expect(isSyncRetryable(_error(401)), isFalse);
      expect(isSyncRetryable(_error(400)), isFalse);
      expect(isSyncRetryable(const FormatException('bad')), isFalse);
    });
  });
}
