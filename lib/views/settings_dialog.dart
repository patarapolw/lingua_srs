import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:provider/provider.dart';

import '../providers/app_provider.dart';
import '../services/backup_service.dart';
import '../services/sync_account_service.dart';
import '../services/sync_client.dart';
import '../services/sync_error_text.dart';
import '../services/sync_pairing.dart';
import '../services/sync_password_policy.dart';
import '../services/web_demo.dart';
import '../widgets/ai_settings_fields.dart';
import '../widgets/dialog_messenger.dart';
import '../widgets/icon_switch.dart';
import 'pairing_confirmation.dart';
import 'recovery_code_dialog.dart';

class SettingsDialog extends StatelessWidget {
  final bool isDarkMode;
  final VoidCallback? onToggleTheme;
  final SyncAccountService? syncAccountService;

  const SettingsDialog({
    super.key,
    this.isDarkMode = false,
    this.onToggleTheme,
    this.syncAccountService,
  });

  /// The settings live below their own messenger, so that their snackbars
  /// show on top of the dialog (#246).
  @override
  Widget build(BuildContext context) => DialogMessenger(
    child: _SettingsDialogBody(
      isDarkMode: isDarkMode,
      onToggleTheme: onToggleTheme,
      syncAccountService: syncAccountService,
    ),
  );
}

class _SettingsDialogBody extends StatefulWidget {
  final bool isDarkMode;
  final VoidCallback? onToggleTheme;
  final SyncAccountService? syncAccountService;

  const _SettingsDialogBody({
    required this.isDarkMode,
    required this.onToggleTheme,
    required this.syncAccountService,
  });

  @override
  State<_SettingsDialogBody> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<_SettingsDialogBody> {
  late final TextEditingController _apiKeyController;
  late final TextEditingController _aiInstructionsController;
  late final TextEditingController _maxReviewsController;
  late final TextEditingController _maxNewCardsController;
  final _syncEmailController = TextEditingController();
  final _syncPasswordController = TextEditingController();
  final _syncConfirmPasswordController = TextEditingController();
  final _syncConfirmationCodeController = TextEditingController();
  final _syncRecoveryCodeController = TextEditingController();
  final _newSyncPasswordController = TextEditingController();
  final _newSyncConfirmPasswordController = TextEditingController();
  late bool _darkMode = widget.isDarkMode;
  bool _obscureSyncPassword = true;
  bool _obscureSyncConfirmPassword = true;
  bool _obscureNewSyncPassword = true;
  bool _obscureNewSyncConfirmPassword = true;
  bool _creatingSyncAccount = false;
  bool _awaitingSyncConfirmation = false;
  bool _recoveringSyncAccount = false;
  bool _changingSyncPassword = false;
  bool _saving = false;
  String? _maxReviewsError;
  String? _maxNewCardsError;
  String? _syncError;
  SyncAccountService get _syncAccounts =>
      widget.syncAccountService ?? SyncAccountService();
  String? get _newAccountPasswordError =>
      SyncPasswordPolicy.validateLocally(_syncPasswordController.text);
  String? get _changedPasswordError =>
      SyncPasswordPolicy.validateLocally(_newSyncPasswordController.text);
  bool get _canCreateAccount =>
      _newAccountPasswordError == null &&
      _syncPasswordController.text == _syncConfirmPasswordController.text;

  /// Whether the signed-out form asks for a new password, with its
  /// confirmation and rules: creating an account, or recovering one.
  bool get _choosingNewPassword =>
      (_creatingSyncAccount && !_awaitingSyncConfirmation) ||
      _recoveringSyncAccount;
  bool get _canRecoverAccount =>
      _canCreateAccount && _syncRecoveryCodeController.text.trim().isNotEmpty;
  bool get _hasConfirmationCode =>
      _syncConfirmationCodeController.text.length == 8;
  bool get _canChangePassword =>
      _changedPasswordError == null &&
      _newSyncPasswordController.text == _newSyncConfirmPasswordController.text;

  Widget _passwordVisibilityButton(bool obscureText, VoidCallback onPressed) =>
      IconButton(
        tooltip: obscureText ? 'Show password' : 'Hide password',
        icon: Icon(obscureText ? Icons.visibility : Icons.visibility_off),
        onPressed: onPressed,
      );

  @override
  void initState() {
    super.initState();
    final provider = context.read<AppProvider>();
    _apiKeyController = TextEditingController(text: provider.deepSeekApiKey);
    _aiInstructionsController = TextEditingController(
      text: provider.aiInstructions,
    );
    _maxReviewsController = TextEditingController(
      text: '${provider.maxReviews24h > 0 ? provider.maxReviews24h : 0}',
    );
    _maxNewCardsController = TextEditingController(
      text: '${provider.maxNewCards24h > 0 ? provider.maxNewCards24h : 0}',
    );
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    _aiInstructionsController.dispose();
    _maxReviewsController.dispose();
    _maxNewCardsController.dispose();
    _syncEmailController.dispose();
    _syncPasswordController.dispose();
    _syncConfirmPasswordController.dispose();
    _syncConfirmationCodeController.dispose();
    _syncRecoveryCodeController.dispose();
    _newSyncPasswordController.dispose();
    _newSyncConfirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    const limitError = 'Enter a whole number, or 0 for unlimited.';
    final maxReviews = int.tryParse(_maxReviewsController.text.trim());
    final maxNewCards = int.tryParse(_maxNewCardsController.text.trim());
    if (maxReviews == null ||
        maxReviews < 0 ||
        maxNewCards == null ||
        maxNewCards < 0) {
      setState(() {
        _maxReviewsError = maxReviews == null || maxReviews < 0
            ? limitError
            : null;
        _maxNewCardsError = maxNewCards == null || maxNewCards < 0
            ? limitError
            : null;
      });
      return;
    }
    setState(() {
      _maxReviewsError = null;
      _maxNewCardsError = null;
      _saving = true;
    });
    try {
      final provider = context.read<AppProvider>();
      await provider.setMaxReviews24h(maxReviews);
      await provider.setMaxNewCards24h(maxNewCards);
      // The web demo has no AI settings to save ([WebDemo]).
      if (!WebDemo.enabled) {
        await provider.setDeepSeekApiKey(_apiKeyController.text);
        await provider.setAiInstructions(_aiInstructionsController.text);
      }
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save settings: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _removeApiKey() async {
    setState(() => _saving = true);
    try {
      await context.read<AppProvider>().setDeepSeekApiKey('');
      if (mounted) _apiKeyController.clear();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not remove DeepSeek API key: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _signIn() async {
    final SyncPairing pairing;
    try {
      pairing = SyncPairing(
        email: _syncEmailController.text,
        password: _syncPasswordController.text,
      );
    } on FormatException catch (error) {
      setState(() => _syncError = error.message);
      return;
    }
    setState(() {
      _syncError = null;
      _saving = true;
    });
    try {
      await _syncAccounts.validateCredentials(pairing);
    } catch (error) {
      if (!mounted) return;
      if (error is SyncException && error.statusCode == 403) {
        setState(() {
          _creatingSyncAccount = true;
          _awaitingSyncConfirmation = true;
          _syncError =
              'This account still needs email confirmation. Enter the code '
              'from your email, then tap Confirm email.';
        });
      } else {
        setState(() => _syncError = describeSyncError(error));
      }
      return;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
    await _saveSyncPairing(pairing);
  }

  Future<void> _createSyncAccount() async {
    final SyncPairing pairing;
    try {
      pairing = SyncPairing(
        email: _syncEmailController.text,
        password: _syncPasswordController.text,
      );
    } on FormatException catch (error) {
      setState(() => _syncError = error.message);
      return;
    }
    if (_syncPasswordController.text != _syncConfirmPasswordController.text) {
      setState(() => _syncError = 'Passwords do not match.');
      return;
    }
    setState(() {
      _syncError = null;
      _saving = true;
    });
    try {
      await _syncAccounts.createAccount(pairing);
      if (mounted) {
        TextInput.finishAutofillContext(shouldSave: false);
        setState(() => _awaitingSyncConfirmation = true);
      }
    } catch (error) {
      if (mounted) setState(() => _syncError = describeSyncError(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _confirmSyncAccount() async {
    final SyncPairing pairing;
    try {
      pairing = SyncPairing(
        email: _syncEmailController.text,
        password: _syncPasswordController.text,
      );
    } on FormatException catch (error) {
      setState(() => _syncError = error.message);
      return;
    }
    // Taken before the awaits: checking the code takes a while, and the
    // account is confirmed on the server even if this dialog is closed in the
    // meantime (for example while reading the email in another app). The
    // sign-in has to be saved either way, or the code is used up and this
    // device is left signed out.
    final provider = context.read<AppProvider>();
    setState(() {
      _syncError = null;
      _saving = true;
    });
    try {
      try {
        await _syncAccounts.confirmAccount(
          pairing,
          _syncConfirmationCodeController.text,
        );
      } on SyncException catch (error) {
        if (error.statusCode != 400) rethrow;
        // A refused code can mean the account was confirmed a moment ago and
        // this device missed the answer. If the credentials work, sign in.
        try {
          await _syncAccounts.validateCredentials(pairing);
        } on SyncException {
          throw error; // still not confirmed: report the code
        }
      }
      // A new account gets a recovery code. It is made before the sign-in is
      // saved, while the keys derived for the signup are still at hand, and
      // only while this dialog is open to show it. Not getting one does not
      // stop the sign-in: Settings can make one later.
      String? recoveryCode;
      var recoveryFailed = false;
      if (mounted) {
        try {
          recoveryCode = await _syncAccounts.createRecoveryCode(pairing);
        } catch (_) {
          // Deliberately not shown in detail: the error never holds the code,
          // but the person only needs to know to try again from Settings.
          recoveryFailed = true;
        }
      }
      await provider.setSyncPairing(pairing);
      if (mounted) {
        TextInput.finishAutofillContext();
        _syncEmailController.clear();
        _syncPasswordController.clear();
        _syncConfirmPasswordController.clear();
        _syncConfirmationCodeController.clear();
        setState(() {
          _creatingSyncAccount = false;
          _awaitingSyncConfirmation = false;
          _saving = false;
          if (recoveryFailed) {
            _syncError =
                'Signed in, but a recovery code could not be created. Choose '
                'Recovery code to try again.';
          }
        });
        if (recoveryCode != null) await showRecoveryCode(context, recoveryCode);
      }
    } catch (error) {
      if (mounted) setState(() => _syncError = describeSyncError(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Recovers the account with its recovery code and a new password, signs
  /// this device in, and shows a new recovery code: the old one is used up.
  Future<void> _recoverSyncAccount() async {
    final SyncPairing pairing;
    try {
      pairing = SyncPairing(
        email: _syncEmailController.text,
        password: _syncPasswordController.text,
      );
    } on FormatException catch (error) {
      setState(() => _syncError = error.message);
      return;
    }
    if (_syncPasswordController.text != _syncConfirmPasswordController.text) {
      setState(() => _syncError = 'Passwords do not match.');
      return;
    }
    // Taken before the awaits: once the server has taken the new password,
    // the sign-in has to be saved even if this dialog was closed meanwhile.
    final provider = context.read<AppProvider>();
    setState(() {
      _syncError = null;
      _saving = true;
    });
    try {
      final recovered = await _syncAccounts.recoverAccount(
        pairing,
        _syncRecoveryCodeController.text,
      );
      // The old code is used up. Make the new one while the keys derived for
      // the new password are still at hand, as at signup.
      String? recoveryCode;
      var recoveryFailed = false;
      if (mounted) {
        try {
          recoveryCode = await _syncAccounts.createRecoveryCode(recovered);
        } catch (_) {
          recoveryFailed = true;
        }
      }
      await provider.setSyncPairing(recovered);
      if (mounted) {
        TextInput.finishAutofillContext();
        _syncEmailController.clear();
        _syncPasswordController.clear();
        _syncConfirmPasswordController.clear();
        _syncRecoveryCodeController.clear();
        setState(() {
          _recoveringSyncAccount = false;
          _saving = false;
          if (recoveryFailed) {
            _syncError =
                'Account recovered and signed in. The old recovery code has '
                'been used, and a new one could not be created. Choose '
                'Recovery code to create one.';
          }
        });
        if (recoveryCode != null) {
          await showRecoveryCode(
            context,
            recoveryCode,
            reason:
                'Your account is recovered and this device is signed in with '
                'the new password. The old recovery code has been used and '
                'no longer works, so here is a new one.',
          );
        }
      }
    } catch (error) {
      if (mounted) setState(() => _syncError = describeSyncError(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _deleteUnconfirmedAccount() async {
    final pairing = SyncPairing(
      email: _syncEmailController.text,
      password: _syncPasswordController.text,
    );
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete unconfirmed account?'),
        content: const Text(
          'This permanently deletes the pending account and its confirmation '
          'code. You can create a new account later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete account'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _syncError = null;
      _saving = true;
    });
    try {
      await _syncAccounts.deleteAccount(pairing);
      if (!mounted) return;
      _syncEmailController.clear();
      _syncPasswordController.clear();
      _syncConfirmPasswordController.clear();
      _syncConfirmationCodeController.clear();
      setState(() {
        _creatingSyncAccount = false;
        _awaitingSyncConfirmation = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unconfirmed account deleted.')),
      );
    } catch (error) {
      if (mounted) setState(() => _syncError = describeSyncError(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _changeSyncPassword(SyncPairing current) async {
    final newPassword = _newSyncPasswordController.text;
    if (newPassword != _newSyncConfirmPasswordController.text) {
      setState(() => _syncError = 'Passwords do not match.');
      return;
    }
    setState(() {
      _syncError = null;
      _saving = true;
    });
    try {
      final updated = await _syncAccounts.changePassword(current, newPassword);
      if (!mounted) return;
      await context.read<AppProvider>().setSyncPairing(updated);
      if (mounted) {
        _newSyncPasswordController.clear();
        _newSyncConfirmPasswordController.clear();
        setState(() => _changingSyncPassword = false);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _syncError = describeSyncError(error, signedIn: true));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _signInWithCopiedLink() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    final SyncPairing pairing;
    try {
      final text = data?.text ?? '';
      // Only one-time pairing links. A link that carried the password itself
      // is not accepted: nothing creates one, and it would skip the server.
      if (Uri.tryParse(text.trim())?.host != 'pair') {
        throw const FormatException('Not a LinguaSRS pairing link.');
      }
      pairing = await _syncAccounts.redeemPairingLink(text);
    } on FormatException catch (error) {
      setState(() => _syncError = error.message);
      return;
    } catch (error) {
      setState(() => _syncError = describeSyncError(error));
      return;
    }
    if (!mounted || !await confirmPairing(context, pairing)) return;
    await _saveSyncPairing(pairing);
  }

  /// Asks the server whether it still accepts this device's sign-in. Nothing
  /// else contacts it until sync exists, so this is how a device that was
  /// signed in elsewhere finds out that the account is gone.
  /// When a sync finished, in local time: just the time today, else the date
  /// and time.
  static String _syncTime(DateTime time) {
    final local = time.toLocal();
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final clock = '${two(local.hour)}:${two(local.minute)}';
    if (local.year == now.year &&
        local.month == now.month &&
        local.day == now.day) {
      return 'at $clock';
    }
    return 'on ${local.year}-${two(local.month)}-${two(local.day)} at $clock';
  }

  Future<void> _checkSignIn(SyncPairing pairing) async {
    setState(() {
      _syncError = null;
      _saving = true;
    });
    try {
      await _syncAccounts.validateCredentials(pairing);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('The server accepts this sign-in.')),
      );
    } catch (error) {
      if (mounted) {
        setState(() => _syncError = describeSyncError(error, signedIn: true));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveSyncPairing(SyncPairing? pairing) async {
    final provider = context.read<AppProvider>();
    setState(() {
      _syncError = null;
      _saving = true;
    });
    try {
      await provider.setSyncPairing(pairing);
      if (mounted) {
        _syncEmailController.clear();
        _syncPasswordController.clear();
        _syncConfirmPasswordController.clear();
        _syncConfirmationCodeController.clear();
        _syncRecoveryCodeController.clear();
        _newSyncPasswordController.clear();
        _newSyncConfirmPasswordController.clear();
        _creatingSyncAccount = false;
        _awaitingSyncConfirmation = false;
        _recoveringSyncAccount = false;
        _changingSyncPassword = false;
        _syncError = null;
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save sync sign-in: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Copies [text] and says so with [message], in the messenger of
  /// [context]: a dialog opened from Settings passes its own context, so the
  /// message shows on top of that dialog.
  Future<void> _copyToClipboard(
    BuildContext context,
    String text,
    String message,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: text));
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _signOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign out of sync?'),
        content: const Text(
          'Your lessons and progress stay on this device. You need your email '
          'and password to sign in again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _saveSyncPairing(null);
  }

  Future<void> _showPairingInvite(SyncPairing pairing) async {
    setState(() {
      _syncError = null;
      _saving = true;
    });
    try {
      final link = await _syncAccounts.createPairingLink(pairing);
      if (!mounted) return;
      setState(() => _saving = false);
      await showDialog<void>(
        context: context,
        builder: (context) => DialogMessenger(
          child: Builder(
            builder: (context) => AlertDialog(
              title: const Text('Pair another device'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox.square(
                    dimension: 240,
                    child: QrImageView(
                      data: link,
                      size: 240,
                      backgroundColor: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Scan on mobile to open the app and sign in, or copy '
                    'the one-time link and choose “Use copied link” on '
                    'desktop. It expires in 10 minutes and grants access to '
                    'this account. Only share it with a device you control.',
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Close'),
                ),
                FilledButton.icon(
                  onPressed: () => _copyToClipboard(
                    context,
                    link,
                    'One-time pairing link copied. It expires in 10 minutes.',
                  ),
                  icon: const Icon(Icons.copy),
                  label: const Text('Copy one-time link'),
                ),
              ],
            ),
          ),
        ),
      );
    } catch (error) {
      if (mounted) {
        setState(() => _syncError = describeSyncError(error, signedIn: true));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _createRecoveryCode(SyncPairing pairing) async {
    if (!await confirmNewRecoveryCode(context) || !mounted) return;
    setState(() {
      _syncError = null;
      _saving = true;
    });
    try {
      final code = await _syncAccounts.createRecoveryCode(pairing);
      if (!mounted) return;
      setState(() => _saving = false);
      await showRecoveryCode(context, code);
    } catch (error) {
      if (mounted) {
        setState(() => _syncError = describeSyncError(error, signedIn: true));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _deleteSyncAccount(SyncPairing pairing) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete sync account?'),
        content: const Text(
          'This permanently deletes the account and all synced data from the '
          'server. Local lessons and study progress on this device are not '
          'deleted. Other devices signed in to this account stay signed in '
          'until they next use the server, and then their sign-in is '
          'rejected; their lessons stay too. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete account'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _syncError = null;
      _saving = true;
    });
    try {
      await _syncAccounts.deleteAccount(pairing);
      if (mounted) await context.read<AppProvider>().setSyncPairing(null);
    } catch (error) {
      if (mounted) {
        setState(() => _syncError = describeSyncError(error, signedIn: true));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _generateAccountPassphrase() async {
    setState(() {
      _saving = true;
      _syncError = null;
    });
    try {
      final password = await _syncAccounts.generatePassphrase();
      if (!mounted) return;
      setState(() {
        _syncPasswordController.text = password;
        _syncConfirmPasswordController.text = password;
      });
    } catch (error) {
      if (mounted) setState(() => _syncError = describeSyncError(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _generateNewPassphrase() async {
    setState(() {
      _saving = true;
      _syncError = null;
    });
    try {
      final password = await _syncAccounts.generatePassphrase();
      if (!mounted) return;
      setState(() {
        _newSyncPasswordController.text = password;
        _newSyncConfirmPasswordController.text = password;
      });
    } catch (error) {
      if (mounted) setState(() => _syncError = describeSyncError(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _backupData() async {
    setState(() => _saving = true);
    try {
      final backup = await BackupService.createBackup();
      final saved = await FilePicker.saveFile(
        dialogTitle: 'Save LinguaSRS backup',
        fileName: 'lingua_srs_backup.json',
        bytes: Uint8List.fromList(utf8.encode(backup)),
      );
      if (saved != null && mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Backup saved.')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not create backup: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _restoreData() async {
    final provider = context.read<AppProvider>();
    setState(() => _saving = true);
    try {
      final files = await FilePicker.pickFiles(
        dialogTitle: 'Select LinguaSRS backup',
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (files.isEmpty || !mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Restore backup?'),
          content: Text(
            WebDemo.enabled
                ? 'This replaces the lessons and study progress in this '
                      'browser.'
                : 'This replaces the app data on this device. Your DeepSeek API key and sync sign-in will remain on this device.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Restore'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;

      final bytes = await files.single.readAsBytes();
      await BackupService.restoreBackup(utf8.decode(bytes));
      await provider.init();
      if (mounted) {
        // Settings closes, so the message goes to the page it was opened on.
        DialogMessenger.parentOf(context)
            .showSnackBar(const SnackBar(content: Text('Backup restored.')));
        Navigator.of(context).pop();
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not restore backup: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.watch<AppProvider>();
    final syncPairing = provider.syncPairing;
    return AlertDialog(
      title: const Text('Settings'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.onToggleTheme != null)
                Row(
                  children: [
                    const Expanded(child: Text('Theme')),
                    IconSwitch(
                      leading: Icons.light_mode,
                      trailing: Icons.dark_mode,
                      value: _darkMode,
                      onChanged: (_) {
                        widget.onToggleTheme!();
                        setState(() => _darkMode = !_darkMode);
                      },
                    ),
                  ],
                ),
              Row(
                children: [
                  const Expanded(child: Text('Autoplay audio')),
                  IconSwitch(
                    leading: Icons.volume_off,
                    trailing: Icons.volume_up,
                    value: provider.autoplayAudio,
                    onChanged: (_) => provider.toggleAutoplay(),
                  ),
                ],
              ),
              const Divider(),
              const SizedBox(height: 8),
              Text('Reviews', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              const Text(
                'Maximum number of due cards you can review in any rolling 24-hour window. Enter 0 for unlimited.',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _maxReviewsController,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: 'Max reviews per 24 hours',
                  border: const OutlineInputBorder(),
                  suffixText: 'cards',
                  errorText: _maxReviewsError,
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [50, 100, 200, 0].map((value) {
                  return ActionChip(
                    label: Text(value == 0 ? 'Unlimited' : '$value'),
                    onPressed: () => setState(() {
                      _maxReviewsController.text = '$value';
                      _maxReviewsError = null;
                    }),
                  );
                }).toList(),
              ),
              const SizedBox(height: 24),
              Text('New cards', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              const Text(
                'Maximum number of never-seen cards you can start in any rolling 24-hour window. They are studied after your due reviews and do not use up the review limit. Enter 0 for unlimited.',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _maxNewCardsController,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: 'Max new cards per 24 hours',
                  border: const OutlineInputBorder(),
                  suffixText: 'cards',
                  errorText: _maxNewCardsError,
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [5, 10, 20, 0].map((value) {
                  return ActionChip(
                    label: Text(value == 0 ? 'Unlimited' : '$value'),
                    onPressed: () => setState(() {
                      _maxNewCardsController.text = '$value';
                      _maxNewCardsError = null;
                    }),
                  );
                }).toList(),
              ),
              const SizedBox(height: 24),
              Text('Backup and restore', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              Text(
                WebDemo.enabled
                    ? 'Save your lessons and study progress to a file, or '
                          'restore them in this browser.'
                    : 'Save your lessons and study progress to a file, or restore them on this device. The DeepSeek API key and sync password are not included.',
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: _saving ? null : _backupData,
                    icon: const Icon(Icons.download),
                    label: const Text('Back up'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _saving ? null : _restoreData,
                    icon: const Icon(Icons.upload),
                    label: const Text('Restore'),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              if (WebDemo.enabled) ...[
                Text('Web demo', style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                const Text(WebDemo.settingsNote),
              ],
              if (!WebDemo.enabled &&
                  (SyncPairing.defaultEndpoint != null ||
                      syncPairing != null)) ...[
                Text('Sync', style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                if (syncPairing == null)
                  AutofillGroup(
                    onDisposeAction: AutofillContextAction.cancel,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _recoveringSyncAccount
                              ? 'Forgot your password? Enter your email, the '
                                    'recovery code you saved, and a new '
                                    'password. Your other devices will need '
                                    'the new password to sign in again.'
                              : _creatingSyncAccount
                              ? _awaitingSyncConfirmation
                                    ? 'Enter the confirmation code sent by '
                                          'email. If the address can be '
                                          'registered, the code will arrive '
                                          'shortly.'
                                    : 'Create an account with a strong '
                                          'passphrase. You must enter the '
                                          'emailed code and tap Confirm email '
                                          'before you can use it.'
                              : 'Sign in with your email and password, or use '
                                    'a one-time pairing link from another '
                                    'device.',
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _syncEmailController,
                          enabled: !_awaitingSyncConfirmation,
                          keyboardType: TextInputType.emailAddress,
                          autocorrect: false,
                          enableSuggestions: false,
                          autofillHints: const [AutofillHints.email],
                          decoration: const InputDecoration(
                            labelText: 'Sync email',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        if (_recoveringSyncAccount) ...[
                          const SizedBox(height: 12),
                          TextField(
                            controller: _syncRecoveryCodeController,
                            autocorrect: false,
                            enableSuggestions: false,
                            enableIMEPersonalizedLearning: false,
                            textCapitalization: TextCapitalization.characters,
                            onChanged: (_) => setState(() => _syncError = null),
                            decoration: const InputDecoration(
                              labelText: 'Recovery code',
                              helperText:
                                  '32 letters and digits, such as '
                                  'XXXX-XXXX-…',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ],
                        const SizedBox(height: 12),
                        TextField(
                          controller: _syncPasswordController,
                          enabled: !_awaitingSyncConfirmation,
                          obscureText: _obscureSyncPassword,
                          autocorrect: false,
                          enableSuggestions: false,
                          autofillHints: [
                            _creatingSyncAccount || _recoveringSyncAccount
                                ? AutofillHints.newPassword
                                : AutofillHints.password,
                          ],
                          onChanged: (_) => setState(() => _syncError = null),
                          decoration: InputDecoration(
                            labelText:
                                _creatingSyncAccount || _recoveringSyncAccount
                                ? 'New sync password'
                                : 'Sync password',
                            border: const OutlineInputBorder(),
                            suffixIcon: _passwordVisibilityButton(
                              _obscureSyncPassword,
                              () => setState(
                                () => _obscureSyncPassword =
                                    !_obscureSyncPassword,
                              ),
                            ),
                          ),
                        ),
                        if (_choosingNewPassword) ...[
                          const SizedBox(height: 12),
                          TextField(
                            controller: _syncConfirmPasswordController,
                            obscureText: _obscureSyncConfirmPassword,
                            autocorrect: false,
                            enableSuggestions: false,
                            autofillHints: const [AutofillHints.newPassword],
                            onChanged: (_) => setState(() => _syncError = null),
                            decoration: InputDecoration(
                              labelText: 'Confirm sync password',
                              border: OutlineInputBorder(),
                              suffixIcon: _passwordVisibilityButton(
                                _obscureSyncConfirmPassword,
                                () => setState(
                                  () => _obscureSyncConfirmPassword =
                                      !_obscureSyncConfirmPassword,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'Use 15–64 characters. Avoid common or breached '
                            'passwords.',
                          ),
                          if (_syncPasswordController.text.isNotEmpty &&
                              _newAccountPasswordError != null) ...[
                            const SizedBox(height: 6),
                            Text(
                              _newAccountPasswordError!,
                              style: TextStyle(color: theme.colorScheme.error),
                            ),
                          ],
                          if (_syncPasswordController.text.isNotEmpty &&
                              _syncPasswordController.text !=
                                  _syncConfirmPasswordController.text) ...[
                            const SizedBox(height: 6),
                            Text(
                              'Passwords do not match.',
                              style: TextStyle(color: theme.colorScheme.error),
                            ),
                          ],
                          TextButton.icon(
                            onPressed: _saving
                                ? null
                                : _generateAccountPassphrase,
                            icon: const Icon(Icons.auto_awesome),
                            label: const Text('Generate passphrase'),
                          ),
                        ],
                        if (_creatingSyncAccount &&
                            _awaitingSyncConfirmation) ...[
                          const SizedBox(height: 12),
                          TextField(
                            controller: _syncConfirmationCodeController,
                            keyboardType: TextInputType.number,
                            textInputAction: TextInputAction.done,
                            autocorrect: false,
                            enableSuggestions: false,
                            autofillHints: const [AutofillHints.oneTimeCode],
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                              LengthLimitingTextInputFormatter(8),
                            ],
                            onChanged: (_) {
                              setState(() {});
                              if (_hasConfirmationCode && !_saving) {
                                _confirmSyncAccount();
                              }
                            },
                            onSubmitted: (_) {
                              if (_hasConfirmationCode && !_saving) {
                                _confirmSyncAccount();
                              }
                            },
                            decoration: const InputDecoration(
                              labelText: 'Email confirmation code',
                              helperText: 'The 8-digit code from the email',
                              border: OutlineInputBorder(),
                            ),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'You are signed in as soon as the 8-digit code is '
                            'entered. Saving the password in your password '
                            'manager does not confirm the account.',
                          ),
                        ],
                        if (_syncError != null) ...[
                          const SizedBox(height: 8),
                          Text(
                            _syncError!,
                            style: TextStyle(color: theme.colorScheme.error),
                          ),
                        ],
                        if (_creatingSyncAccount && _awaitingSyncConfirmation)
                          TextButton(
                            onPressed: _saving
                                ? null
                                : _deleteUnconfirmedAccount,
                            child: const Text('Delete unconfirmed account'),
                          ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          children: [
                            if (_recoveringSyncAccount)
                              FilledButton(
                                onPressed: _saving || !_canRecoverAccount
                                    ? null
                                    : _recoverSyncAccount,
                                child: const Text('Recover account'),
                              )
                            else if (_creatingSyncAccount)
                              FilledButton(
                                onPressed: _saving
                                    ? null
                                    : _awaitingSyncConfirmation
                                    ? (_hasConfirmationCode
                                          ? _confirmSyncAccount
                                          : null)
                                    : _canCreateAccount
                                    ? _createSyncAccount
                                    : null,
                                child: Text(
                                  _awaitingSyncConfirmation
                                      ? 'Confirm email'
                                      : 'Create account',
                                ),
                              )
                            else ...[
                              FilledButton(
                                onPressed: _saving ? null : _signIn,
                                child: const Text('Sign in'),
                              ),
                              OutlinedButton.icon(
                                onPressed: _saving
                                    ? null
                                    : _signInWithCopiedLink,
                                icon: const Icon(Icons.content_paste),
                                label: const Text('Use copied link'),
                              ),
                            ],
                          ],
                        ),
                        if (!_awaitingSyncConfirmation &&
                            !_recoveringSyncAccount)
                          TextButton(
                            onPressed: _saving
                                ? null
                                : () => setState(() {
                                    _creatingSyncAccount =
                                        !_creatingSyncAccount;
                                    _syncError = null;
                                    _syncPasswordController.clear();
                                    _syncConfirmPasswordController.clear();
                                  }),
                            child: Text(
                              _creatingSyncAccount
                                  ? 'Already have an account? Sign in'
                                  : 'Create a sync account',
                            ),
                          ),
                        if (!_creatingSyncAccount)
                          TextButton(
                            onPressed: _saving
                                ? null
                                : () => setState(() {
                                    _recoveringSyncAccount =
                                        !_recoveringSyncAccount;
                                    _syncError = null;
                                    _syncPasswordController.clear();
                                    _syncConfirmPasswordController.clear();
                                    _syncRecoveryCodeController.clear();
                                  }),
                            child: Text(
                              _recoveringSyncAccount
                                  ? 'Back to sign in'
                                  : 'Forgot password? Use recovery code',
                            ),
                          ),
                      ],
                    ),
                  )
                else ...[
                  Text('Signed in as ${syncPairing.email}'),
                  if (syncPairing.endpoint != SyncPairing.defaultEndpoint)
                    Text(
                      'Server ${syncPairing.endpoint}',
                      style: theme.textTheme.bodySmall,
                    ),
                  const SizedBox(height: 4),
                  Text(
                    provider.isSyncing
                        ? 'Syncing…'
                        : provider.lastSyncedAt == null
                        ? 'Not synced yet on this device.'
                        : 'Last synced ${_syncTime(provider.lastSyncedAt!)}.',
                    style: theme.textTheme.bodySmall,
                  ),
                  if (provider.syncProblem != null)
                    Text(
                      provider.syncProblem!,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  if (_changingSyncPassword) ...[
                    const SizedBox(height: 12),
                    TextField(
                      controller: _newSyncPasswordController,
                      obscureText: _obscureNewSyncPassword,
                      autocorrect: false,
                      enableSuggestions: false,
                      autofillHints: const [AutofillHints.newPassword],
                      onChanged: (_) => setState(() => _syncError = null),
                      decoration: InputDecoration(
                        labelText: 'New sync password',
                        border: OutlineInputBorder(),
                        suffixIcon: _passwordVisibilityButton(
                          _obscureNewSyncPassword,
                          () => setState(
                            () => _obscureNewSyncPassword =
                                !_obscureNewSyncPassword,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _newSyncConfirmPasswordController,
                      obscureText: _obscureNewSyncConfirmPassword,
                      autocorrect: false,
                      enableSuggestions: false,
                      autofillHints: const [AutofillHints.newPassword],
                      onChanged: (_) => setState(() => _syncError = null),
                      decoration: InputDecoration(
                        labelText: 'Confirm new sync password',
                        border: OutlineInputBorder(),
                        suffixIcon: _passwordVisibilityButton(
                          _obscureNewSyncConfirmPassword,
                          () => setState(
                            () => _obscureNewSyncConfirmPassword =
                                !_obscureNewSyncConfirmPassword,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Use 15–64 characters and avoid common or breached '
                      'passwords. Your data is re-wrapped with the new '
                      'password; synced data is not re-encrypted.',
                    ),
                    if (_newSyncPasswordController.text.isNotEmpty &&
                        _changedPasswordError != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        _changedPasswordError!,
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    ],
                    if (_newSyncPasswordController.text.isNotEmpty &&
                        _newSyncPasswordController.text !=
                            _newSyncConfirmPasswordController.text) ...[
                      const SizedBox(height: 6),
                      Text(
                        'Passwords do not match.',
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    ],
                    TextButton.icon(
                      onPressed: _saving ? null : _generateNewPassphrase,
                      icon: const Icon(Icons.auto_awesome),
                      label: const Text('Generate passphrase'),
                    ),
                    if (_syncError != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        _syncError!,
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    ],
                    Wrap(
                      spacing: 8,
                      children: [
                        FilledButton(
                          onPressed: _saving || !_canChangePassword
                              ? null
                              : () => _changeSyncPassword(syncPairing),
                          child: const Text('Save new password'),
                        ),
                        TextButton(
                          onPressed: _saving
                              ? null
                              : () => setState(() {
                                  _changingSyncPassword = false;
                                  _syncError = null;
                                  _newSyncPasswordController.clear();
                                  _newSyncConfirmPasswordController.clear();
                                }),
                          child: const Text('Cancel'),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 12),
                  if (_syncError != null && !_changingSyncPassword) ...[
                    Text(
                      _syncError!,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                    const SizedBox(height: 8),
                  ],
                  Wrap(
                    spacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed: _saving || provider.isSyncing
                            ? null
                            : provider.syncNow,
                        icon: const Icon(Icons.sync),
                        label: const Text('Sync now'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _saving
                            ? null
                            : () => _checkSignIn(syncPairing),
                        icon: const Icon(Icons.verified_user_outlined),
                        label: const Text('Check sign-in'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _saving
                            ? null
                            : () => _showPairingInvite(syncPairing),
                        icon: const Icon(Icons.qr_code_2),
                        label: const Text('Pair another device'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _saving
                            ? null
                            : () => setState(() {
                                _changingSyncPassword = true;
                                _syncError = null;
                              }),
                        icon: const Icon(Icons.password),
                        label: const Text('Change password'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _saving
                            ? null
                            : () => _createRecoveryCode(syncPairing),
                        icon: const Icon(Icons.key_outlined),
                        label: const Text('Recovery code'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _saving ? null : _signOut,
                        icon: const Icon(Icons.logout),
                        label: const Text('Sign out'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _saving
                            ? null
                            : () => _deleteSyncAccount(syncPairing),
                        icon: const Icon(Icons.delete_forever_outlined),
                        label: const Text('Delete account'),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 24),
              ],
              if (!WebDemo.enabled) ..._aiSection(theme, provider),
            ],
          ),
        ),
      ),
      actions: _actions,
    );
  }

  List<Widget> _aiSection(ThemeData theme, AppProvider provider) => [
    Row(
      children: [
        Expanded(child: Text('AI features', style: theme.textTheme.titleSmall)),
        Switch(value: provider.showAi, onChanged: provider.setShowAi),
      ],
    ),
    const SizedBox(height: 8),
    if (!provider.showAi)
      const Text(
        'AI features are hidden: the Discussions tab, Ask AI and '
        'the AI suggestion buttons. Saved discussions are kept.',
      ),
    if (provider.showAi) ...[
      const Text(
        'Add your DeepSeek API key to ask questions about vocabulary and example sentences during quizzes.',
      ),
      const SizedBox(height: 16),
      AiSettingsFields(
        apiKeyController: _apiKeyController,
        instructionsController: _aiInstructionsController,
        onRemoveApiKey: provider.deepSeekApiKey.isNotEmpty
            ? _removeApiKey
            : null,
        enabled: !_saving,
      ),
    ],
  ];

  List<Widget> get _actions => [
    TextButton(
      onPressed: _saving ? null : () => Navigator.of(context).pop(),
      child: const Text('Cancel'),
    ),
    FilledButton(
      onPressed: _saving ? null : _save,
      child: _saving
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Text('Save'),
    ),
  ];
}
