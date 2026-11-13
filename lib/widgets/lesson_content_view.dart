import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_all/webview_all.dart';
import 'package:webview_all_android/webview_all_android.dart';

import '../models/lesson.dart' show looseNameKey;
import '../services/audio_service.dart';
import '../services/lesson_links.dart';
import 'lesson_html.dart';
import 'markdown_content.dart';
import 'youtube_embed.dart';

/// A heading found in a lesson, used for the table of contents.
class LessonHeading {
  final int level;
  final String text;

  /// Index of the chunk the heading starts in (or is inside, in a group).
  final int chunk;

  /// What `#anchor` links to the heading use: its `{#id}`, or a GitHub-style
  /// anchor of its text, with `-1`, `-2`, … for repeated headings.
  final String anchor;

  const LessonHeading(this.level, this.text, this.chunk, {this.anchor = ''});
}

/// A lesson's Markdown cut into chunks, with the headings found in it.
///
/// The reader shows the lesson as one page ([LessonHtml]); the chunks are
/// what [LessonContent.preprocess] and the chunk markers produce from it.
class LessonContent {
  final List<String> chunks;
  final List<LessonHeading> headings;

  const LessonContent(this.chunks, this.headings);

  /// The heading a link names: by its [LessonHeading.anchor] first, then by
  /// its text (the first such heading), then by the letters and digits of
  /// its text. Case does not matter.
  LessonHeading? headingFor(String target) {
    final wanted = target.trim().toLowerCase();
    if (wanted.isEmpty) return null;
    for (final heading in headings) {
      if (heading.anchor.toLowerCase() == wanted) return heading;
    }
    for (final heading in headings) {
      if (LessonLink.headingMatches(heading.text, target)) return heading;
    }
    // An anchor another tool made, such as a site generator's `_1-intro`
    // for `1. Intro`: the same letters and digits.
    final loose = looseNameKey(target);
    for (final heading in headings) {
      if (loose.isNotEmpty && looseNameKey(heading.text) == loose) {
        return heading;
      }
    }
    return null;
  }

  /// A chunk is closed at the next safe blank line once it is this long.
  static const defaultChunkChars = 3000;

  static final _breakLine = RegExp(r'^\s*<!--\s*chunk\s*-->\s*$');
  static final _startLine = RegExp(r'^\s*<!--\s*chunk:start\s*-->\s*$');
  static final _endLine = RegExp(r'^\s*<!--\s*chunk:end\s*-->\s*$');
  static final _fenceLine = RegExp(r'^\s{0,3}(```|~~~)');
  static final _inlineCode = RegExp(r'(`+)[^\n]*?\1');
  static final _detailsOpen = RegExp(r'<details\b', caseSensitive: false);
  static final _detailsClose = RegExp(r'</details\s*>', caseSensitive: false);
  static final _headingLine = RegExp(r'^\s{0,3}(#{1,6})\s+(.+?)(?:\s+#+)?\s*$');
  static final _continuationLine = RegExp(r'^(\s|[-*+]\s|\d+[.)]\s|\||>)');
  static final _setextUnderline = RegExp(r'^ {0,3}(=+|-+)[ \t]*$');

  /// Cuts [markdown] into chunks and collects its headings.
  ///
  /// A chunk starts at every heading, and a long section is also cut at a
  /// blank line, but never inside a fenced code block, a list or a table.
  /// `<!-- chunk -->` forces a cut, and everything between
  /// `<!-- chunk:start -->` and `<!-- chunk:end -->` stays in one chunk. So
  /// does a `<details>` block, which is shown and hidden as a whole.
  static LessonContent parse(
    String markdown, {
    int maxChars = defaultChunkChars,
  }) {
    final lines = preprocess(markdown).split('\n');
    final chunks = <String>[];
    final headings = <LessonHeading>[];
    var current = <String>[];
    var size = 0;
    var grouped = false;
    var detailsDepth = 0;
    String? fence;
    final anchors = <String>{};

    String anchorFor(String text, String? id) {
      if (id != null) {
        anchors.add(id.toLowerCase());
        return id;
      }
      final base = LessonLink.slug(text);
      var anchor = base;
      for (var n = 1; !anchors.add(anchor); n++) {
        anchor = '$base-$n';
      }
      return anchor;
    }

    void flush() {
      final text = current.join('\n').trim();
      if (text.isNotEmpty) chunks.add(text);
      current = [];
      size = 0;
    }

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      // Whether this line is inside a block that must stay in one chunk.
      final whole = grouped || detailsDepth > 0;
      if (fence == null) {
        final text = line.replaceAll(_inlineCode, '');
        detailsDepth += _detailsOpen.allMatches(text).length;
        detailsDepth -= _detailsClose.allMatches(text).length;
        if (detailsDepth < 0) detailsDepth = 0;
        if (_breakLine.hasMatch(line)) {
          if (!whole) flush();
          continue;
        }
        if (_startLine.hasMatch(line)) {
          flush();
          grouped = true;
          continue;
        }
        if (_endLine.hasMatch(line)) {
          grouped = false;
          flush();
          continue;
        }
      }

      final fenceMatch = _fenceLine.firstMatch(line);
      if (fenceMatch != null) {
        if (fence == null) {
          fence = fenceMatch[1];
        } else if (fence == fenceMatch[1]) {
          fence = null;
        }
      } else if (fence == null) {
        final heading = _headingLine.firstMatch(line);
        final setextLevel = _setextLevel(lines, i);
        if (heading != null || setextLevel != null) {
          if (!whole) flush();
          final raw = heading != null ? heading[2]! : line.trim();
          final (title, id) = LessonLink.splitHeadingAttributes(raw);
          final text = _plainText(title);
          headings.add(
            LessonHeading(
              heading != null ? heading[1]!.length : setextLevel!,
              text,
              chunks.length,
              anchor: anchorFor(text, id),
            ),
          );
          if (title != raw) {
            current.add(
              heading != null ? '${heading[1]} ${title.trim()}' : title,
            );
            size += line.length + 1;
            continue;
          }
        } else if (!whole &&
            size >= maxChars &&
            line.trim().isEmpty &&
            _canCutBefore(lines, i + 1)) {
          flush();
          continue;
        }
      }
      current.add(line);
      size += line.length + 1;
    }
    flush();
    return LessonContent(chunks, headings);
  }

  /// The level of a `Title` over `=====` (1) or `-----` (2) heading whose
  /// title is the line at [index], or null if it is not one.
  static int? _setextLevel(List<String> lines, int index) {
    if (index + 1 >= lines.length) return null;
    final line = lines[index];
    if (line.trim().isEmpty ||
        _continuationLine.hasMatch(line) ||
        _fenceLine.hasMatch(line) ||
        _headingLine.hasMatch(line) ||
        _setextUnderline.hasMatch(line)) {
      return null;
    }
    if (index > 0) {
      final previous = lines[index - 1];
      if (previous.trim().isNotEmpty &&
          !_breakLine.hasMatch(previous) &&
          !_startLine.hasMatch(previous) &&
          !_endLine.hasMatch(previous)) {
        return null;
      }
    }
    final underline = _setextUnderline.firstMatch(lines[index + 1]);
    if (underline == null) return null;
    return underline[1]!.startsWith('=') ? 1 : 2;
  }

  /// Whether the block starting at the first non-blank line from [index] is a
  /// new top-level block, so a chunk may end before it.
  static bool _canCutBefore(List<String> lines, int index) {
    for (var i = index; i < lines.length; i++) {
      if (lines[i].trim().isEmpty) continue;
      return !_continuationLine.hasMatch(lines[i]);
    }
    return false;
  }

  static String _plainText(String heading) => heading
      .replaceAllMapped(RegExp(r'\[([^\]]*)\]\([^)]*\)'), (m) => m[1]!)
      .replaceAll(RegExp(r'<[^>]*>'), '')
      .replaceAll(RegExp(r'[*_`~]'), '')
      .trim();

  /// Turns the lesson components (`<YouTube>`, `<AudioButton>`, `<TTS>`,
  /// spoiler spans) and `[[lesson links]]` into what [MarkdownContent]
  /// renders, and drops scripts, quizzes, unknown components and HTML
  /// comments. Chunk markers and `<details>` blocks are
  /// kept: the first for [parse], the second for [MarkdownContent].
  static String preprocess(String markdown) {
    final fencedCodeBlocks = <String>[];
    var text = markdown.replaceAll('\r\n', '\n').replaceAllMapped(
      RegExp(
        r'(^```[\s\S]*?^```[ \t]*$|^~~~[\s\S]*?^~~~[ \t]*$)',
        multiLine: true,
      ),
      (match) {
        fencedCodeBlocks.add(match[0]!);
        return 'LINGUA_CODE_BLOCK_${fencedCodeBlocks.length - 1}';
      },
    );

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
    text = MarkdownContent.prepareYouTube(text);
    text = text.replaceAllMapped(
      RegExp(r'<AudioButton\b([^>]*)/?>', caseSensitive: false),
      (match) {
        final source = attr(match[1] ?? '', 'src');
        if (source == null) return '';
        final uri = Uri(
          scheme: 'lingua-audio',
          queryParameters: {'src': source},
        );
        return '![audio](<$uri>)';
      },
    );
    text = text.replaceAllMapped(
      RegExp(r'<TTS\b[^>]*>([\s\S]*?)</TTS\s*>', caseSensitive: false),
      (match) {
        final spoken = (match[1] ?? '')
            .replaceAll(RegExp(r'<[^>]*>'), '')
            .trim();
        if (spoken.isEmpty) return '';
        final uri = Uri(
          scheme: 'lingua-audio',
          queryParameters: {'text': spoken},
        );
        return '$spoken ![tts](<$uri>)';
      },
    );
    text = MarkdownContent.prepareSpoilerSpans(text);
    // Remaining capitalised tags are lesson components with no meaning here.
    text = text.replaceAll(
      RegExp(r'</?[A-Z][A-Za-z0-9:-]*(?:\s[^<>]*)?/?>'),
      '',
    );
    text = text.replaceAll(
      RegExp(r'<!--(?!\s*chunk(?::start|:end)?\s*-->)[\s\S]*?-->'),
      '',
    );
    text = LessonLink.prepareWikiLinks(text);

    return text.replaceAllMapped(
      RegExp(r'LINGUA_CODE_BLOCK_(\d+)'),
      (match) => fencedCodeBlocks[int.parse(match[1]!)],
    );
  }
}

/// Lets a parent widget ask [LessonContentView] to scroll to a heading.
class LessonContentController {
  void Function(LessonHeading heading)? _scrollTo;
  bool Function(String target)? _scrollToNamed;

  void scrollToHeading(LessonHeading heading) => _scrollTo?.call(heading);

  /// Scrolls to the first heading whose text or anchor is [target]; returns
  /// false if there is none.
  bool scrollToHeadingNamed(String target) =>
      _scrollToNamed?.call(target) ?? false;
}

/// Where a lesson was scrolled to, in pixels, and a hash of its text.
typedef _SavedScroll = ({double pixels, int text});

/// Scroll positions of lessons left this session, by [LessonContentView.
/// scrollKey], so going back to the lesson list and opening the lesson again
/// returns to the same place. In memory only.
abstract final class LessonScrollMemory {
  static final Map<String, _SavedScroll> _saved = {};

  /// Forgets every saved position, for tests.
  static void clear() => _saved.clear();
}

/// Shows a lesson as one HTML page in a WebView ([LessonHtml]), so the browser
/// lays out the Markdown and the HTML in it, scrolls and selects the text.
class LessonContentView extends StatefulWidget {
  final String markdown;

  /// [markdown] already parsed, to avoid parsing it again here.
  final LessonContent? content;
  final LessonContentController? controller;

  /// Called for a tapped link to another lesson, such as
  /// `[[Lesson 1#Past tense]]`. Links to a heading in this lesson scroll to
  /// it without calling this.
  final void Function(LessonLink link)? onLessonLink;

  /// Text or anchor of a heading to scroll to once the lesson is shown.
  final String? initialHeading;

  /// Keeps the scroll position under this key ([LessonScrollMemory]), such as
  /// the lesson's id, and returns to it when the lesson is shown again,
  /// unless [initialHeading] is given or the text has changed.
  final String? scrollKey;

  const LessonContentView({
    super.key,
    required this.markdown,
    this.content,
    this.controller,
    this.onLessonLink,
    this.initialHeading,
    this.scrollKey,
  });

  @override
  State<LessonContentView> createState() => _LessonContentViewState();
}

class _LessonContentViewState extends State<LessonContentView> {
  // On Windows the WebView ignores the base URL of an HTML string, so the
  // page would have no real HTTPS origin and YouTube would reject its embeds
  // (Error 153). There, load a harmless youtube-nocookie.com page and replace
  // its document. Elsewhere the page is loaded locally with that base URL.
  static const _windowsHostPage = 'https://www.youtube-nocookie.com/robots.txt';

  static bool get _useHostPage =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  final WebViewController _web = WebViewController();
  late final Future<void> _configured = _configure();
  late LessonContent _content;
  late String _body;
  String? _shownCss;
  String? _shownBody;

  /// Whether the page is being loaded, so the navigation to it is allowed.
  bool _loading = true;

  /// What to run once the page has loaded: the Windows injection, then a
  /// scroll asked for meanwhile.
  String? _injection;
  String? _pendingAnchor;

  /// The regular YouTube link of the video last started, for a link out of
  /// its player that the WebView cannot follow (`intent:` on Android).
  String? _playingWatch;

  /// The first page opens at this heading or, after it was left, at the
  /// saved place. Later reloads (a new theme) keep the current place.
  String? _startAnchor;
  double _scrollY = 0;

  @override
  void initState() {
    super.initState();
    _attach(widget.controller);
    _parse();
    final key = widget.scrollKey;
    final saved = key == null ? null : LessonScrollMemory._saved[key];
    final initialHeading = widget.initialHeading;
    if (initialHeading != null) {
      _startAnchor = _content.headingFor(initialHeading)?.anchor;
    } else if (saved != null && saved.text == _textHash) {
      _scrollY = saved.pixels;
    }
    _configured;
  }

  int get _textHash => Object.hash(widget.markdown, _content.chunks.length);

  void _parse() {
    _content = widget.content ?? LessonContent.parse(widget.markdown);
    _body = LessonHtml.body(_content);
  }

  void _attach(LessonContentController? controller) {
    controller?._scrollTo = _scrollTo;
    controller?._scrollToNamed = _scrollToNamed;
  }

  void _detach(LessonContentController? controller) {
    controller?._scrollTo = null;
    controller?._scrollToNamed = null;
  }

  Future<void> _configure() async {
    final platform = _web.platform;
    if (platform is AndroidWebViewController) {
      // A tap on a video's thumbnail is a gesture in the page; let the
      // player start without another one.
      try {
        await platform.setMediaPlaybackRequiresUserGesture(false);
      } catch (_) {}
    }
    await _web.setJavaScriptMode(JavaScriptMode.unrestricted);
    // Audio, text-to-speech, links and the scroll position go through the
    // app, not the WebView.
    await _web.addJavaScriptChannel('Lingua', onMessageReceived: _onMessage);
    await _web.setNavigationDelegate(
      NavigationDelegate(
        onNavigationRequest: _onNavigationRequest,
        onPageFinished: (_) => _onPageFinished(),
      ),
    );
  }

  NavigationDecision _onNavigationRequest(NavigationRequest request) {
    if (!mounted) return NavigationDecision.prevent;
    // The player's own links (the YouTube logo, "Watch on YouTube") leave
    // the app. Everything else is prevented once the page has loaded: links
    // in the lesson are handled by [_onLink].
    if (YouTubeEmbed.leavesPlayer(request.url)) {
      _launch(Uri.parse(request.url));
      return NavigationDecision.prevent;
    }
    if (request.isMainFrame) {
      return _loading
          ? NavigationDecision.navigate
          : NavigationDecision.prevent;
    }
    return NavigationDecision.navigate;
  }

  void _onPageFinished() {
    if (!mounted) return;
    final injection = _injection;
    _injection = null;
    if (injection != null) {
      _web.runJavaScript(injection);
    }
    _loading = false;
    final anchor = _pendingAnchor;
    _pendingAnchor = null;
    if (anchor != null) _runScrollTo(anchor);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _show();
  }

  @override
  void didUpdateWidget(LessonContentView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _detach(oldWidget.controller);
      _attach(widget.controller);
    }
    if (oldWidget.markdown != widget.markdown ||
        oldWidget.content != widget.content) {
      _parse();
      _show();
    }
  }

  @override
  void dispose() {
    _detach(widget.controller);
    super.dispose();
  }

  /// Loads the lesson page, unless the WebView already shows it.
  Future<void> _show() async {
    await _configured;
    if (!mounted) return;
    final theme = Theme.of(context);
    final fontSize = MediaQuery.textScalerOf(context).scale(16);
    final css = LessonHtml.css(theme, fontSize: fontSize);
    if (css == _shownCss && _body == _shownBody) return;
    _shownCss = css;
    _shownBody = _body;
    final start = LessonHtml.start(scrollY: _scrollY, anchor: _startAnchor);
    _startAnchor = null;
    _loading = true;
    try {
      await _web.setBackgroundColor(theme.colorScheme.surface);
    } catch (_) {}
    if (_useHostPage) {
      _injection = LessonHtml.injection(css, _body, start: start);
      await _web.loadRequest(Uri.parse(_windowsHostPage));
    } else {
      _injection = null;
      await _web.loadHtmlString(
        LessonHtml.page(css, _body, start: start),
        baseUrl: '${YouTubeEmbed.playerOrigin}/',
      );
    }
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
    switch (data['type']) {
      case 'scroll':
        final y = data['y'];
        if (y is num) _rememberScroll(y.toDouble());
      case 'youtube':
        final watch = data['watch'];
        _playingWatch = watch is String && watch.isNotEmpty ? watch : null;
      case 'link':
        final href = data['href'];
        if (href is String) _onLink(href);
      case 'audio':
      case 'tts':
        _playAudio(data);
    }
  }

  void _rememberScroll(double y) {
    _scrollY = y;
    final key = widget.scrollKey;
    if (key != null) {
      LessonScrollMemory._saved[key] = (pixels: y, text: _textHash);
    }
  }

  void _playAudio(Map<dynamic, dynamic> data) {
    final audio = context.read<AudioService>();
    final isTts = data['type'] == 'tts';
    final source = isTts ? data['text'] : data['src'];
    if (source is! String || source.trim().isEmpty) return;
    final key = isTts ? 'tts_${source.trim()}' : source.trim();
    if (audio.isPlaying && audio.currentlyPlayingKey == key) {
      audio.stop();
    } else if (isTts) {
      audio.speak(source, language: 'ko');
    } else {
      audio.playAudio(source);
    }
  }

  void _runScrollTo(String anchor) {
    _web.runJavaScript('linguaScrollTo(${jsonEncode(anchor)}, true);');
  }

  void _scrollTo(LessonHeading heading) {
    if (_loading) {
      _pendingAnchor = heading.anchor;
    } else {
      _runScrollTo(heading.anchor);
    }
  }

  /// Scrolls to the heading [target] names (see [LessonContent.headingFor]).
  bool _scrollToNamed(String target) {
    final heading = _content.headingFor(target);
    if (heading == null) return false;
    _scrollTo(heading);
    return true;
  }

  /// Handles `#anchor` and `[[#Heading]]` links by scrolling to the heading,
  /// passes links to other lessons to [LessonContentView.onLessonLink], and
  /// opens web links outside the app.
  Future<void> _onLink(String href) async {
    final link = LessonLink.fromHref(href);
    if (link == null) {
      final uri = Uri.tryParse(href);
      if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
        await _launch(uri);
      }
      return;
    }
    if (link.isOtherLesson) {
      widget.onLessonLink?.call(link);
    } else if (!_scrollToNamed(link.heading!)) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('No heading “${link.heading}” in this lesson.')),
      );
    }
  }

  Future<void> _launch(Uri uri) async {
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      // `intent:` and `vnd.youtube:` links from the player: open the regular
      // YouTube link of the video instead, when there is one.
      final watch = _playingWatch;
      if (watch == null) return;
      uri = Uri.parse(watch);
    }
    final opened = await YouTubeEmbed.openExternally(
      uri,
      (url, mode) => launchUrl(url, mode: mode),
    );
    if (!opened && mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Could not open the link.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) => WebViewWidget(controller: _web);
}
