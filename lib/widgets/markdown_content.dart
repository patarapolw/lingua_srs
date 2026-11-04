import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'audio_button.dart';
import 'cached_markdown_image.dart';
import 'youtube_embed.dart';

class MarkdownContent extends StatelessWidget {
  final String content;
  final TextStyle? style;
  final bool selectable;

  /// Called first for every tapped link; return true if it was handled.
  final bool Function(String href)? onLink;

  const MarkdownContent({
    super.key,
    required this.content,
    this.style,
    this.selectable = false,
    this.onLink,
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
    return _prepareHtmlDel(text).trim();
  }

  String _prepareHtmlDel(String input) {
    final code = <String>[];
    var prefix = 'LINGUA_MARKDOWN_CODE_';
    while (input.contains(prefix)) {
      prefix += 'X';
    }

    String protectCode(Match match) {
      code.add(match[0]!);
      return '$prefix${code.length - 1}';
    }

    var text = input.replaceAllMapped(
      RegExp(
        r'(^```[\s\S]*?^```[ \t]*$|^~~~[\s\S]*?^~~~[ \t]*$)',
        multiLine: true,
      ),
      protectCode,
    );
    text = text.replaceAllMapped(RegExp(r'(`+)[^\n]*?\1'), protectCode);
    text = text.replaceAllMapped(
      RegExp(r'<del\b[^>]*>([\s\S]*?)</del\s*>', caseSensitive: false),
      (match) => '~~${match[1]}~~',
    );
    return text.replaceAllMapped(
      RegExp('$prefix(\\d+)'),
      (match) => code[int.parse(match[1]!)],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final normalized = _normalizeContent(content);

    if (normalized.isEmpty) {
      return const SizedBox.shrink();
    }

    final bodyFontSize =
        style?.fontSize ?? theme.textTheme.bodyMedium!.fontSize!;
    TextStyle? headingStyle(TextStyle? base, double sizeEm) => base?.copyWith(
      fontSize: bodyFontSize * sizeEm,
      fontWeight: FontWeight.bold,
    );
    final h1 = headingStyle(theme.textTheme.headlineSmall, 2);
    final h2 = headingStyle(theme.textTheme.titleLarge, 1.5);
    final h3 = headingStyle(theme.textTheme.titleMedium, 1.17);
    final h4 = headingStyle(theme.textTheme.bodyLarge, 1);
    final h5 = headingStyle(theme.textTheme.bodyLarge, 0.83);
    final h6 = headingStyle(theme.textTheme.bodyLarge, 0.67);
    const blockSpacing = 16.0;
    EdgeInsets headingPadding(TextStyle? heading, double marginEm) {
      final margin = (heading?.fontSize ?? bodyFontSize) * marginEm;
      final extraBottomMargin = margin > blockSpacing
          ? margin - blockSpacing
          : 0.0;
      return EdgeInsets.only(top: margin, bottom: extraBottomMargin);
    }

    final mdStyle = MarkdownStyleSheet.fromTheme(theme).copyWith(
      p: style ?? theme.textTheme.bodyMedium?.copyWith(height: 1.5),
      h1: h1,
      h2: h2,
      h3: h3,
      h4: h4,
      h5: h5,
      h6: h6,
      h1Align: WrapAlignment.start,
      h2Align: WrapAlignment.start,
      h3Align: WrapAlignment.start,
      h4Align: WrapAlignment.start,
      h5Align: WrapAlignment.start,
      h6Align: WrapAlignment.start,
      h1Padding: headingPadding(h1, 0.67),
      h2Padding: headingPadding(h2, 0.83),
      h3Padding: headingPadding(h3, 1),
      h4Padding: headingPadding(h4, 1.33),
      h5Padding: headingPadding(h5, 1.67),
      h6Padding: headingPadding(h6, 2.33),
      blockSpacing: blockSpacing,
      strong: (style ?? theme.textTheme.bodyMedium)?.copyWith(
        fontWeight: FontWeight.bold,
        color: theme.colorScheme.primary,
      ),
      em: (style ?? theme.textTheme.bodyMedium)?.copyWith(
        fontStyle: FontStyle.italic,
      ),
      del: const TextStyle(decoration: TextDecoration.lineThrough),
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
      onTapLink: (text, href, title) async {
        if (href == null || (onLink?.call(href) ?? false)) return;
        final uri = Uri.tryParse(href);
        if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
          return;
        }
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      },
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
