import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/ai_discussion_message.dart';
import '../models/lesson.dart';
import '../providers/app_provider.dart';
import '../services/ai_discussion_search.dart';
import '../services/deepseek_service.dart';
import '../services/lesson_ai_prompt.dart';
import '../services/word_ai_prompt.dart';
import '../widgets/ai_discussion_suggestion_tile.dart';
import '../widgets/emphasis_text.dart';
import '../widgets/markdown_content.dart';
import 'related_ai_discussions_sheet.dart';

/// What the dialog header's More menu offers.
enum _DialogMenuAction { delete }

class AiDiscussionDialog extends StatefulWidget {
  final String discussionId;
  final String targetWord;
  final String translation;
  final String targetLanguage;
  final String nativeLanguage;
  final String? sentenceTarget;
  final String? sentenceTranslation;
  final Lesson? lesson;

  /// The word or lesson this chat was about no longer exists. The chat opens
  /// read-only, and can be continued without it.
  final bool orphaned;

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
    this.orphaned = false,
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

  /// An orphaned chat is only read until the learner chooses to continue.
  late bool _readOnly = widget.orphaned;

  bool get _isLessonChat =>
      LessonAiPrompt.isLessonDiscussion(widget.discussionId);

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

  void _openEarlier(AiDiscussionSuggestion suggestion) {
    final dialog = aiDiscussionDialogFor(suggestion.discussion);
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

  /// What the confirmation says is about to be deleted.
  String get _deleteMessage {
    final what = _isLessonChat
        ? (widget.orphaned
              ? 'a lesson that no longer exists'
              : 'the lesson "${widget.targetWord}"')
        : (widget.orphaned
              ? 'a word that no longer exists'
              : '"${widget.targetWord}"');
    return 'The saved AI conversation about $what will be permanently deleted.';
  }

  Future<void> _deleteDiscussion() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete this discussion?'),
        content: Text(_deleteMessage),
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
      if (!mounted) return;
      // Nothing is left to read or continue about a word or lesson that is gone.
      if (widget.orphaned) {
        Navigator.of(context).pop();
      } else {
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
    if (widget.orphaned) {
      return _isLessonChat
          ? OrphanedAiPrompt.forLesson(
              targetLanguage: widget.targetLanguage,
              nativeLanguage: widget.nativeLanguage,
            )
          : OrphanedAiPrompt.forWord(
              targetLanguage: widget.targetLanguage,
              nativeLanguage: widget.nativeLanguage,
            );
    }
    return WordAiPrompt.systemPrompt(
      targetLanguage: widget.targetLanguage,
      nativeLanguage: widget.nativeLanguage,
      targetWord: widget.targetWord,
      translation: widget.translation,
      sentenceTarget: widget.sentenceTarget,
      sentenceTranslation: widget.sentenceTranslation,
    );
  }

  /// The saved conversation as the AI should read it. In a word chat the
  /// newest question carries the example sentence on the card.
  List<AiDiscussionMessage> _history(List<AiDiscussionMessage> saved) {
    if (widget.lesson != null || widget.orphaned) return saved;
    return WordAiPrompt.withCurrentSentence(
      saved,
      sentenceTarget: widget.sentenceTarget,
      sentenceTranslation: widget.sentenceTranslation,
    );
  }

  List<String> _suggestedQuestions(bool hasMessages) {
    // The questions are about a word or lesson that is not there to ask about.
    if (widget.orphaned) return const [];
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
        ..._history(provider.getAiDiscussion(widget.discussionId)),
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
                    // A lesson chat is about no single word to relate, and a word
                    // that is gone has nothing to relate by.
                    if (!_isLessonChat && !widget.orphaned)
                      IconButton(
                        tooltip: 'Related discussions',
                        onPressed: _sending ? null : _openRelated,
                        icon: const Icon(Icons.manage_search),
                      ),
                    // Deleting is rare and permanent, so it lives in a menu. An
                    // empty chat has nothing to delete, hence nothing to show.
                    if (messages.isNotEmpty)
                      PopupMenuButton<_DialogMenuAction>(
                        tooltip: 'More',
                        enabled: !_sending,
                        onSelected: (action) {
                          switch (action) {
                            case _DialogMenuAction.delete:
                              _deleteDiscussion();
                          }
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(
                            value: _DialogMenuAction.delete,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.delete_outline),
                                SizedBox(width: 12),
                                Flexible(
                                  child: Text(
                                    'Delete discussion',
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
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
                    child: EmphasisText(
                      widget.sentenceTarget!,
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
                if (messages.isNotEmpty && _suggestedQuestions(true).isNotEmpty)
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
                if (_readOnly)
                  _OrphanedNotice(
                    isLesson: _isLessonChat,
                    onContinue: () => setState(() => _readOnly = false),
                  )
                else ...[
                  if (widget.orphaned)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        _isLessonChat
                            ? 'The AI cannot see the deleted lesson, so it only has this conversation to go on.'
                            : 'The AI cannot see the deleted word, so it only has this conversation to go on.',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
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
                              hintText: widget.orphaned
                                  ? 'Ask a follow-up…'
                                  : widget.lesson != null
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
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The Ask AI dialog for a saved discussion. When its word or lesson is gone
/// it opens read-only.
AiDiscussionDialog aiDiscussionDialogFor(AiDiscussionSummary discussion) {
  return AiDiscussionDialog(
    discussionId: discussion.id,
    targetWord: discussion.title,
    translation: discussion.vocab?.translation ?? '',
    targetLanguage: discussion.lesson?.targetLanguage ?? 'ko',
    nativeLanguage: discussion.lesson?.nativeLanguage ?? 'en',
    sentenceTarget: discussion.sentence?.targetText,
    sentenceTranslation: discussion.sentence?.translationText,
    lesson: discussion.isLesson ? discussion.lesson : null,
    orphaned: discussion.isOrphaned,
  );
}

/// Opens a saved discussion.
Future<void> showAiDiscussion(
  BuildContext context,
  AiDiscussionSummary discussion,
) async {
  final dialog = aiDiscussionDialogFor(discussion);
  await showDialog<void>(context: context, builder: (_) => dialog);
}

/// Shown instead of the message box while a chat about a word or lesson that is
/// gone is only being read.
class _OrphanedNotice extends StatelessWidget {
  const _OrphanedNotice({required this.isLesson, required this.onContinue});

  final bool isLesson;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final what = isLesson ? 'lesson' : 'word';
    return Card(
      margin: EdgeInsets.zero,
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'This $what no longer exists, so this chat is read-only. You can still search for it or delete it.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonal(
                onPressed: onContinue,
                child: Text('Continue without the $what'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
