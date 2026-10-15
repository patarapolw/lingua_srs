import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

class MarkdownContent extends StatelessWidget {
  final String content;
  final TextStyle? style;
  final bool selectable;

  const MarkdownContent({
    super.key,
    required this.content,
    this.style,
    this.selectable = false,
  });

  /// Cleans up raw HTML <p> tags into markdown friendly newlines
  String _normalizeContent(String input) {
    String text = input;
    // Replace <p> with empty or single newline and </p> with double newlines
    text = text.replaceAll(RegExp(r'<p\s*>', caseSensitive: false), '');
    text = text.replaceAll(RegExp(r'</p\s*>', caseSensitive: false), '\n\n');
    text = text.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
    return text.trim();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final normalized = _normalizeContent(content);

    if (normalized.isEmpty) {
      return const SizedBox.shrink();
    }

    final mdStyle = MarkdownStyleSheet.fromTheme(theme).copyWith(
      p: style ?? theme.textTheme.bodyMedium?.copyWith(height: 1.5),
      strong: (style ?? theme.textTheme.bodyMedium)?.copyWith(
        fontWeight: FontWeight.bold,
        color: theme.colorScheme.primary,
      ),
      em: (style ?? theme.textTheme.bodyMedium)?.copyWith(fontStyle: FontStyle.italic),
      code: TextStyle(
        backgroundColor: theme.colorScheme.surfaceContainerHighest,
        fontFamily: 'monospace',
        fontSize: (style?.fontSize ?? 14) * 0.9,
      ),
    );

    return selectable
        ? MarkdownBody(
            data: normalized,
            selectable: true,
            styleSheet: mdStyle,
          )
        : MarkdownBody(
            data: normalized,
            styleSheet: mdStyle,
          );
  }
}
