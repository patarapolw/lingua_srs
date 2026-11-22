import 'package:material_ui/material_ui.dart';

import '../services/lesson_ai_prompt.dart';

/// The DeepSeek API key and custom AI instructions fields, shared by Settings
/// and the AI settings an AI chat opens. Turning AI features off is not here:
/// it stays in Settings.
class AiSettingsFields extends StatefulWidget {
  final TextEditingController apiKeyController;
  final TextEditingController instructionsController;

  /// Shows the Remove API key button, which calls this. Null hides it.
  final VoidCallback? onRemoveApiKey;

  /// False while saving: the remove button is disabled.
  final bool enabled;

  const AiSettingsFields({
    super.key,
    required this.apiKeyController,
    required this.instructionsController,
    this.onRemoveApiKey,
    this.enabled = true,
  });

  @override
  State<AiSettingsFields> createState() => _AiSettingsFieldsState();
}

class _AiSettingsFieldsState extends State<AiSettingsFields> {
  bool _obscureApiKey = true;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: widget.apiKeyController,
          obscureText: _obscureApiKey,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: 'DeepSeek API key',
            hintText: 'sk-...',
            floatingLabelBehavior: FloatingLabelBehavior.always,
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.onRemoveApiKey case final onRemove?)
                  IconButton(
                    tooltip: 'Remove API key',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: widget.enabled ? onRemove : null,
                  ),
                IconButton(
                  tooltip: _obscureApiKey ? 'Show API key' : 'Hide API key',
                  icon: Icon(
                    _obscureApiKey ? Icons.visibility : Icons.visibility_off,
                  ),
                  onPressed: () =>
                      setState(() => _obscureApiKey = !_obscureApiKey),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: widget.instructionsController,
          minLines: 2,
          maxLines: 6,
          maxLength: LessonAiPrompt.maxInstructionsChars,
          decoration: const InputDecoration(
            labelText: 'Custom AI instructions',
            hintText: 'e.g. Explain for an ESL learner',
            alignLabelWithHint: true,
            floatingLabelBehavior: FloatingLabelBehavior.always,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          'The key is stored in this device’s secure storage. DeepSeek receives your questions, and for the merge and hint buttons the Korean and English of your vocabulary (for hints, every word of the same type).',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}
