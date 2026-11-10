import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show RenderAbstractViewport, ScrollCacheExtent;
import 'package:flutter/scheduler.dart';

import '../models/lesson.dart' show looseNameKey;
import '../services/lesson_links.dart';
import 'markdown_content.dart';

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

/// A lesson's Markdown cut into chunks that are rendered lazily, one by one.
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
  static final _headingLine = RegExp(r'^\s{0,3}(#{1,6})\s+(.+?)(?:\s+#+)?\s*$');
  static final _continuationLine = RegExp(r'^(\s|[-*+]\s|\d+[.)]\s|\||>)');
  static final _setextUnderline = RegExp(r'^ {0,3}(=+|-+)[ \t]*$');

  /// Cuts [markdown] into chunks and collects its headings.
  ///
  /// A chunk starts at every heading, and a long section is also cut at a
  /// blank line, but never inside a fenced code block, a list or a table.
  /// `<!-- chunk -->` forces a cut, and everything between
  /// `<!-- chunk:start -->` and `<!-- chunk:end -->` stays in one chunk.
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
      if (fence == null) {
        if (_breakLine.hasMatch(line)) {
          if (!grouped) flush();
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
          if (!grouped) flush();
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
        } else if (!grouped &&
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
  /// `<Details>`, spoiler spans) and `[[lesson links]]` into what
  /// [MarkdownContent] renders, and drops scripts, quizzes, unknown
  /// components and HTML comments. Chunk markers are kept for [parse].
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
    text = text.replaceAllMapped(
      RegExp(r'<Details\b([^>]*)>', caseSensitive: false),
      (match) {
        final summary =
            attr(match[1] ?? '', 'summary') ?? attr(match[1] ?? '', 'title');
        return summary == null ? '' : '\n\n**$summary**\n\n';
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

/// Where a lesson was scrolled to: the chunk at the top of the view and how
/// far into it, and the pixel offset as a fallback above the first chunk.
typedef _SavedScroll = ({int? chunk, double offset, double pixels, int text});

/// Scroll positions of lessons left this session, by [LessonContentView.
/// scrollKey], so going back to the lesson list and opening the lesson again
/// returns to the same place. In memory only.
abstract final class LessonScrollMemory {
  static final Map<String, _SavedScroll> _saved = {};

  /// Forgets every saved position, for tests.
  static void clear() => _saved.clear();
}

/// Renders a lesson natively: its Markdown is cut into chunks (see
/// [LessonContent.parse]) shown in a lazy list, with selectable text.
class LessonContentView extends StatefulWidget {
  final String markdown;

  /// [markdown] already parsed, to avoid parsing it again here.
  final LessonContent? content;
  final LessonContentController? controller;

  /// Called for a tapped link to another lesson, such as
  /// `[[Lesson 26#Past tense]]`. Links to a heading in this lesson scroll to
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
  /// Builds chunks well ahead of the viewport so their heights are measured
  /// early, keeping the scroll extent (and scrollbar) from jumping.
  static const double _cacheExtent = 4000;

  final ScrollController _scroll = ScrollController();
  late LessonContent _content;
  late List<GlobalKey> _keys;
  late List<double?> _chunkHeights;
  final Set<GlobalKey> _pendingMeasurements = {};
  double? _layoutWidth;
  double? _textScale;
  double? _bodyFontSize;

  /// Hides the list while it jumps back to a saved position, so the lesson
  /// does not flash at the top first.
  bool _restoring = false;

  @override
  void initState() {
    super.initState();
    _attach(widget.controller);
    _parse();
    final initialHeading = widget.initialHeading;
    final key = widget.scrollKey;
    final saved = key == null ? null : LessonScrollMemory._saved[key];
    if (initialHeading != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scrollToNamed(initialHeading);
      });
    } else if (saved != null && saved.text == _textHash) {
      _restoring = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _restore(saved));
    }
  }

  int get _textHash => Object.hash(widget.markdown, _content.chunks.length);

  /// The chunk at the top of the view and how far it is scrolled into it.
  _SavedScroll? _position() {
    if (!_scroll.hasClients) return null;
    final pixels = _scroll.position.pixels;
    int? chunk;
    var offset = 0.0;
    for (var index = 0; index < _keys.length; index++) {
      final top = _chunkTop(index);
      if (top == null || top > pixels + 0.5) continue;
      if (chunk == null || index > chunk) {
        chunk = index;
        offset = pixels - top;
      }
    }
    return (chunk: chunk, offset: offset, pixels: pixels, text: _textHash);
  }

  /// The scroll offset at which chunk [index] starts at the top of the view,
  /// or null while it is not built.
  double? _chunkTop(int index) {
    final box = _keys[index].currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    return RenderAbstractViewport.of(box).getOffsetToReveal(box, 0).offset;
  }

  /// Saves where the lesson is scrolled to. With [onlyAnchored], only when a
  /// chunk can still be measured: while the view is being taken down its
  /// chunks may already be detached, and the place saved when scrolling
  /// stopped is better than a bare pixel offset.
  void _savePosition({bool onlyAnchored = false}) {
    final key = widget.scrollKey;
    if (key == null || _restoring) return;
    final position = _position();
    if (position == null || (onlyAnchored && position.chunk == null)) return;
    LessonScrollMemory._saved[key] = position;
  }

  /// Jumps back to [saved]: to its chunk (by its estimated offset until it
  /// is built), then into it, until the place settles.
  Future<void> _restore(_SavedScroll saved) async {
    try {
      for (var attempt = 0; attempt < 10; attempt++) {
        if (!mounted || !_scroll.hasClients) return;
        final position = _scroll.position;
        final chunk = saved.chunk;
        double target;
        if (chunk == null || chunk >= _keys.length) {
          target = saved.pixels;
        } else {
          final top = _chunkTop(chunk);
          target = (top ?? _estimatedOffsetForChunk(chunk)) + saved.offset;
          if (top != null && (position.pixels - target).abs() <= 1) return;
        }
        position.jumpTo(
          target.clamp(position.minScrollExtent, position.maxScrollExtent),
        );
        await SchedulerBinding.instance.endOfFrame;
        if (chunk == null) return;
      }
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
  }

  void _attach(LessonContentController? controller) {
    controller?._scrollTo = _scrollTo;
    controller?._scrollToNamed = _scrollToNamed;
  }

  void _detach(LessonContentController? controller) {
    controller?._scrollTo = null;
    controller?._scrollToNamed = null;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final width = MediaQuery.sizeOf(context).width;
    final textScale = MediaQuery.textScalerOf(context).scale(14);
    final bodyFontSize = Theme.of(context).textTheme.bodyMedium?.fontSize ?? 14;
    if (_layoutWidth != null &&
        (_layoutWidth != width ||
            _textScale != textScale ||
            _bodyFontSize != bodyFontSize)) {
      _chunkHeights = List<double?>.filled(_content.chunks.length, null);
    }
    _layoutWidth = width;
    _textScale = textScale;
    _bodyFontSize = bodyFontSize;
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
    }
  }

  @override
  void deactivate() {
    // Leaving the lesson, such as going back to the list: keep the place,
    // in case scrolling had not settled.
    _savePosition(onlyAnchored: true);
    super.deactivate();
  }

  @override
  void dispose() {
    _detach(widget.controller);
    _scroll.dispose();
    super.dispose();
  }

  void _parse() {
    _content = widget.content ?? LessonContent.parse(widget.markdown);
    _keys = List.generate(_content.chunks.length, (_) => GlobalKey());
    _chunkHeights = List<double?>.filled(_content.chunks.length, null);
  }

  void _recordChunkHeight(int index) {
    final renderObject = _keys[index].currentContext?.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return;
    _chunkHeights[index] = renderObject.size.height;
  }

  void _scheduleChunkMeasurement(int index) {
    final key = _keys[index];
    if (!_pendingMeasurements.add(key)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pendingMeasurements.remove(key);
      if (!mounted || !identical(_keys[index], key)) return;
      _recordChunkHeight(index);
    });
  }

  double _estimatedChunkHeight(int index) {
    final measuredHeight = _chunkHeights[index];
    if (measuredHeight != null) return measuredHeight;

    var measuredCharacters = 0;
    var totalMeasuredHeight = 0.0;
    for (var i = 0; i < _chunkHeights.length; i++) {
      final height = _chunkHeights[i];
      if (height == null) continue;
      measuredCharacters += math.max(1, _content.chunks[i].length);
      totalMeasuredHeight += height;
    }
    if (measuredCharacters > 0) {
      return math.max(
        48,
        _content.chunks[index].length *
            totalMeasuredHeight /
            measuredCharacters,
      );
    }

    final width = math.min(_layoutWidth ?? 900, 900) - 48;
    final charactersPerLine = math.max(1, width / (8 * (_textScale ?? 1)));
    final estimatedLines = _content.chunks[index].length / charactersPerLine;
    return math.max(80, estimatedLines * _bodyFontSize! * 1.5 + 48);
  }

  double _estimatedOffsetForChunk(int index) {
    var offset = 20.0;
    for (var i = 0; i < index; i++) {
      offset += _estimatedChunkHeight(i);
    }
    return offset;
  }

  /// Animates toward an estimated offset, refining it as chunks are measured.
  Future<void> _scrollTo(LessonHeading heading) async {
    final index = heading.chunk;
    if (index < 0 || index >= _keys.length) return;
    for (var attempt = 0; attempt < 10; attempt++) {
      if (!mounted) return;
      final context = _keys[index].currentContext;
      if (context != null) {
        if (!context.mounted) continue;
        await Scrollable.ensureVisible(
          context,
          duration: const Duration(milliseconds: 250),
        );
        return;
      }
      if (!_scroll.hasClients) return;
      final position = _scroll.position;
      final target = _estimatedOffsetForChunk(index)
          .clamp(position.minScrollExtent, position.maxScrollExtent);
      if ((position.pixels - target).abs() > 1) {
        await _scroll.animateTo(
          target,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOutCubic,
        );
      }
      await SchedulerBinding.instance.endOfFrame;
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
  /// and passes links to other lessons to [LessonContentView.onLessonLink].
  bool _onLink(String href) {
    final link = LessonLink.fromHref(href);
    if (link == null) return false;
    if (link.isOtherLesson) {
      widget.onLessonLink?.call(link);
    } else if (!_scrollToNamed(link.heading!)) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('No heading “${link.heading}” in this lesson.')),
      );
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollEndNotification>(
      onNotification: (_) {
        _savePosition();
        return false;
      },
      child: Opacity(opacity: _restoring ? 0 : 1, child: _list(context)),
    );
  }

  Widget _list(BuildContext context) {
    return SelectionArea(
      child: ListView.builder(
        controller: _scroll,
        scrollCacheExtent: const ScrollCacheExtent.pixels(_cacheExtent),
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 48),
        itemCount: _content.chunks.length,
        itemBuilder: (context, index) {
          _scheduleChunkMeasurement(index);
          return NotificationListener<SizeChangedLayoutNotification>(
            onNotification: (_) {
              _recordChunkHeight(index);
              return false;
            },
            child: SizeChangedLayoutNotifier(
              key: _keys[index],
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 900),
                  child: SizedBox(
                    width: double.infinity,
                    child: MarkdownContent(
                      content: _content.chunks[index],
                      onLink: _onLink,
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
