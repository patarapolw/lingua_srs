import 'package:flutter/material.dart';

import '../services/sync_pairing.dart';

/// Asks before a pairing link signs this device in.
///
/// A link can come from anywhere (a message, a web page, a poster with a QR
/// code), and signing in to someone else's account would sync this device's
/// lessons into it, so the account and the server are shown first. Returns
/// true if the person agrees. [replacing] is the sign-in that would be lost.
Future<bool> confirmPairing(
  BuildContext context,
  SyncPairing pairing, {
  SyncPairing? replacing,
}) async {
  final message = StringBuffer(
    'This device will sign in as ${pairing.email} '
    'on ${pairing.endpoint.authority}.',
  );
  if (replacing != null && replacing != pairing) {
    message.write(' It replaces the sign-in for ${replacing.email}.');
  }
  message.write(' Only continue if you started this pairing yourself.');

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Pair this device?'),
      content: Text(message.toString()),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Pair'),
        ),
      ],
    ),
  );
  return confirmed == true;
}
