import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/lesson.dart';
import '../providers/app_provider.dart';
import '../widgets/lesson_html_view.dart';
import '../widgets/markdown_text_field.dart';
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
          : LessonHtmlView(markdown: selectedLesson.markdownContent),
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
            child: MarkdownTextField(
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
