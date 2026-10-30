import 'package:flutter/material.dart';

import 'audio_button.dart';

/// An "Audio URL" field for an edit dialog.
///
/// The button at the end previews the URL as typed, whether or not the
/// recording is switched on. Once there is a URL, a checkbox lets the
/// recording be ignored in favour of text-to-speech without deleting the URL.
class AudioUrlField extends StatelessWidget {
  final TextEditingController controller;
  final bool useAudio;
  final ValueChanged<bool> onUseAudioChanged;
  final String labelText;

  const AudioUrlField({
    super.key,
    required this.controller,
    required this.useAudio,
    required this.onUseAudioChanged,
    this.labelText = 'Audio URL',
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final hasUrl = controller.text.trim().isNotEmpty;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: controller,
              decoration: InputDecoration(
                labelText: labelText,
                border: const OutlineInputBorder(),
                suffixIcon: AudioButton(
                  audioUrl: controller.text.trim(),
                  compact: true,
                ),
              ),
            ),
            if (hasUrl)
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: useAudio,
                onChanged: (value) => onUseAudioChanged(value ?? true),
                title: const Text('Use this recording'),
                subtitle: const Text(
                  'Untick to speak with text-to-speech instead.',
                ),
              ),
          ],
        );
      },
    );
  }
}

/// The optional text-to-speech override of an edit dialog.
///
/// Collapsed unless a value is already set, so dialogs stay short, especially
/// on a phone. The button previews what would be spoken: the override, or
/// [spokenFallback] (the word or sentence) while the override is blank. It
/// always uses text-to-speech, so it can be compared with the recording.
class TtsTextField extends StatelessWidget {
  final TextEditingController controller;

  /// The text that is spoken when [controller] is blank.
  final TextEditingController spokenFallback;
  final String? language;
  final String labelText;
  final String? hintText;
  final String? helperText;

  const TtsTextField({
    super.key,
    required this.controller,
    required this.spokenFallback,
    this.language,
    this.labelText = 'Korean TTS text (optional)',
    this.hintText,
    this.helperText,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Theme(
      data: theme.copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        initiallyExpanded: controller.text.trim().isNotEmpty,
        maintainState: true,
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(top: 4, bottom: 8),
        title: Text(
          'Text-to-speech',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        subtitle: ListenableBuilder(
          listenable: controller,
          builder: (context, _) => Text(
            controller.text.trim().isEmpty
                ? 'Speaks the text as written.'
                : 'Speaks: ${controller.text.trim()}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
        ),
        children: [
          ListenableBuilder(
            listenable: Listenable.merge([controller, spokenFallback]),
            builder: (context, _) {
              final override = controller.text.trim();
              return TextField(
                controller: controller,
                decoration: InputDecoration(
                  labelText: labelText,
                  hintText: hintText,
                  helperText: helperText,
                  helperMaxLines: 3,
                  border: const OutlineInputBorder(),
                  suffixIcon: AudioButton(
                    fallbackText: override.isNotEmpty
                        ? override
                        : spokenFallback.text,
                    language: language,
                    compact: true,
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
