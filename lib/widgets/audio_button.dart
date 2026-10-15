import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/audio_service.dart';

class AudioButton extends StatelessWidget {
  final String? audioUrl;
  final String? fallbackText;
  final String? language;
  final String? label;
  final double iconSize;
  final bool compact;

  const AudioButton({
    super.key,
    this.audioUrl,
    this.fallbackText,
    this.language,
    this.label,
    this.iconSize = 22,
    this.compact = false,
  });

  bool get _hasAudioUrl => audioUrl != null && audioUrl!.trim().isNotEmpty;
  bool get _hasFallbackText => fallbackText != null && fallbackText!.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    if (!_hasAudioUrl && !_hasFallbackText) {
      return const SizedBox.shrink();
    }

    final audioService = context.watch<AudioService>();
    final keyToMatch = _hasAudioUrl ? audioUrl!.trim() : 'tts_${fallbackText!.trim()}';
    final isPlayingThis = audioService.isPlaying && audioService.currentlyPlayingKey == keyToMatch;

    final colorScheme = Theme.of(context).colorScheme;
    final isTts = !_hasAudioUrl && _hasFallbackText;

    if (compact) {
      return IconButton(
        iconSize: iconSize,
        visualDensity: VisualDensity.compact,
        tooltip: isPlayingThis
            ? 'Stop Audio'
            : (isTts ? 'Play Text-to-Speech' : 'Play Audio'),
        color: isPlayingThis ? colorScheme.primary : colorScheme.onSurfaceVariant,
        icon: isPlayingThis
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2.2),
              )
            : Icon(isTts ? Icons.record_voice_over_outlined : Icons.volume_up_rounded),
        onPressed: () {
          if (isPlayingThis) {
            audioService.stop();
          } else {
            if (_hasAudioUrl) {
              audioService.playAudio(audioUrl);
            } else {
              audioService.speak(fallbackText!, language: language);
            }
          }
        },
      );
    }

    final displayLabel = label ??
        (isPlayingThis
            ? 'Playing...'
            : (isTts ? 'TTS Audio' : 'Play Audio'));

    return OutlinedButton.icon(
      style: OutlinedButton.styleFrom(
        foregroundColor: isPlayingThis ? colorScheme.primary : null,
        side: BorderSide(
          color: isPlayingThis ? colorScheme.primary : colorScheme.outlineVariant,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      ),
      icon: isPlayingThis
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(isTts ? Icons.record_voice_over_outlined : Icons.volume_up_rounded),
      label: Text(displayLabel),
      onPressed: () {
        if (isPlayingThis) {
          audioService.stop();
        } else {
          if (_hasAudioUrl) {
            audioService.playAudio(audioUrl);
          } else {
            audioService.speak(fallbackText!, language: language);
          }
        }
      },
    );
  }
}
