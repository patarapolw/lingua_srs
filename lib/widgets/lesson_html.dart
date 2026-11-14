import 'dart:convert';

import 'package:material_ui/material_ui.dart' show Brightness, Color, ThemeData;
import 'package:markdown/markdown.dart' as md;

import '../models/lesson.dart' show looseNameKey;
import 'lesson_content_view.dart' show LessonContent;
import 'youtube_embed.dart';

/// Turns a lesson into the HTML page [LessonContentView] shows in a WebView,
/// so the browser lays out the text, HTML in the Markdown included, and
/// scrolls and selects it.
abstract final class LessonHtml {
  /// The lesson as an HTML body: its Markdown (see [LessonContent.preprocess])
  /// rendered with GitHub-flavoured extensions, raw HTML kept.
  ///
  /// Headings get the `id` of the matching [LessonContent.headings] entry,
  /// so `#anchor` links and the table of contents can find them. Lesson
  /// components become elements the page script brings to life: `.yt`
  /// (YouTube), `button.audio`, `button.tts` and `.spoiler`.
  static String body(LessonContent content) {
    final document = md.Document(extensionSet: md.ExtensionSet.gitHubFlavored);
    final nodes = document.parseLines(content.chunks.join('\n\n').split('\n'));
    _transform(nodes, _HeadingIds(content));
    return _withoutHandlers(md.renderToHtml(nodes));
  }

  static final _tagWithHandler = RegExp(
    r'''(<[a-zA-Z][^<>]*?)\s+on[a-zA-Z]+\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)''',
  );

  /// Drops `onclick="…"` and the like from tags, which would run script in
  /// the page. Scripts themselves are removed by [LessonContent.preprocess].
  static String _withoutHandlers(String html) {
    var text = html;
    for (var i = 0; i < 8; i++) {
      final next = text.replaceAllMapped(_tagWithHandler, (m) => m[1]!);
      if (next == text) break;
      text = next;
    }
    return text;
  }

  static final _headingTag = RegExp(r'^h[1-6]$');

  static void _transform(List<md.Node> nodes, _HeadingIds headings) {
    for (var i = 0; i < nodes.length; i++) {
      final node = nodes[i];
      if (node is! md.Element) continue;
      final replacement = _component(node);
      if (replacement != null) {
        nodes[i] = replacement;
        continue;
      }
      if (_headingTag.hasMatch(node.tag)) headings.assign(node);
      if (node.tag == 'img') node.attributes['loading'] = 'lazy';
      final children = node.children;
      if (children != null) _transform(children, headings);
    }
  }

  /// The element for a `lingua-…:` image that [LessonContent.preprocess]
  /// wrote for a lesson component, or null for anything else. A paragraph
  /// that is only a YouTube embed is replaced as a whole.
  static md.Element? _component(md.Element element) {
    if (element.tag == 'p') {
      final children = element.children;
      if (children != null && children.length == 1) {
        final only = children.first;
        if (only is md.Element && _scheme(only) == 'lingua-youtube') {
          return _component(only);
        }
      }
      return null;
    }
    if (element.tag != 'img') return null;
    final uri = Uri.tryParse(element.attributes['src'] ?? '');
    if (uri == null) return null;
    final params = uri.queryParameters;
    switch (uri.scheme) {
      case 'lingua-youtube':
        final embedUrl = params['url'] ?? '';
        final thumbnail = YouTubeEmbed.thumbnailUrl(embedUrl);
        final watch = YouTubeEmbed.watchUrl(embedUrl);
        final oEmbed = YouTubeEmbed.oEmbedUrl(embedUrl);
        final player = md.Element('div', [
          // The title the native player shows over its thumbnail; the page
          // script fills it in from `data-oembed`.
          if (thumbnail != null && oEmbed != null)
            md.Element('div', [md.Text('Loading video title…')])
              ..attributes['class'] = 'yt-title',
          md.Element('span', [])..attributes['class'] = 'play',
        ]);
        if (thumbnail != null && oEmbed != null) {
          player.attributes['data-oembed'] = oEmbed.toString();
        }
        player.attributes['class'] = 'yt';
        player.attributes['data-src'] = YouTubeEmbed.playerSrc(embedUrl);
        if (thumbnail != null) player.attributes['data-thumb'] = thumbnail;
        if (watch != null) player.attributes['data-watch'] = watch;
        player.attributes['role'] = 'button';
        player.attributes['aria-label'] = 'Play video';
        if (watch == null) return player;
        // The regular YouTube link, for when the embed cannot play (YouTube
        // forbids the iframe, or the WebView cannot show it).
        final open = md.Element('a', [md.Text('Open on YouTube')]);
        open.attributes['class'] = 'yt-open';
        open.attributes['href'] = watch;
        return md.Element('div', [player, open])
          ..attributes['class'] = 'yt-wrap';
      case 'lingua-spoiler':
        final text = params['text'] ?? '';
        final inline = md.markdownToHtml(
          text,
          extensionSet: md.ExtensionSet.gitHubFlavored,
          inlineOnly: true,
        );
        return md.Element('span', [md.Text(inline)])
          ..attributes['class'] = 'spoiler'
          ..attributes['title'] = 'Tap to reveal';
      case 'lingua-audio':
        final source = params['src'];
        final spoken = params['text'];
        if (source == null && spoken == null) return null;
        return md.Element('button', [md.Text('&#128266;')])
          ..attributes['type'] = 'button'
          ..attributes['class'] = source != null ? 'audio' : 'tts'
          ..attributes[source != null ? 'data-src' : 'data-text'] =
              (source ?? spoken)!
          ..attributes['aria-label'] = source != null
              ? 'Play audio'
              : 'Read aloud';
    }
    return null;
  }

  static String? _scheme(md.Element element) =>
      Uri.tryParse(element.attributes['src'] ?? '')?.scheme;

  /// The CSS of the page, from the app's [theme]. [fontSize] is the body
  /// text size in logical pixels (the user's text scale applied).
  static String css(ThemeData theme, {double fontSize = 16}) {
    String hex(Color c) =>
        '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
    final scheme = theme.colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    return '''
:root { color-scheme: ${dark ? 'dark' : 'light'}; }
html, body { margin: 0; background: ${hex(scheme.surface)}; color: ${hex(scheme.onSurface)}; }
body { font: ${fontSize.toStringAsFixed(1)}px/1.6 system-ui, -apple-system, "Segoe UI", "Noto Sans", sans-serif; overflow-wrap: anywhere; -webkit-text-size-adjust: 100%; }
#content { max-width: 900px; margin: 0 auto; padding: 20px 24px 48px; }
h1, h2, h3, h4, h5, h6 { line-height: 1.3; scroll-margin-top: 8px; }
a { color: ${hex(scheme.primary)}; }
strong { color: ${hex(scheme.primary)}; }
hr { border: 0; border-top: 1px solid ${hex(theme.dividerColor)}; margin: 1.5em 0; }
code { font-family: ui-monospace, Consolas, monospace; font-size: 0.9em; background: ${hex(scheme.surfaceContainerHighest)}; padding: 0.1em 0.3em; border-radius: 4px; }
pre { background: ${hex(scheme.surfaceContainerHighest)}; padding: 12px; border-radius: 6px; overflow-x: auto; }
pre code { padding: 0; background: none; }
blockquote { margin: 1em 0; padding: 0.1em 1em; border-left: 3px solid ${hex(scheme.primary)}; background: ${hex(scheme.surfaceContainerHighest)}; }
table { border-collapse: collapse; display: block; overflow-x: auto; max-width: 100%; }
th, td { border: 1px solid ${hex(theme.dividerColor)}; padding: 6px 10px; }
img, video { max-width: 100%; height: auto; }
mark { background: ${dark ? '#665c00' : '#fff3a3'}; color: inherit; }
details { margin: 1em 0; }
summary { cursor: pointer; font-weight: bold; }
.yt { position: relative; width: 100%; max-width: 640px; aspect-ratio: 16 / 9; margin: 8px 0; background: #000 center / cover no-repeat; border-radius: 8px; overflow: hidden; cursor: pointer; }
.yt .yt-title { position: absolute; left: 0; right: 0; top: 0; padding: 10px 12px 24px; color: #fff; font-weight: 600; font-size: 16px; line-height: 1.3; background: linear-gradient(rgba(0,0,0,.87), transparent); display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; pointer-events: none; }
.yt .play { position: absolute; left: 50%; top: 50%; width: 64px; height: 44px; margin: -22px 0 0 -32px; border-radius: 12px; background: rgba(0,0,0,.7); }
.yt .play::after { content: ""; position: absolute; left: 25px; top: 12px; border: 10px solid transparent; border-left: 17px solid #fff; }
.yt-wrap { margin: 8px 0; }
.yt-wrap .yt { margin: 0 0 4px; }
.yt-open { font-size: 0.85em; }
.yt iframe { position: absolute; inset: 0; width: 100%; height: 100%; border: 0; }
.spoiler { filter: blur(5px); cursor: pointer; transition: filter .15s; }
.spoiler:hover, .spoiler.show { filter: none; }
button.audio, button.tts { font-size: 0.8em; padding: 2px 6px; margin: 0 2px; border: none; border-radius: 50%; cursor: pointer; background: ${hex(scheme.surfaceContainerHighest)}; color: ${hex(scheme.onSurface)}; }
''';
  }

  /// The page script: brings the components to life, reports taps and the
  /// scroll position to the app (the `Lingua` channel), and defines
  /// `linguaScrollTo(anchor, smooth)` and `linguaStart(y, anchor)`.
  static const script = r'''
function linguaPost(message) {
  if (window.Lingua) window.Lingua.postMessage(JSON.stringify(message));
}
window.linguaScrollTo = function (anchor, smooth) {
  var headings = document.querySelectorAll('h1,h2,h3,h4,h5,h6');
  for (var i = 0; i < headings.length; i++) {
    if (headings[i].id === anchor) {
      headings[i].scrollIntoView({behavior: smooth ? 'smooth' : 'auto', block: 'start'});
      return true;
    }
  }
  return false;
};
window.linguaStart = function (y, anchor) {
  var go = function () {
    if (anchor) window.linguaScrollTo(anchor, false); else window.scrollTo(0, y);
  };
  go();
  // Images and embeds above the place shift it as they load.
  window.addEventListener('load', function () { if (!window.__linguaMoved) go(); });
};
if (!window.__linguaBound) {
  window.__linguaBound = true;
  var timer;
  ['wheel', 'touchstart', 'mousedown', 'keydown'].forEach(function (name) {
    window.addEventListener(name, function () { window.__linguaMoved = true; }, {passive: true});
  });
  window.addEventListener('scroll', function () {
    clearTimeout(timer);
    timer = setTimeout(function () { linguaPost({type: 'scroll', y: window.scrollY}); }, 200);
  }, {passive: true});
  document.addEventListener('click', function (e) {
    var t = e.target.nodeType === 1 ? e.target : e.target.parentElement;
    if (!t || !t.closest) return;
    var yt = t.closest('.yt');
    if (yt && !yt.querySelector('iframe')) {
      var frame = document.createElement('iframe');
      linguaPost({type: 'youtube', watch: yt.dataset.watch || ''});
      var src = new URL(yt.dataset.src);
      if (location.origin !== 'null') {
        src.searchParams.set('origin', location.origin);
      }
      frame.src = src.toString();
      frame.allow = 'accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share; fullscreen';
      frame.referrerPolicy = 'strict-origin-when-cross-origin';
      frame.allowFullscreen = true;
      yt.appendChild(frame);
      return;
    }
    var spoiler = t.closest('.spoiler');
    if (spoiler) spoiler.classList.toggle('show');
    var audio = t.closest('button.audio');
    if (audio) { linguaPost({type: 'audio', src: audio.dataset.src}); return; }
    var tts = t.closest('button.tts');
    if (tts) { linguaPost({type: 'tts', text: tts.dataset.text}); return; }
    var link = t.closest('a[href]');
    if (link) {
      e.preventDefault();
      linguaPost({type: 'link', href: link.getAttribute('href')});
    }
  });
}
document.querySelectorAll('.yt').forEach(function (el) {
  if (el.dataset.thumb) el.style.backgroundImage = 'url("' + el.dataset.thumb + '")';
  var title = el.querySelector('.yt-title');
  if (title && el.dataset.oembed && !el.dataset.titled) {
    el.dataset.titled = '1';
    fetch(el.dataset.oembed).then(function (r) {
      if (!r.ok) throw new Error(r.status);
      return r.json();
    }).then(function (j) {
      title.textContent = j && j.title ? j.title : 'Video title unavailable';
    }).catch(function () { title.textContent = 'Video title unavailable'; });
  }
});
''';

  static String _json(Object? value) =>
      jsonEncode(value).replaceAll('<', r'\u003c');

  /// The call that starts the page at [scrollY], or at the heading [anchor].
  static String start({double scrollY = 0, String? anchor}) =>
      'linguaStart(${_json(scrollY)}, ${_json(anchor)});';

  /// What goes inside `<html>`: the head, with [css], and the lesson [body].
  static String inner(String css, String body) =>
      '<head><meta charset="utf-8">'
      '<meta name="viewport" content="width=device-width, initial-scale=1">'
      '<style>$css</style></head>'
      '<body><div id="content">$body</div>';

  /// A whole page, for a WebView that can load an HTML string.
  static String page(String css, String body, {String start = ''}) =>
      '<!DOCTYPE html><html>${inner(css, body)}'
      '<script>$script\n$start</script></body></html>';

  /// A script that replaces the page of the WebView with this lesson, for
  /// platforms that cannot load an HTML string with a base URL.
  static String injection(String css, String body, {String start = ''}) =>
      'document.documentElement.innerHTML = ${_json('${inner(css, body)}</body>')};\n'
      '$script\n$start';
}

/// Hands the ids of [LessonContent.headings] to the heading elements, in
/// order. A heading the parser did not list (one in a quote) gets none.
class _HeadingIds {
  _HeadingIds(this.content);

  final LessonContent content;
  var _next = 0;

  void assign(md.Element element) {
    final key = looseNameKey(element.textContent);
    final headings = content.headings;
    for (var i = _next; i < headings.length; i++) {
      if (looseNameKey(headings[i].text) == key) {
        element.attributes['id'] = headings[i].anchor;
        _next = i + 1;
        return;
      }
    }
  }
}
