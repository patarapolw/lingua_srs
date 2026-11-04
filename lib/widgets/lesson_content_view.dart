import 'dart:math' as math;

import 'package:flutter/material.dart';
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
  static final _headingLine = RegExp(
    r'^\s{0,3}(#{1,6})\s+(.+?)(?:\s+#+)?\s*$',
  );
  static final _continuationLine = RegExp(r'^(\s|[-*+]\s|\d+[.)]\s|\||>)');

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
        if (heading != null) {
          if (!grouped) flush();
          headings.add(
            LessonHeading(
              heading[1]!.length,
              _plainText(heading[2]!),
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
    var text = markdown
        .replaceAll('\r\n', '\n')
        .replaceAllMapped(
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
  final LessonContentController? controller;

  const LessonContentView({super.key, required this.markdown, this.controller});

  @override
  State<LessonContentView> createState() => _LessonContentViewState();
}

class _LessonContentViewState extends State<LessonContentView> {
  final ScrollController _scroll = ScrollController();
  late LessonContent _content;
  late List<GlobalKey> _keys;

  @override
  void initState() {
    super.initState();
    widget.controller?._scrollTo = _scrollTo;
    _parse();
  }

  @override
  void didUpdateWidget(LessonContentView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?._scrollTo = null;
      widget.controller?._scrollTo = _scrollTo;
    }
    if (oldWidget.markdown != widget.markdown) _parse();
  }

  @override
  void dispose() {
    widget.controller?._scrollTo = null;
    _scroll.dispose();
    super.dispose();
  }

  void _parse() {
    _content = LessonContent.parse(widget.markdown);
    _keys = List.generate(_content.chunks.length, (_) => GlobalKey());
  }

  /// Chunks far away are not built yet, so jump close to the chunk first and
  /// then align it once it has been built.
  Future<void> _scrollTo(LessonHeading heading) async {
    final index = heading.chunk;
    if (index < 0 || index >= _keys.length) return;
    for (var attempt = 0; attempt < 10; attempt++) {
      if (!mounted) return;
      final context = _keys[index].currentContext;
      if (context != null) {
        await Scrollable.ensureVisible(
          context,
          duration: const Duration(milliseconds: 250),
        );
        return;
      }
      if (!_scroll.hasClients) return;
      final position = _scroll.position;
      final fraction = index / math.max(1, _keys.length - 1);
      _scroll.jumpTo(
        (position.maxScrollExtent * fraction).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        ),
      );
      await SchedulerBinding.instance.endOfFrame;
    }
  }

  @override
  Widget build(BuildContext context) {
    return SelectionArea(
      child: ListView.builder(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 48),
        itemCount: _content.chunks.length,
        itemBuilder: (context, index) => Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: KeyedSubtree(
              key: _keys[index],
              child: MarkdownContent(content: _content.chunks[index]),
            ),
          ),
        ),
      ),
    );
  }
}
