import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/app_provider.dart';
import '../services/korean_pronunciation_service.dart';

/// Optional romanization / IPA lines under Korean text. Renders nothing unless
/// the matching setting is on, the language is Korean, and the text has Hangul.
class PronunciationLine extends StatelessWidget {
  const PronunciationLine({
    super.key,
    required this.text,
    required this.languageCode,
    this.centered = true,
  });

  final String text;
  final String languageCode;
  final bool centered;

  @override
  Widget build(BuildContext context) {
    if (languageCode != 'ko' ||
        !KoreanPronunciationService.containsHangul(text)) {
      return const SizedBox.shrink();
    }
    final provider = context.watch<AppProvider>();
    final lines = <String>[
      if (provider.showRomanization) KoreanPronunciationService.romanize(text),
      if (provider.showIpa) '[${KoreanPronunciationService.toIpa(text)}]',
    ];
    if (lines.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final style = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: centered
            ? CrossAxisAlignment.center
            : CrossAxisAlignment.start,
        children: [
          for (final line in lines)
            Text(
              line,
              style: style,
              textAlign: centered ? TextAlign.center : TextAlign.start,
            ),
        ],
      ),
    );
  }
}
