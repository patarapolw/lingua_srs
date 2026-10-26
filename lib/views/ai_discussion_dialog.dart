import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/ai_discussion_message.dart';
import '../models/lesson.dart';
import '../providers/app_provider.dart';
import '../services/ai_discussion_search.dart';
import '../services/deepseek_service.dart';
import '../services/lesson_ai_prompt.dart';
import '../widgets/ai_discussion_suggestion_tile.dart';
import '../widgets/markdown_content.dart';
import 'related_ai_discussions_sheet.dart';
import 'settings_dialog.dart';

class AiDiscussionDialog extends StatefulWidget {
  final String discussionId;
  final String targetWord;
  final String translation;
  final String targetLanguage;
  final String nativeLanguage;
  final String? sentenceTarget;
  final String? sentenceTranslation;
  final Lesson? lesson;

  const AiDiscussionDialog({
    super.key,
    required this.discussionId,
    required this.targetWord,
    required this.translation,
    required this.targetLanguage,
    required this.nativeLanguage,
    this.sentenceTarget,
    this.sentenceTranslation,
    this.lesson,
  });

  @override
  State<AiDiscussionDialog> createState() => _AiDiscussionDialogState();
}

class _AiDiscussionDialogState extends State<AiDiscussionDialog> {
  final TextEditingController _questionController = TextEditingController();
  final ScrollController _messagesController = ScrollController();
  bool _sending = false;
  String? _error;
  String _streamingAnswer = '';
  bool _wasAtBottom = true;

  /// Earlier discussions about this word or related ones. Only looked up for a
  /// discussion that has no messages yet, and once, when it opens.
  List<AiDiscussionSuggestion> _earlier = const [];

  @override
  void initState() {
    super.initState();
    final provider = context.read<AppProvider>();
    if (provider.getAiDiscussion(widget.discussionId).isEmpty) {
      _earlier = provider.relatedAiDiscussions(widget.discussionId);
    }
    _messagesController.addListener(() {
      final position = _messagesController.position;
      _wasAtBottom = position.maxScrollExtent - position.pixels < 80;
    });
  }

  @override
  void dispose() {
    _questionController.dispose();
    _messagesController.dispose();
    super.dispose();
  }

  Future<void> _openSettings() async {
    await showDialog<void>(
      context: context,
      builder: (_) => const SettingsDialog(),
    );
    if (mounted) setState(() {});
  }

  void _openEarlier(AiDiscussionSuggestion suggestion) {
    final dialog = aiDiscussionDialogFor(suggestion.discussion);
    if (dialog == null) return;
    Navigator.of(context).pushReplacement(
      DialogRoute<void>(context: context, builder: (_) => dialog),
    );
  }

  /// Opens a related discussion on top of this one, so closing it comes back
  /// to this chat.
  Future<void> _openRelated() async {
    final chosen = await showRelatedAiDiscussions(
      context,
      discussionId: widget.discussionId,
      suggestedQuery: widget.targetWord,
    );
    if (chosen == null || !mounted) return;
    await showAiDiscussion(context, chosen);
  }

  Future<void> _deleteDiscussion() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete this discussion?'),
        content: const Text(
          'The saved AI conversation for this vocabulary and sentence will be permanently deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await context.read<AppProvider>().deleteAiDiscussion(widget.discussionId);
      if (mounted) {
        setState(() => _error = null);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'Could not delete discussion: $error');
      }
    }
  }

  String _systemPrompt() {
    if (widget.lesson case final lesson?) {
      return LessonAiPrompt.systemPrompt(lesson);
    }
    final sentence = widget.sentenceTarget?.trim();
    final sentenceTranslation = widget.sentenceTranslation?.trim();
    return [
      'You are a helpful language-learning tutor.',
      'The learner is studying ${widget.targetLanguage} with ${widget.nativeLanguage} support.',
      'Vocabulary: "${widget.targetWord}" means "${widget.translation}".',
      if (sentence?.isNotEmpty == true)
        'Example sentence: "$sentence"${sentenceTranslation?.isNotEmpty == true ? ' (translation: "$sentenceTranslation")' : ''}.',
      'Answer questions about this vocabulary and example sentence clearly. Explain nuances and usage when useful.',
      'Format your answer using Markdown.',
    ].join('\n');
  }

  List<String> _suggestedQuestions(bool hasMessages) {
    if (widget.lesson != null) {
      return LessonAiPrompt.suggestedQuestions(hasMessages);
    }
    final questions = !hasMessages
        ? [
            'Explain the etymology and Hanja of "${widget.targetWord}".',
            if (widget.sentenceTarget?.isNotEmpty == true)
              'How does this sentence work?',
            'How is "${widget.targetWord}" used in everyday speech?',
            'Give me another example sentence with "${widget.targetWord}".',
          ]
        : [
            'Explain the etymology and Hanja of "${widget.targetWord}".',
            'Can you give another example with "${widget.targetWord}"?',
            'How would a native speaker say this more naturally?',
            if (widget.sentenceTarget?.isNotEmpty == true)
              'What other useful expressions are in this sentence?',
          ];

    return questions;
  }

  void _insertNewline() {
    final value = _questionController.value;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : value.text.length;
    final end = selection.isValid ? selection.end : value.text.length;
    final text = value.text.replaceRange(start, end, '\n');
    _questionController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: start + 1),
    );
  }

  KeyEventResult _handleComposerKeyEvent(FocusNode node, KeyEvent event) {
    final isEnter =
        event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter;
    if (event is KeyDownEvent &&
        isEnter &&
        (HardwareKeyboard.instance.isShiftPressed ||
            HardwareKeyboard.instance.isControlPressed)) {
      _insertNewline();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _sendQuestion([String? suggestedQuestion]) async {
    final question = (suggestedQuestion ?? _questionController.text).trim();
    if (_sending || question.isEmpty) return;

    final provider = context.read<AppProvider>();
    if (provider.deepSeekApiKey.isEmpty) {
      setState(() => _error = 'Add your DeepSeek API key in settings first.');
      return;
    }

    if (suggestedQuestion == null) _questionController.clear();
    setState(() {
      _sending = true;
      _error = null;
      _streamingAnswer = '';
    });

    try {
      await provider.addAiDiscussionMessage(
        widget.discussionId,
        AiDiscussionMessage(role: 'user', content: question),
      );
      final messages = [
        AiDiscussionMessage(role: 'system', content: _systemPrompt()),
        ...provider.getAiDiscussion(widget.discussionId),
      ];
      final answer = StringBuffer();
      await for (final chunk in DeepSeekService.replyStream(
        apiKey: provider.deepSeekApiKey,
        messages: messages,
      )) {
        answer.write(chunk);
        if (mounted) {
          setState(() => _streamingAnswer = answer.toString());
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_messagesController.hasClients && _wasAtBottom) {
              _messagesController.jumpTo(
                _messagesController.position.maxScrollExtent,
              );
            }
          });
        }
      }
      await provider.addAiDiscussionMessage(
        widget.discussionId,
        AiDiscussionMessage(role: 'assistant', content: answer.toString()),
      );
    } catch (error) {
      if (mounted) setState(() => _error = 'Could not get an answer: $error');
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
          _streamingAnswer = '';
        });

        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_messagesController.hasClients && _wasAtBottom) {
            _messagesController.jumpTo(
              _messagesController.position.maxScrollExtent,
            );
          }
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppProvider>();
    final messages = provider.getAiDiscussion(widget.discussionId);
    final theme = Theme.of(context);
    final width = MediaQuery.sizeOf(context).width;
    final height = MediaQuery.sizeOf(context).height;
    final double maxWidth = 640;

    final lastSaved = messages.isNotEmpty ? messages.last : null;
    final showStreaming =
        _sending &&
        _streamingAnswer.isNotEmpty &&
        !(lastSaved?.role == 'assistant' &&
            lastSaved?.content == _streamingAnswer);

    return Dialog(
      insetPadding: EdgeInsets.zero,
      alignment: Alignment.bottomCenter,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: maxWidth,
          maxHeight: height * 0.9,
        ),
        child: SizedBox(
          width: width < maxWidth ? width : maxWidth,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Ask AI', style: theme.textTheme.titleLarge),
                          Text(
                            widget.translation.trim().isEmpty
                                ? widget.targetWord
                                : '${widget.targetWord} — ${widget.translation}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    // A lesson chat is about no single word to relate.
                    if (widget.lesson == null)
                      IconButton(
                        tooltip: 'Related discussions',
                        onPressed: _sending ? null : _openRelated,
                        icon: const Icon(Icons.manage_search),
                      ),
                    IconButton(
                      tooltip: 'DeepSeek settings',
                      onPressed: _openSettings,
                      icon: const Icon(Icons.key_outlined),
                    ),
                    if (messages.isNotEmpty)
                      IconButton(
                        tooltip: 'Delete saved discussion',
                        onPressed: _sending ? null : _deleteDiscussion,
                        icon: const Icon(Icons.delete_outline),
                      ),
                    IconButton(
                      tooltip: 'Close',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                if (widget.sentenceTarget?.isNotEmpty == true)
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(top: 8, bottom: 12),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest
                          .withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: MarkdownContent(
                      content: widget.sentenceTarget!,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                Expanded(
                  child: messages.isEmpty
                      ? Center(
                          child: SingleChildScrollView(
                            child: Column(
                              children: [
                                Text(
                                  widget.lesson != null
                                      ? 'Ask a question about this lesson.'
                                      : 'Ask a question about this word or sentence.',
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: 12),
                                if (_earlier.isNotEmpty) ...[
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: Text(
                                      'Earlier discussions',
                                      style: theme.textTheme.labelMedium,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  for (final suggestion in _earlier)
                                    AiDiscussionSuggestionTile(
                                      suggestion: suggestion,
                                      onTap: _sending
                                          ? null
                                          : () => _openEarlier(suggestion),
                                    ),
                                  const SizedBox(height: 12),
                                ],
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    'Try asking',
                                    style: theme.textTheme.labelMedium,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Wrap(
                                  spacing: 6,
                                  runSpacing: 4,
                                  children: _suggestedQuestions(false)
                                      .map(
                                        (question) => ActionChip(
                                          label: Text(question),
                                          onPressed: _sending
                                              ? null
                                              : () => _sendQuestion(question),
                                        ),
                                      )
                                      .toList(),
                                ),
                              ],
                            ),
                          ),
                        )
                      : ListView.builder(
                          controller: _messagesController,
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          itemCount: messages.length + (showStreaming ? 1 : 0),
                          itemBuilder: (context, index) {
                            if (showStreaming && index == messages.length) {
                              return Align(
                                alignment: Alignment.centerLeft,
                                child: Container(
                                  constraints: const BoxConstraints(
                                    maxWidth: 500,
                                  ),
                                  margin: const EdgeInsets.only(bottom: 10),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 10,
                                  ),
                                  decoration: BoxDecoration(
                                    color: theme
                                        .colorScheme
                                        .surfaceContainerHighest,
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  child: MarkdownContent(
                                    content: _streamingAnswer,
                                    selectable: true,
                                  ),
                                ),
                              );
                            }
                            final message = messages[index];
                            final isUser = message.role == 'user';
                            return Align(
                              alignment: isUser
                                  ? Alignment.centerRight
                                  : Alignment.centerLeft,
                              child: Container(
                                constraints: const BoxConstraints(
                                  maxWidth: 500,
                                ),
                                margin: const EdgeInsets.only(bottom: 10),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 10,
                                ),
                                decoration: BoxDecoration(
                                  color: isUser
                                      ? theme.colorScheme.primaryContainer
                                      : theme
                                            .colorScheme
                                            .surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: isUser
                                    ? SelectableText(message.content)
                                    : MarkdownContent(
                                        content: message.content,
                                        selectable: true,
                                      ),
                              ),
                            );
                          },
                        ),
                ),
                if (messages.isNotEmpty)
                  ExpansionTile(
                    title: Text(
                      'Suggested next questions',
                      style: theme.textTheme.labelMedium,
                    ),
                    tilePadding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                    initiallyExpanded: height > 1000,
                    children: _suggestedQuestions(true)
                        .map(
                          (question) => ActionChip(
                            label: Text(question),
                            onPressed: _sending
                                ? null
                                : () => _sendQuestion(question),
                          ),
                        )
                        .toList(),
                  ),
                SizedBox(
                  height: 2,
                  child: _sending
                      ? const LinearProgressIndicator(minHeight: 2)
                      : null,
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      _error!,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ),
                const SizedBox(height: 10),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: Focus(
                        onKeyEvent: _handleComposerKeyEvent,
                        child: TextField(
                          controller: _questionController,
                          minLines: 1,
                          maxLines: 4,
                          textCapitalization: TextCapitalization.sentences,
                          textInputAction: TextInputAction.send,
                          decoration: InputDecoration(
                            hintText: widget.lesson != null
                                ? 'Ask about this lesson…'
                                : 'Ask about the vocabulary or sentence…',
                          ),
                          onSubmitted: (_) => _sendQuestion(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      tooltip: 'Send question',
                      onPressed: _sending ? null : _sendQuestion,
                      icon: const Icon(Icons.send),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Enter to send · Shift/Ctrl+Enter for a new line',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
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

/// The Ask AI dialog for a saved discussion, or null when the lesson it was
/// about has been deleted.
AiDiscussionDialog? aiDiscussionDialogFor(AiDiscussionSummary discussion) {
  if (discussion.isLesson && discussion.lesson == null) return null;
  return AiDiscussionDialog(
    discussionId: discussion.id,
    targetWord:
        discussion.vocab?.targetWord ??
        (discussion.isLesson ? discussion.lesson!.displayTitle : discussion.id),
    translation: discussion.vocab?.translation ?? '',
    targetLanguage: discussion.lesson?.targetLanguage ?? 'ko',
    nativeLanguage: discussion.lesson?.nativeLanguage ?? 'en',
    sentenceTarget: discussion.sentence?.targetText,
    sentenceTranslation: discussion.sentence?.translationText,
    lesson: discussion.isLesson ? discussion.lesson : null,
  );
}

/// Opens a saved discussion; does nothing when its lesson is gone.
Future<void> showAiDiscussion(
  BuildContext context,
  AiDiscussionSummary discussion,
) async {
  final dialog = aiDiscussionDialogFor(discussion);
  if (dialog == null) return;
  await showDialog<void>(context: context, builder: (_) => dialog);
}
