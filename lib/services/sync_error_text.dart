import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'sync_client.dart';

/// A message a person can act on for a failed sync request, instead of the
/// status code and JSON that the server sent.
///
/// A [signedIn] device that gets a 401 holds a sign-in the server no longer
/// accepts. The server gives the same answer for an unknown email and a wrong
/// password, so it cannot say whether the account was deleted or its password
/// was changed on another device, and neither can this message.
String describeSyncError(Object error, {bool signedIn = false}) {
  if (error is SyncException) {
    switch (error.statusCode) {
      case 400 when error.message.contains('invalid_code'):
        // The server gives the same answer whatever the reason, so name
        // them all (#103).
        return "That code didn't confirm this signup. It may be mistyped, "
            'more than 30 minutes old, or cancelled after five wrong tries, '
            'or the account was created again on another device since. '
            'Check the newest email. If its code fails too, create the '
            'account again: a new code is sent once 10 minutes have passed '
            'since the last one.';
      case 401:
        return signedIn
            ? 'The server no longer accepts this sign-in. The account may '
                  'have been deleted, or its password changed on another '
                  'device. Your lessons and progress are still on this '
                  'device. Sign out, then sign in again or create a new '
                  'account.'
            : 'Wrong email or password, or this account does not exist.';
      case 403:
        return 'This account still needs email confirmation.';
      case 429 when error.message.contains('quota_exceeded'):
        // A first sync uploads the whole library, which can pass the
        // account's daily write limit. What got through is kept, and the
        // next sync goes on from there.
        return "This account has used today's sync allowance. Everything "
            'sent so far is saved, and the rest is sent when you sync after '
            'midnight UTC. Your lessons and progress stay on this device.';
      case 429 when error.message.contains('signups_paused'):
        return 'The sync server has sent all the confirmation emails it can '
            'today. Create the account again after midnight UTC.';
      case 429:
        return 'The sync server is busy or has reached its daily limit. '
            'Try again later.';
      case 502:
        return 'The confirmation email could not be sent. Try again later.';
    }
    return error.message;
  }
  if (error is FormatException) return error.message;
  if (error is SocketException ||
      error is TimeoutException ||
      error is http.ClientException) {
    return 'Could not reach the sync server. Check the connection and try '
        'again.';
  }
  return '$error';
}

/// Whether a sync that failed with [error] is worth trying again on its own:
/// the server could not be reached, or it failed on its side. A rejected
/// sign-in or a bad request would fail the same way again.
bool isSyncRetryable(Object error) {
  if (error is SyncException) {
    final status = error.statusCode;
    return status != null && status >= 500;
  }
  return error is SocketException ||
      error is TimeoutException ||
      error is http.ClientException;
}
