import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/app_provider.dart';

class DeepSeekSettingsDialog extends StatefulWidget {
  const DeepSeekSettingsDialog({super.key});

  @override
  State<DeepSeekSettingsDialog> createState() => _DeepSeekSettingsDialogState();
}

class _DeepSeekSettingsDialogState extends State<DeepSeekSettingsDialog> {
  late final TextEditingController _apiKeyController;
  bool _obscureApiKey = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _apiKeyController = TextEditingController(
      text: context.read<AppProvider>().deepSeekApiKey,
    );
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await context.read<AppProvider>().setDeepSeekApiKey(
        _apiKeyController.text,
      );
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save DeepSeek API key: $error')),
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
      if (mounted) Navigator.of(context).pop();
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

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Settings'),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
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
              'The key is stored in this device’s app preferences and sent to DeepSeek when you ask a question.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
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
