import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/app_provider.dart';
import '../services/backup_service.dart';
import '../widgets/icon_switch.dart';

class SettingsDialog extends StatefulWidget {
  final bool isDarkMode;
  final VoidCallback? onToggleTheme;

  const SettingsDialog({
    super.key,
    this.isDarkMode = false,
    this.onToggleTheme,
  });

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  late final TextEditingController _apiKeyController;
  late final TextEditingController _maxReviewsController;
  late final TextEditingController _maxNewCardsController;
  late bool _darkMode = widget.isDarkMode;
  bool _obscureApiKey = true;
  bool _saving = false;
  String? _maxReviewsError;
  String? _maxNewCardsError;

  @override
  void initState() {
    super.initState();
    final provider = context.read<AppProvider>();
    _apiKeyController = TextEditingController(text: provider.deepSeekApiKey);
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
    _maxReviewsController.dispose();
    _maxNewCardsController.dispose();
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
      await provider.setDeepSeekApiKey(_apiKeyController.text);
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
          content: const Text(
            'This replaces the app data on this device. Your DeepSeek API key will remain on this device.',
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
        ScaffoldMessenger.of(context)
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
              const Text(
                'Save your lessons and study progress to a file, or restore them on this device. The DeepSeek API key is not included.',
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
              Text('AI discussions', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              const Text(
                'Add your DeepSeek API key to ask questions about vocabulary and example sentences during quizzes.',
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _apiKeyController,
                obscureText: _obscureApiKey,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: 'DeepSeek API key',
                  hintText: 'sk-...',
                  suffixIcon: IconButton(
                    tooltip: _obscureApiKey ? 'Show API key' : 'Hide API key',
                    icon: Icon(
                      _obscureApiKey ? Icons.visibility : Icons.visibility_off,
                    ),
                    onPressed: () =>
                        setState(() => _obscureApiKey = !_obscureApiKey),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'The key is stored in this device’s app preferences. DeepSeek receives your questions, and for the merge and hint buttons the Korean and English of your vocabulary (for hints, every word of the same type).',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
      actions: [
        if (context.read<AppProvider>().deepSeekApiKey.isNotEmpty)
          TextButton(
            onPressed: _saving ? null : _removeApiKey,
            child: const Text('Remove key'),
          ),
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
      ],
    );
  }
}
