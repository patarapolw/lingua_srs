import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/scheduler.dart';

import 'markdown_content.dart';

/// A heading found in a lesson, used for the table of contents.
class LessonHeading {
  final int level;
  final String text;

  /// Index of the chunk the heading starts in (or is inside, in a group).
  final int chunk;

  const LessonHeading(this.level, this.text, this.chunk);
}

/// A lesson's Markdown cut into chunks that are rendered lazily, one by one.
class LessonContent {
  final List<String> chunks;
  final List<LessonHeading> headings;

  const LessonContent(this.chunks, this.headings);

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
          headings.add(
            LessonHeading(
              heading != null ? heading[1]!.length : setextLevel!,
              _plainText(heading != null ? heading[2]! : line.trim()),
              chunks.length,
            ),
          );
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
  /// `<Details>`, spoiler spans) into what [MarkdownContent] renders, and
  /// drops scripts, quizzes, unknown components and HTML comments. Chunk
  /// markers are kept for [parse].
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

    return text.replaceAllMapped(
      RegExp(r'LINGUA_CODE_BLOCK_(\d+)'),
      (match) => fencedCodeBlocks[int.parse(match[1]!)],
    );
  }
}

/// Lets a parent widget ask [LessonContentView] to scroll to a heading.
class LessonContentController {
  void Function(LessonHeading heading)? _scrollTo;

  void scrollToHeading(LessonHeading heading) => _scrollTo?.call(heading);
}

/// Renders a lesson natively: its Markdown is cut into chunks (see
/// [LessonContent.parse]) shown in a lazy list, with selectable text.
class LessonContentView extends StatefulWidget {
  final String markdown;

  /// [markdown] already parsed, to avoid parsing it again here.
  final LessonContent? content;
  final LessonContentController? controller;

  const LessonContentView({
    super.key,
    required this.markdown,
    this.content,
    this.controller,
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

  @override
  void initState() {
    super.initState();
    widget.controller?._scrollTo = _scrollTo;
    _parse();
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
      oldWidget.controller?._scrollTo = null;
      widget.controller?._scrollTo = _scrollTo;
    }
    if (oldWidget.markdown != widget.markdown ||
        oldWidget.content != widget.content) {
      _parse();
    }
  }

  @override
  void dispose() {
    widget.controller?._scrollTo = null;
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

  /// GitHub-style anchor for a heading: `Hello, World!` becomes `hello-world`.
  static String _slug(String text) => text
      .toLowerCase()
      .replaceAll(RegExp(r'[^\p{L}\p{N}\s_-]', unicode: true), '')
      .trim()
      .replaceAll(RegExp(r'\s'), '-');

  /// Handles `#anchor` links by scrolling to the matching heading.
  bool _onLink(String href) {
    if (!href.startsWith('#')) return false;
    String target;
    try {
      target = Uri.decodeComponent(href.substring(1));
    } catch (_) {
      target = href.substring(1);
    }
    target = target.toLowerCase();
    for (final heading in _content.headings) {
      if (_slug(heading.text) == target) {
        _scrollTo(heading);
        break;
      }
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
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
