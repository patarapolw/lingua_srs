import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../widgets/dialog_messenger.dart';

/// Shows a new recovery code once and waits until the person says they saved
/// it.
///
/// This is the only place the code is shown. It is not kept anywhere: when
/// the dialog closes, the code is gone from the app, and only a new code can
/// replace it. The dialog cannot be dismissed by tapping outside it, so the
/// code is not lost by accident before it was written down.
///
/// [reason] says why a code is shown, above the usual explanation: after a
/// recovery, that the old code has been used.
Future<void> showRecoveryCode(
  BuildContext context,
  String code, {
  String? reason,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    // Its own messenger, so "Recovery code copied" shows on top (#246).
    builder: (context) => DialogMessenger(
      dismissible: false,
      child: _RecoveryCodeDialog(code: code, reason: reason),
    ),
  );
}

/// Asks before a new recovery code replaces the account's current one.
Future<bool> confirmNewRecoveryCode(BuildContext context) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Create a new recovery code?'),
      content: const Text(
        'A recovery code unlocks your synced data if you forget the password '
        'while no device is signed in. A new code replaces the old one: only '
        'the newest code works, so any code you saved before stops working.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Create code'),
        ),
      ],
    ),
  );
  return confirmed == true;
}

class _RecoveryCodeDialog extends StatefulWidget {
  final String code;
  final String? reason;

  const _RecoveryCodeDialog({required this.code, this.reason});

  @override
  State<_RecoveryCodeDialog> createState() => _RecoveryCodeDialogState();
}

class _RecoveryCodeDialogState extends State<_RecoveryCodeDialog> {
  bool _saved = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.code));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Recovery code copied. Save it somewhere safe, then clear it from '
          'the clipboard.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Your recovery code'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.reason != null) ...[
              Text(widget.reason!),
              const SizedBox(height: 12),
            ],
            const Text(
              'Write this code down or keep it in a password manager. If you '
              'forget your password while no device is signed in, it is the '
              'only way to get your synced data back. Nobody can show it '
              'again, the server included.',
            ),
            const SizedBox(height: 16),
            Center(
              child: SelectableText(
                widget.code,
                key: const ValueKey('recoveryCode'),
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontFamily: 'monospace',
                  letterSpacing: 1.5,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Center(
              child: TextButton.icon(
                onPressed: _copy,
                icon: const Icon(Icons.copy),
                label: const Text('Copy code'),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Only the newest recovery code works. Creating a new one in '
              'Settings replaces this one.',
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _saved,
              onChanged: (value) => setState(() => _saved = value ?? false),
              title: const Text('I have saved my recovery code'),
            ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: _saved ? () => Navigator.pop(context) : null,
          child: const Text('Done'),
        ),
      ],
    );
  }
}
