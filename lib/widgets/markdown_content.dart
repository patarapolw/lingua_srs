import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import 'audio_button.dart';
import 'cached_markdown_image.dart';
import 'youtube_embed.dart';

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

  static String prepareSpoilerSpans(String input) => input.replaceAllMapped(
    RegExp(
      r'''<span\b(?=[^>]*\bclass\s*=\s*["'][^"']*\bspoiler\b[^"']*["'])[^>]*>([\s\S]*?)</span\s*>''',
      caseSensitive: false,
    ),
    (match) {
      final text = (match[1] ?? '').replaceAll(RegExp(r'<[^>]*>'), '').trim();
      final spoilerUri = Uri(
        scheme: 'lingua-spoiler',
        queryParameters: {'text': text},
      );
      return '![spoiler](<$spoilerUri>)';
    },
  );

  static String prepareYouTube(String input) => input.replaceAllMapped(
    RegExp(
      r'<YouTube\b([^>]*?)/>|<YouTube\b([^>]*)>(?:[\s\S]*?</YouTube\s*>)?',
      caseSensitive: false,
    ),
    (match) {
      final embedUrl = YouTubeEmbed.embedUrlFromAttributes(
        match[1] ?? match[2] ?? '',
      );
      if (embedUrl == null) return '';
      final uri = Uri(
        scheme: 'lingua-youtube',
        queryParameters: {'url': embedUrl},
      );
      return '\n\n![YouTube](<$uri>)\n\n';
    },
  );

  /// Cleans up raw HTML <p> tags into markdown friendly newlines
  String _normalizeContent(String input) {
    String text = prepareYouTube(input);
    // Replace <p> with empty or single newline and </p> with double newlines
    text = text.replaceAll(RegExp(r'<p\s*>', caseSensitive: false), '');
    text = text.replaceAll(RegExp(r'</p\s*>', caseSensitive: false), '\n\n');
    text = text.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
    text = text.replaceAll(
      RegExp(r'<hr\b[^>]*\/?>', caseSensitive: false),
      '\n\n---\n\n',
    );
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
      em: (style ?? theme.textTheme.bodyMedium)?.copyWith(
        fontStyle: FontStyle.italic,
      ),
      code: TextStyle(
        backgroundColor: theme.colorScheme.surfaceContainerHighest,
        fontFamily: 'monospace',
        fontSize: (style?.fontSize ?? 14) * 0.9,
      ),
      horizontalRuleDecoration: BoxDecoration(
        border: Border(top: BorderSide(width: 1, color: theme.dividerColor)),
      ),
    );

    return MarkdownBody(
      data: normalized,
      selectable: selectable,
      styleSheet: mdStyle,
      imageBuilder: (uri, title, alt) {
        if (uri.scheme == 'lingua-spoiler') {
          return SpoilerText(text: uri.queryParameters['text'] ?? '');
        }
        if (uri.scheme == 'lingua-youtube') {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: SizedBox(
              width: (MediaQuery.sizeOf(context).width - 48).clamp(
                200.0,
                640.0,
              ),
              child: YouTubeEmbed(embedUrl: uri.queryParameters['url'] ?? ''),
            ),
          );
        }
        if (uri.scheme == 'lingua-audio') {
          final textToSpeak = uri.queryParameters['text'];
          return AudioButton(
            audioUrl: uri.queryParameters['src'],
            fallbackText: textToSpeak,
            language: 'ko',
            compact: true,
          );
        }
        return CachedMarkdownImage(url: uri.toString());
      },
    );
  }
}

/// Blurs arbitrary content (e.g. rendered Markdown) until tapped or hovered.
class SpoilerBlock extends StatefulWidget {
  final Widget child;

  const SpoilerBlock({super.key, required this.child});

  @override
  State<SpoilerBlock> createState() => _SpoilerBlockState();
}

class _SpoilerBlockState extends State<SpoilerBlock> {
  bool _hovered = false;
  bool _revealedByTap = false;

  bool get _revealed => _hovered || _revealedByTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: _revealed ? null : 'Spoiler. Tap to reveal.',
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _revealedByTap = !_revealedByTap),
          child: _revealed
              ? widget.child
              : ImageFiltered(
                  imageFilter: ui.ImageFilter.blur(sigmaX: 5, sigmaY: 5),
                  child: widget.child,
                ),
        ),
      ),
    );
  }
}

class SpoilerText extends StatefulWidget {
  final String text;

  const SpoilerText({super.key, required this.text});

  @override
  State<SpoilerText> createState() => _SpoilerTextState();
}

class _SpoilerTextState extends State<SpoilerText> {
  bool _hovered = false;
  bool _revealedByTap = false;

  bool get _revealed => _hovered || _revealedByTap;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyMedium;
    return Semantics(
      label: _revealed ? widget.text : 'Spoiler. Tap to reveal.',
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _revealedByTap = !_revealedByTap),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 150),
            child: _revealed
                ? Text(
                    widget.text,
                    key: const ValueKey('revealed'),
                    style: style,
                  )
                : ImageFiltered(
                    key: const ValueKey('blurred'),
                    imageFilter: ui.ImageFilter.blur(sigmaX: 5, sigmaY: 5),
                    child: Text(widget.text, style: style),
                  ),
          ),
        ),
      ),
    );
  }
}
