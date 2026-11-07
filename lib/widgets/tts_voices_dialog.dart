import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../services/audio_service.dart';
import '../services/tts_voice.dart';

/// Lists the voices of the device's TTS engine by locale, so the locale for a
/// `tts` prefix (`zh-TW:垃圾`) can be read off exactly. Tapping a locale
/// copies its prefix.
class TtsVoicesDialog extends StatefulWidget {
  const TtsVoicesDialog({super.key});

  static Future<void> show(BuildContext context) => showDialog<void>(
    context: context,
    builder: (_) => const TtsVoicesDialog(),
  );

  @override
  State<TtsVoicesDialog> createState() => _TtsVoicesDialogState();
}

class _TtsVoicesDialogState extends State<TtsVoicesDialog> {
  late final Future<TtsVoiceList> _voices = context
      .read<AudioService>()
      .listVoices();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Text-to-speech voices'),
      content: SizedBox(
        width: 440,
        child: FutureBuilder<TtsVoiceList>(
          future: _voices,
          builder: (context, snapshot) {
            final list = snapshot.data;
            if (list == null) {
              return const SizedBox(
                height: 80,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            return _VoiceList(list);
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _VoiceList extends StatelessWidget {
  final TtsVoiceList list;

  const _VoiceList(this.list);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final byLocale = <String, List<TtsVoice>>{};
    for (final voice in list.voices) {
      byLocale.putIfAbsent(voice.locale, () => []).add(voice);
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Engine: ${list.engine ?? 'unknown'}. Only this engine\'s voices '
          'are used; change it in Android text-to-speech settings. '
          'Tap a locale to copy its prefix.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        if (byLocale.isEmpty)
          const Text('This engine reports no voices.')
        else
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final entry in byLocale.entries)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(entry.key),
                    subtitle: Text(
                      entry.value.map(_describe).join('\n'),
                      style: theme.textTheme.bodySmall,
                    ),
                    onTap: () => _copyPrefix(context, entry.key),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  static String _describe(TtsVoice voice) {
    final notes = [
      if (!voice.offline) 'needs network, not used',
      if (voice.installed == false) 'not installed',
    ];
    return notes.isEmpty ? voice.name : '${voice.name} (${notes.join(', ')})';
  }

  static Future<void> _copyPrefix(BuildContext context, String locale) async {
    final prefix = '$locale:';
    await Clipboard.setData(ClipboardData(text: prefix));
    if (!context.mounted) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text('Copied $prefix')));
  }
}
