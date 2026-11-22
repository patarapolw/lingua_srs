import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../providers/app_provider.dart';
import '../widgets/ai_settings_fields.dart';
import '../widgets/dialog_messenger.dart';
import '../widgets/dialog_save_shortcuts.dart';

/// The AI settings alone, opened from an AI chat: the DeepSeek API key and
/// custom AI instructions. A chat opened during a review can change them
/// without leaving the review for Settings. Turning AI features off stays in
/// Settings.
class AiSettingsDialog extends StatelessWidget {
  const AiSettingsDialog({super.key});

  /// Opens the dialog over [context].
  static Future<void> show(BuildContext context) => showDialog<void>(
    context: context,
    builder: (_) => const AiSettingsDialog(),
  );

  @override
  Widget build(BuildContext context) =>
      const DialogMessenger(child: _AiSettingsDialogBody());
}

class _AiSettingsDialogBody extends StatefulWidget {
  const _AiSettingsDialogBody();

  @override
  State<_AiSettingsDialogBody> createState() => _AiSettingsDialogState();
}

class _AiSettingsDialogState extends State<_AiSettingsDialogBody> {
  late final TextEditingController _apiKeyController;
  late final TextEditingController _instructionsController;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final provider = context.read<AppProvider>();
    _apiKeyController = TextEditingController(text: provider.deepSeekApiKey);
    _instructionsController = TextEditingController(
      text: provider.aiInstructions,
    );
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    _instructionsController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final provider = context.read<AppProvider>();
      await provider.setDeepSeekApiKey(_apiKeyController.text);
      await provider.setAiInstructions(_instructionsController.text);
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save AI settings: $error')),
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
    final hasKey = context.select<AppProvider, bool>(
      (provider) => provider.deepSeekApiKey.isNotEmpty,
    );
    return DialogSaveShortcuts(
      onSave: _save,
      autofocus: false,
      child: AlertDialog(
        title: const Text('AI settings'),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: AiSettingsFields(
              apiKeyController: _apiKeyController,
              instructionsController: _instructionsController,
              onRemoveApiKey: hasKey ? _removeApiKey : null,
              enabled: !_saving,
            ),
          ),
        ),
        actions: [
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
      ),
    );
  }
}
