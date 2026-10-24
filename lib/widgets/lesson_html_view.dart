import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:provider/provider.dart';
import 'package:webview_all/webview_all.dart';

import '../services/audio_service.dart';
import 'youtube_embed.dart';

/// A heading found in a lesson, used for the table of contents.
class LessonHeading {
  final int level;
  final String text;
  final String id;

  const LessonHeading(this.level, this.text, this.id);
}

/// Lets a parent widget ask [LessonHtmlView] to scroll to a heading.
class LessonHtmlController {
  void Function(String id)? _scrollTo;

  void scrollToHeading(String id) => _scrollTo?.call(id);
}

/// Renders a whole lesson as one HTML document (Dart `markdown` -> HTML) in a
/// WebView, so the browser handles layout, scrolling and text selection.
class LessonHtmlView extends StatefulWidget {
  final String markdown;
  final LessonHtmlController? controller;

  const LessonHtmlView({super.key, required this.markdown, this.controller});

  /// Converts lesson Markdown (including custom lesson tags) to an HTML body.
  static String markdownToHtmlBody(String markdown) => render(markdown).html;

  /// Top-level headings of a lesson, in document order.
  static List<LessonHeading> extractHeadings(String markdown) =>
      render(markdown).headings;

  /// Renders HTML and collects headings; each heading gets a stable `id`.
  static ({String html, List<LessonHeading> headings}) render(String markdown) {
    final document = md.Document(extensionSet: md.ExtensionSet.gitHubFlavored);
    final nodes = document.parseLines(_preprocess(markdown).split('\n'));
    final headings = <LessonHeading>[];
    for (final node in nodes) {
      if (node is md.Element && RegExp(r'^h[1-6]$').hasMatch(node.tag)) {
        final text = node.textContent.trim();
        if (text.isEmpty) continue;
        final id = 'lesson-h-${headings.length}';
        node.attributes['id'] = id;
        headings.add(LessonHeading(int.parse(node.tag.substring(1)), text, id));
      }
    }
    return (html: md.renderToHtml(nodes), headings: headings);
  }

  static String _preprocess(String markdown) {
    final fencedCodeBlocks = <String>[];
    var text = markdown.replaceAllMapped(
      RegExp(
        r'(^```[\s\S]*?^```[ \t]*$|^~~~[\s\S]*?^~~~[ \t]*$)',
        multiLine: true,
      ),
      (match) {
        fencedCodeBlocks.add(match[0]!);
        return 'LINGUA_CODE_BLOCK_${fencedCodeBlocks.length - 1}';
      },
    );

    const escape = HtmlEscape(HtmlEscapeMode.attribute);
    String? attr(String attributes, String name) => RegExp(
      '$name\\s*=\\s*["\']([^"\']+)["\']',
      caseSensitive: false,
    ).firstMatch(attributes)?.group(1);

    text = text.replaceAll(
      RegExp(r'<(script|style|iframe)\b[\s\S]*?</\1\s*>', caseSensitive: false),
      '',
    );
    text = text.replaceAll(
      RegExp(
        r'<VocabQuiz\b[^>]*>([\s\S]*?)</VocabQuiz\s*>|<VocabQuiz\b[^>]*/?>',
        caseSensitive: false,
      ),
      '',
    );
    text = text.replaceAllMapped(
      RegExp(
        r'<YouTube\b([^>]*?)/>|<YouTube\b([^>]*)>(?:[\s\S]*?</YouTube\s*>)?',
        caseSensitive: false,
      ),
      (match) {
        final embedUrl = YouTubeEmbed.embedUrlFromAttributes(
          match[1] ?? match[2] ?? '',
        );
        if (embedUrl == null) return '';
        return '\n\n<div class="yt" data-src="${escape.convert(embedUrl)}"></div>\n\n';
      },
    );
    text = text.replaceAllMapped(
      RegExp(r'<AudioButton\b([^>]*)/?>', caseSensitive: false),
      (match) {
        final source = attr(match[1] ?? '', 'src');
        if (source == null) return '';
        return '<button class="audio" data-src="${escape.convert(source)}">&#9654;</button>';
      },
    );
    text = text.replaceAllMapped(
      RegExp(r'<TTS\b[^>]*>([\s\S]*?)</TTS\s*>', caseSensitive: false),
      (match) {
        final spoken = (match[1] ?? '')
            .replaceAll(RegExp(r'<[^>]*>'), '')
            .trim();
        if (spoken.isEmpty) return '';
        return '<span class="tts" data-text="${escape.convert(spoken)}">${escape.convert(spoken)} &#128266;</span>';
      },
    );
    text = text.replaceAllMapped(
      RegExp(r'<Details\b([^>]*)>', caseSensitive: false),
      (match) {
        final summary =
            attr(match[1] ?? '', 'summary') ?? attr(match[1] ?? '', 'title');
        return summary == null ? '' : '\n\n**$summary**\n\n';
      },
    );
    // Remaining capitalised tags are lesson components with no HTML meaning.
    text = text.replaceAll(
      RegExp(r'</?[A-Z][A-Za-z0-9:-]*(?:\s[^<>]*)?/?>'),
      '',
    );

    for (var i = 0; i < fencedCodeBlocks.length; i++) {
      text = text.replaceAll('LINGUA_CODE_BLOCK_$i', fencedCodeBlocks[i]);
    }

    return text.replaceAll('\r\n', '\n');
  }

  static String _css(ThemeData theme) {
    String hex(Color c) =>
        '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
    final scheme = theme.colorScheme;
    return '''
:root { color-scheme: ${scheme.brightness == Brightness.dark ? 'dark' : 'light'}; }
html, body { margin: 0; background: ${hex(scheme.surface)}; color: ${hex(scheme.onSurface)}; }
body { font: 16px/1.6 system-ui, -apple-system, "Segoe UI", sans-serif; }
#content { max-width: 900px; margin: 0 auto; padding: 20px 24px 48px; }
a { color: ${hex(scheme.primary)}; }
strong { color: ${hex(scheme.primary)}; }
hr { border: 0; border-top: 1px solid ${hex(theme.dividerColor)}; margin: 1.5em 0; }
code { font-family: ui-monospace, Consolas, monospace; background: ${hex(scheme.surfaceContainerHighest)}; padding: 0.1em 0.3em; border-radius: 4px; }
pre { background: ${hex(scheme.surfaceContainerHighest)}; padding: 12px; border-radius: 6px; overflow-x: auto; }
pre code { padding: 0; background: none; }
blockquote { margin: 1em 0; padding: 0.1em 1em; border-left: 3px solid ${hex(scheme.primary)}; background: ${hex(scheme.surfaceContainerHighest)}; }
table { border-collapse: collapse; display: block; overflow-x: auto; }
th, td { border: 1px solid ${hex(theme.dividerColor)}; padding: 6px 10px; }
img { max-width: 100%; }
.yt { position: relative; width: 100%; max-width: 640px; min-width: 200px; aspect-ratio: 16 / 9; margin: 8px 0; background: #000; border-radius: 8px; overflow: hidden; }
.yt iframe { position: absolute; inset: 0; width: 100%; height: 100%; border: 0; }
.spoiler { filter: blur(5px); cursor: pointer; transition: filter .15s; }
.spoiler:hover, .spoiler.show { filter: none; }
.tts, .audio { cursor: pointer; }
.audio { font-size: 0.8em; padding: 2px 5px; border: none; border-radius: 50%; }
''';
  }

  static String _script(String html) =>
      '''
document.documentElement.innerHTML =
  '<head><meta name="viewport" content="width=device-width, initial-scale=1"><style>' + ${jsonEncode('__CSS__')} + '</style></head><body><div id="content"></div></body>';
document.getElementById('content').innerHTML = ${jsonEncode(html)};
document.querySelectorAll('.yt').forEach(function (el) {
  var u = new URL(el.dataset.src);
  u.host = 'www.youtube-nocookie.com';
  u.searchParams.set('origin', location.origin);
  var f = document.createElement('iframe');
  f.src = u.toString();
  f.allow = 'accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share; fullscreen';
  f.referrerPolicy = 'strict-origin-when-cross-origin';
  f.allowFullscreen = true;
  el.appendChild(f);
});
if (!window.__linguaClick) {
window.__linguaClick = true;
document.addEventListener('click', function (e) {
  var t = e.target.closest ? e.target : e.target.parentElement;
  var spoiler = t.closest('.spoiler');
  if (spoiler) spoiler.classList.toggle('show');
  var audio = t.closest('.audio');
  if (audio) Lingua.postMessage(JSON.stringify({type: 'audio', src: audio.dataset.src}));
  var tts = t.closest('.tts');
  if (tts) Lingua.postMessage(JSON.stringify({type: 'tts', text: tts.dataset.text}));
});
}
''';

  @override
  State<LessonHtmlView> createState() => _LessonHtmlViewState();
}

class _LessonHtmlViewState extends State<LessonHtmlView> {
  // YouTube rejects embeds (Error 153) from pages without a real HTTPS origin,
  // so the document is injected into a harmless youtube-nocookie.com page.
  static const _hostPage = 'https://www.youtube-nocookie.com/robots.txt';

  late final WebViewController _controller;
  bool _pageLoaded = false;
  String? _lastInjected;

  @override
  void initState() {
    super.initState();
    widget.controller?._scrollTo = _scrollTo;
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      // Audio and TTS go through the Flutter AudioService, not the WebView.
      ..addJavaScriptChannel('Lingua', onMessageReceived: _onMessage)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) => request.url == _hostPage
              ? NavigationDecision.navigate
              : NavigationDecision.prevent,
          onPageFinished: (_) {
            _pageLoaded = true;
            _inject();
          },
        ),
      )
      ..loadRequest(Uri.parse(_hostPage));
  }

  @override
  void didUpdateWidget(LessonHtmlView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?._scrollTo = null;
      widget.controller?._scrollTo = _scrollTo;
    }
    if (oldWidget.markdown != widget.markdown) _inject();
  }

  @override
  void dispose() {
    widget.controller?._scrollTo = null;
    super.dispose();
  }

  void _scrollTo(String id) {
    if (!_pageLoaded) return;
    _controller.runJavaScript(
      'var e=document.getElementById(${jsonEncode(id)});'
      "if(e)e.scrollIntoView({behavior:'smooth',block:'start'});",
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _inject();
  }

  void _onMessage(JavaScriptMessage message) {
    if (!mounted) return;
    final Object? data;
    try {
      data = jsonDecode(message.message);
    } on FormatException {
      return;
    }
    if (data is! Map) return;
    final audio = context.read<AudioService>();
    final key = data['type'] == 'tts' ? 'tts_${data['text']}' : data['src'];
    if (audio.isPlaying && audio.currentlyPlayingKey == key) {
      audio.stop();
    } else if (data['type'] == 'tts' && data['text'] is String) {
      audio.speak(data['text'] as String, language: 'ko');
    } else if (data['type'] == 'audio' && data['src'] is String) {
      audio.playAudio(data['src'] as String);
    }
  }

  void _inject() {
    if (!_pageLoaded) return;
    final theme = Theme.of(context);
    final html = LessonHtmlView.markdownToHtmlBody(widget.markdown);
    final script = LessonHtmlView._script(html).replaceFirst(
      jsonEncode('__CSS__'),
      jsonEncode(LessonHtmlView._css(theme)),
    );
    if (script == _lastInjected) return;
    _lastInjected = script;
    _controller.runJavaScript(script);
  }

  @override
  Widget build(BuildContext context) => WebViewWidget(controller: _controller);
}
