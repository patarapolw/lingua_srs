import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/lesson.dart';
import '../providers/app_provider.dart';
import '../widgets/markdown_content.dart';
import 'lesson_detail_view.dart';

class LessonReaderView extends StatelessWidget {
  final String lessonId;

  const LessonReaderView({super.key, required this.lessonId});

  @override
  Widget build(BuildContext context) {
    Lesson? lesson;
    for (final candidate in context.watch<AppProvider>().lessons) {
      if (candidate.id == lessonId) {
        lesson = candidate;
        break;
      }
    }

    if (lesson == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Lesson Not Found')),
        body: const Center(child: Text('This lesson could not be found.')),
      );
    }
    final selectedLesson = lesson;

    return Scaffold(
      appBar: AppBar(
        title: Text(selectedLesson.displayTitle),
        actions: [
          IconButton(
            tooltip: 'Edit Markdown',
            icon: const Icon(Icons.edit_outlined),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => _LessonMarkdownEditor(lesson: selectedLesson),
                ),
              );
            },
          ),
          TextButton.icon(
            icon: const Icon(Icons.menu_book_outlined),
            label: const Text('View Vocabulary'),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => LessonDetailView(lessonId: selectedLesson.id),
                ),
              );
            },
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: selectedLesson.markdownContent.trim().isEmpty
          ? _emptyLessonContent(context, selectedLesson)
          : _markdownBody(selectedLesson.markdownContent),
    );
  }

  Widget _markdownBody(String markdown) {
    final chunks = _splitMarkdownBlocks(_prepareMarkdown(markdown));
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      itemCount: chunks.length,
      itemBuilder: (context, index) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: MarkdownContent(content: chunks[index], selectable: true),
        ),
      ),
    );
  }

  Widget _emptyLessonContent(BuildContext context, Lesson lesson) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.article_outlined, size: 48),
            const SizedBox(height: 12),
            Text(
              'This lesson has no imported Markdown content.',
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              icon: const Icon(Icons.menu_book_outlined),
              label: const Text('View Vocabulary'),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => LessonDetailView(lessonId: lesson.id),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  static String _prepareMarkdown(String markdown) {
    final fencedCodeBlocks = <String>[];
    final codeBlockPattern = RegExp(
      r'(^```[\s\S]*?^```[ \t]*$|^~~~[\s\S]*?^~~~[ \t]*$)',
      multiLine: true,
    );
    var prepared = markdown.replaceAllMapped(codeBlockPattern, (match) {
      final placeholder = 'LINGUA_CODE_BLOCK_${fencedCodeBlocks.length}';
      fencedCodeBlocks.add(match[0]!);
      return placeholder;
    });

    prepared = prepared.replaceAll(
      RegExp(
        r'<VocabQuiz\b[^>]*>([\s\S]*?)</VocabQuiz\s*>|<VocabQuiz\b[^>]*/?>',
        caseSensitive: false,
      ),
      '',
    );
    prepared = MarkdownContent.prepareSpoilerSpans(prepared);
    prepared = prepared.replaceAllMapped(
      RegExp(r'<AudioButton\b([^>]*)/?>', caseSensitive: false),
      (match) {
        final source = RegExp(
          r'''src\s*=\s*["']([^"']+)["']''',
          caseSensitive: false,
        ).firstMatch(match[1] ?? '')?.group(1);
        if (source == null) return '';
        final audioUri = Uri(
          scheme: 'lingua-audio',
          queryParameters: {'src': source},
        );
        return '![Audio](<$audioUri>)';
      },
    );
    prepared = prepared.replaceAllMapped(
      RegExp(r'<TTS\b[^>]*>([\s\S]*?)</TTS\s*>', caseSensitive: false),
      (match) {
        final text = (match[1] ?? '').replaceAll(RegExp(r'<[^>]*>'), '').trim();
        if (text.isEmpty) return '';
        final audioUri = Uri(
          scheme: 'lingua-audio',
          queryParameters: {'text': text},
        );
        return '$text ![Speak](<$audioUri>)';
      },
    );
    prepared = prepared.replaceAllMapped(
      RegExp(r'<Details\b([^>]*)>', caseSensitive: false),
      (match) {
        final summary = RegExp(
          r'''(?:summary|title)\s*=\s*["']([^"']+)["']''',
          caseSensitive: false,
        ).firstMatch(match[1] ?? '')?.group(1);
        return summary == null ? '' : '\n\n**$summary**\n\n';
      },
    );
    prepared = prepared.replaceAllMapped(
      RegExp(
        r'<YouTube\b([^>]*)>([\s\S]*?)</YouTube\s*>|<YouTube\b([^>]*)/?>',
        caseSensitive: false,
      ),
      (match) {
        final attributes = match[1] ?? match[3] ?? '';
        final videoId = RegExp(
          r'''(?:id|video[-_]?id|src)\s*=\s*["']([^"']+)["']''',
          caseSensitive: false,
        ).firstMatch(attributes)?.group(1);
        if (videoId == null) return '';
        final videoUri = videoId.startsWith('http')
            ? videoId
            : 'https://www.youtube.com/watch?v=$videoId';
        return '\n\nYouTube video URL: $videoUri\n\n';
      },
    );
    prepared = prepared.replaceAllMapped(
      RegExp(r'<img\b([^>]*)/?>', caseSensitive: false),
      (match) {
        final attributes = match[1] ?? '';
        final source = RegExp(
          r'''src\s*=\s*["']([^"']+)["']''',
          caseSensitive: false,
        ).firstMatch(attributes)?.group(1);
        if (source == null) return '';
        final alt = RegExp(
          r'''alt\s*=\s*["']([^"']*)["']''',
          caseSensitive: false,
        ).firstMatch(attributes)?.group(1);
        return '\n\n![${alt ?? ''}]($source)\n\n';
      },
    );
    prepared = prepared.replaceAll(
      RegExp(r'</?[A-Za-z][A-Za-z0-9:-]*(?:\s+[^<>]*?)?\s*/?>'),
      '',
    );
    for (var index = 0; index < fencedCodeBlocks.length; index++) {
      prepared = prepared.replaceAll(
        'LINGUA_CODE_BLOCK_$index',
        fencedCodeBlocks[index],
      );
    }
    return prepared;
  }

  static List<String> _splitMarkdownBlocks(String markdown) {
    final blocks = <String>[];
    final current = StringBuffer();
    var inFence = false;
    String? fenceMarker;

    for (final line in markdown.split('\n')) {
      final fenceMatch = RegExp(r'^\s*(`{3,}|~{3,})').firstMatch(line);
      if (fenceMatch != null) {
        final marker = fenceMatch.group(1)!;
        if (!inFence) {
          inFence = true;
          fenceMarker = marker[0];
        } else if (marker.startsWith(fenceMarker!)) {
          inFence = false;
          fenceMarker = null;
        }
      }

      if (line.trim().isEmpty && !inFence && current.isNotEmpty) {
        blocks.add(current.toString().trim());
        current.clear();
      } else {
        if (current.isNotEmpty) current.write('\n');
        current.write(line);
      }
    }
    if (current.isNotEmpty) blocks.add(current.toString().trim());

    final safeBlocks = <String>[];
    final listItem = RegExp(r'^\s*(?:[-*+]|\d+[.)])\s');
    for (final block in blocks) {
      if (safeBlocks.isNotEmpty &&
          listItem.hasMatch(safeBlocks.last) &&
          (listItem.hasMatch(block) || block.startsWith(RegExp(r'\s')))) {
        safeBlocks[safeBlocks.length - 1] = '${safeBlocks.last}\n\n$block';
      } else {
        safeBlocks.add(block);
      }
    }

    final chunks = <String>[];
    final chunk = StringBuffer();
    for (final block in safeBlocks) {
      final nextLength = chunk.length + block.length + (chunk.isEmpty ? 0 : 2);
      if (chunk.isNotEmpty && nextLength > 1800) {
        chunks.add(chunk.toString());
        chunk.clear();
      }
      if (chunk.isNotEmpty) chunk.write('\n\n');
      chunk.write(block);
    }
    if (chunk.isNotEmpty) chunks.add(chunk.toString());
    return chunks;
  }
}

class _LessonMarkdownEditor extends StatefulWidget {
  final Lesson lesson;

  const _LessonMarkdownEditor({required this.lesson});

  @override
  State<_LessonMarkdownEditor> createState() => _LessonMarkdownEditorState();
}

class _LessonMarkdownEditorState extends State<_LessonMarkdownEditor> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.lesson.markdownContent,
  );
  bool _saving = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await context.read<AppProvider>().updateLessonMarkdown(
        widget.lesson.id,
        _controller.text,
      );
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save Markdown: $error')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Edit ${widget.lesson.displayTitle}'),
        actions: [
          TextButton.icon(
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_outlined),
            label: const Text('Save'),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1000),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _controller,
              enabled: !_saving,
              expands: true,
              maxLines: null,
              textAlignVertical: TextAlignVertical.top,
              keyboardType: TextInputType.multiline,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 14,
                height: 1.5,
              ),
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'Enter lesson Markdown',
              ),
            ),
          ),
        ),
      ),
    );
  }
}
