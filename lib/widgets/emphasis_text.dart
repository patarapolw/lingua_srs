import 'package:flutter/material.dart';

/// Shows a sentence or its translation, with each `**emphasis**` segment in
/// bold. Nothing else is interpreted, so sentences and cloze text (`(___)`) are
/// shown exactly as written. Notes and everything else that really is Markdown
/// still go through `MarkdownContent`.
class EmphasisText extends StatelessWidget {
  final String text;
  final TextStyle? style;
  final TextAlign? textAlign;

  const EmphasisText(this.text, {super.key, this.style, this.textAlign});

  /// Splits [text] at every `**`. The parts alternate between plain and
  /// emphasized, starting with plain. With an odd number of markers the last
  /// one has nothing to close it, so it is kept as typed instead of bolding the
  /// rest of the sentence. Empty parts are dropped.
  static List<({String text, bool emphasized})> segments(String text) {
    final parts = text.split('**');
    final lastIsUnclosed = parts.length.isEven;
    final result = <({String text, bool emphasized})>[];

    void add(String value, bool emphasized) {
      if (value.isEmpty) return;
      if (result.isNotEmpty && result.last.emphasized == emphasized) {
        result[result.length - 1] = (
          text: result.last.text + value,
          emphasized: emphasized,
        );
      } else {
        result.add((text: value, emphasized: emphasized));
      }
    }

    for (var i = 0; i < parts.length; i++) {
      if (lastIsUnclosed && i == parts.length - 1) {
        add('**${parts[i]}', false);
      } else {
        add(parts[i], i.isOdd);
      }
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final value = text.trim();
    if (value.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final emphasis = TextStyle(
      fontWeight: FontWeight.bold,
      color: theme.colorScheme.primary,
    );
    return Text.rich(
      TextSpan(
        children: [
          for (final segment in segments(value))
            TextSpan(
              text: segment.text,
              style: segment.emphasized ? emphasis : null,
            ),
        ],
      ),
      style: style ?? theme.textTheme.bodyMedium?.copyWith(height: 1.5),
      textAlign: textAlign,
    );
  }
}
