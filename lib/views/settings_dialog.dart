import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/app_provider.dart';
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
  late bool _darkMode = widget.isDarkMode;
  bool _obscureApiKey = true;
  bool _saving = false;
  String? _maxReviewsError;

  @override
  void initState() {
    super.initState();
    final provider = context.read<AppProvider>();
    _apiKeyController = TextEditingController(text: provider.deepSeekApiKey);
    _maxReviewsController = TextEditingController(
      text: '${provider.maxReviews24h > 0 ? provider.maxReviews24h : 0}',
    );
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    _maxReviewsController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final maxReviews = int.tryParse(_maxReviewsController.text.trim());
    if (maxReviews == null || maxReviews < 0) {
      setState(
        () => _maxReviewsError = 'Enter a whole number, or 0 for unlimited.',
      );
      return;
    }
    setState(() {
      _maxReviewsError = null;
      _saving = true;
    });
    try {
      final provider = context.read<AppProvider>();
      await provider.setMaxReviews24h(maxReviews);
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
                  const Expanded(child: Text('Romanization on card back')),
                  Switch(
                    value: provider.showRomanization,
                    onChanged: (_) => provider.toggleRomanization(),
                  ),
                ],
              ),
              Row(
                children: [
                  const Expanded(child: Text('IPA on card back')),
                  Switch(
                    value: provider.showIpa,
                    onChanged: (_) => provider.toggleIpa(),
                  ),
                ],
              ),
              const Divider(),
              const SizedBox(height: 8),
              Text('Reviews', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              const Text(
                'Maximum number of reviews allowed in any rolling 24-hour window. Enter 0 for unlimited.',
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
