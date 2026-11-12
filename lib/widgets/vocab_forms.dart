import 'package:material_ui/material_ui.dart';

import '../models/vocab_item.dart';

/// A word's reading and the other ways it is written, under the word: the
/// reading as a line of text, then one small tag per other form
/// (*Traditional:* 學生, *Hanja:* 學生). Nothing is built when the word
/// has neither.
class VocabForms extends StatelessWidget {
  const VocabForms({
    super.key,
    required this.vocab,
    this.alignment = WrapAlignment.center,
    this.readingStyle,
  });

  final VocabItem vocab;

  /// How the reading and the tags line up: centred on a card, at the start
  /// in a list.
  final WrapAlignment alignment;

  /// The reading's style; [TextTheme.titleMedium] by default.
  final TextStyle? readingStyle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reading = vocab.reading.trim();
    final forms = vocab.otherForms;
    if (reading.isEmpty && forms.isEmpty) return const SizedBox.shrink();
    final muted = theme.colorScheme.onSurfaceVariant;
    final textAlign = switch (alignment) {
      WrapAlignment.center => TextAlign.center,
      WrapAlignment.end => TextAlign.end,
      _ => TextAlign.start,
    };
    return Column(
      crossAxisAlignment: switch (alignment) {
        WrapAlignment.center => CrossAxisAlignment.center,
        WrapAlignment.end => CrossAxisAlignment.end,
        _ => CrossAxisAlignment.start,
      },
      mainAxisSize: MainAxisSize.min,
      children: [
        if (reading.isNotEmpty)
          Text(
            reading,
            key: const ValueKey('vocab-reading'),
            style: (readingStyle ?? theme.textTheme.titleMedium)?.copyWith(
              color: muted,
            ),
            textAlign: textAlign,
          ),
        if (forms.isNotEmpty)
          Padding(
            key: const ValueKey('vocab-other-forms'),
            padding: const EdgeInsets.only(top: 8, bottom: 4),
            child: Wrap(
              alignment: alignment,
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final other in forms)
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      child: Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: '${other.label}: ',
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: muted,
                              ),
                            ),
                            TextSpan(
                              text: other.form,
                              style: theme.textTheme.titleMedium,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
