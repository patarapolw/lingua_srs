import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/lesson.dart';
import '../providers/app_provider.dart';
import '../services/lesson_ai_prompt.dart';
import '../services/lesson_links.dart';
import '../widgets/lesson_content_view.dart';
import '../widgets/markdown_text_field.dart';
import 'ai_discussion_dialog.dart';
import 'lesson_detail_view.dart';

class LessonReaderView extends StatefulWidget {
  final String lessonId;

  /// Text or anchor of a heading to scroll to on opening, for a link such as
  /// `[[Lesson 26#Past tense]]`.
  final String? initialHeading;

  const LessonReaderView({
    super.key,
    required this.lessonId,
    this.initialHeading,
  });

  @override
  State<LessonReaderView> createState() => _LessonReaderViewState();
}

class _LessonReaderViewState extends State<LessonReaderView> {
  final LessonContentController _contentController = LessonContentController();
  String? _parsedMarkdown;
  LessonContent? _parsed;

  String get lessonId => widget.lessonId;

  LessonContent _contentFor(String markdown) {
    if (_parsed == null || _parsedMarkdown != markdown) {
      _parsedMarkdown = markdown;
      _parsed = LessonContent.parse(markdown);
    }
    return _parsed!;
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppProvider>();
    Lesson? lesson;
    for (final candidate in provider.lessons) {
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
    final content = _contentFor(selectedLesson.markdownContent);
    final headings = content.headings;
    // On a phone, a labelled button leaves no room for the title.
    final compact = MediaQuery.sizeOf(context).width < 700;
    void openVocabulary() => Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => LessonDetailView(lessonId: selectedLesson.id),
      ),
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(selectedLesson.displayTitle),
        actions: [
          if (headings.isNotEmpty)
            IconButton(
              tooltip: 'Table of contents',
              icon: const Icon(Icons.toc),
              onPressed: () => _showToc(context, headings),
            ),
          if (provider.showAi)
            IconButton(
              tooltip: 'Ask AI about lesson',
              icon: const Icon(Icons.forum_outlined),
              onPressed: () => _openAiDiscussion(context, selectedLesson),
            ),
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
          if (compact)
            IconButton(
              tooltip: 'View Vocabulary',
              icon: const Icon(Icons.translate_outlined),
              onPressed: openVocabulary,
            )
          else
            TextButton.icon(
              icon: const Icon(Icons.translate_outlined),
              label: const Text('View Vocabulary'),
              onPressed: openVocabulary,
            ),
          SizedBox(width: compact ? 4 : 12),
        ],
      ),
      body: selectedLesson.markdownContent.trim().isEmpty
          ? _emptyLessonContent(context, selectedLesson)
          : LessonContentView(
              markdown: selectedLesson.markdownContent,
              content: content,
              controller: _contentController,
              initialHeading: widget.initialHeading,
              scrollKey: selectedLesson.id,
              onLessonLink: (link) =>
                  _openLessonLink(context, provider, selectedLesson, link),
            ),
    );
  }

  /// Opens the lesson a `[[Lesson#Heading]]` or `lesson.md#heading` link
  /// names, at its heading, or scrolls to the heading if the link names this
  /// lesson.
  void _openLessonLink(
    BuildContext context,
    AppProvider provider,
    Lesson current,
    LessonLink link,
  ) {
    final messenger = ScaffoldMessenger.of(context);
    final file = link.file;
    final target = file != null
        ? LessonLink.resolveFile(provider.lessons, file, from: current)
        : LessonLink.resolveLesson(
            provider.lessons,
            link.lesson!,
            from: current,
          );
    if (target == null) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            file != null
                ? 'No lesson at “$file”.'
                : 'No lesson named “${link.lesson}”.',
          ),
        ),
      );
      return;
    }
    final heading = link.heading;
    if (target.id == current.id) {
      if (heading != null &&
          !_contentController.scrollToHeadingNamed(heading)) {
        messenger.showSnackBar(
          SnackBar(content: Text('No heading “$heading” in this lesson.')),
        );
      }
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            LessonReaderView(lessonId: target.id, initialHeading: heading),
      ),
    );
  }

  void _showToc(BuildContext context, List<LessonHeading> headings) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.7,
          ),
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: headings.length,
            itemBuilder: (_, index) {
              final heading = headings[index];
              return ListTile(
                dense: true,
                contentPadding: EdgeInsets.only(
                  left: 16.0 + (heading.level - 1) * 16,
                  right: 16,
                ),
                title: Text(heading.text),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _contentController.scrollToHeading(heading);
                },
              );
            },
          ),
        ),
      ),
    );
  }

  void _openAiDiscussion(BuildContext context, Lesson lesson) {
    showDialog<void>(
      context: context,
      builder: (_) => AiDiscussionDialog(
        discussionId: LessonAiPrompt.discussionId(lesson.id),
        targetWord: lesson.displayTitle,
        translation: '',
        targetLanguage: lesson.targetLanguage,
        nativeLanguage: lesson.nativeLanguage,
        lesson: lesson,
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
              icon: const Icon(Icons.translate_outlined),
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                VirtualPathBar(lesson: widget.lesson),
                const SizedBox(height: 12),
                Expanded(
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
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Shows where `.md` links find a lesson ([Lesson.virtualPath]), with a
/// button that copies a Markdown link to it.
class VirtualPathBar extends StatelessWidget {
  final Lesson lesson;

  const VirtualPathBar({super.key, required this.lesson});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final path = LessonLink.virtualPathText(lesson);
    return Row(
      children: [
        Tooltip(
          message: lesson.fileName == null
              ? 'Virtual path, named after the lesson title. '
                    '.md links in other lessons find this lesson here.'
              : 'Virtual path, with the name of the file it was imported '
                    'from. .md links in other lessons find this lesson here.',
          child: Icon(
            Icons.description_outlined,
            size: 18,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: SelectableText(
            path,
            key: const ValueKey('virtual-path'),
            maxLines: 1,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontFamily: 'monospace',
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        IconButton(
          tooltip: 'Copy link to this lesson',
          icon: const Icon(Icons.link),
          onPressed: () async {
            final messenger = ScaffoldMessenger.of(context);
            await Clipboard.setData(
              ClipboardData(text: LessonLink.markdownLinkTo(lesson)),
            );
            messenger.showSnackBar(
              const SnackBar(content: Text('Copied a link to this lesson.')),
            );
          },
        ),
      ],
    );
  }
}
