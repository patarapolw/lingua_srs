import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/ai_discussion_message.dart';
import '../models/lesson.dart';
import '../models/typed_question.dart';
import '../providers/app_provider.dart';
import '../services/ai_discussion_search.dart';
import '../services/ai_question_suggestions.dart';
import '../services/deepseek_service.dart';
import '../services/lesson_ai_prompt.dart';
import '../services/suggested_vocabulary_hints.dart';
import '../services/typed_questions.dart';
import '../services/word_ai_prompt.dart';
import '../services/yaml_parser_service.dart';
import '../widgets/ai_discussion_suggestion_tile.dart';
import '../widgets/ai_question_chip.dart';
import '../widgets/emphasis_text.dart';
import '../widgets/markdown_content.dart';
import 'related_ai_discussions_sheet.dart';
import 'yaml_import_view.dart';

/// Vocabulary an AI answer offers to add: its YAML without the known words,
/// and hints for the words left in it.
typedef _VocabularyOffer = ({
  VocabularyYamlFilter filter,
  List<SuggestedVocabularyHint> hints,
});

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

  /// What the data says about the word's kind (its part of speech and its
  /// sections), which with the word decides whether to ask about its forms.
  final List<String> categories;
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
    this.categories = const [],
    this.lesson,
    this.orphaned = false,
  });

  @override
  State<AiDiscussionDialog> createState() => _AiDiscussionDialogState();
}

class _AiDiscussionDialogState extends State<AiDiscussionDialog> {
  final TextEditingController _questionController = TextEditingController();
  final FocusNode _questionFocusNode = FocusNode();
  final ScrollController _messagesController = ScrollController();
  final ExpansibleController _followUpsController = ExpansibleController();
  bool _sending = false;
  String? _error;
  String _streamingAnswer = '';
  bool _wasAtBottom = true;

  /// Questions the AI suggested after the last answer. They are not saved: a
  /// reopened chat shows only the fixed ones until the next answer.
  List<String> _aiQuestions = const [];

  /// Counts the questions sent, so that suggestions for an old answer that
  /// arrive late are dropped.
  int _suggestionRound = 0;

  /// The offered question last tapped, which fills the question field, and
  /// whether it was one the learner typed before. A question sent as it was
  /// tapped is not a typed one, unless it was offered as one.
  String? _pickedQuestion;
  bool _pickedTyped = false;

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
    _questionFocusNode.dispose();
    _messagesController.dispose();
    _followUpsController.dispose();
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

  /// The vocabulary each answer offers to add to the lesson, by the answer's
  /// text: its YAML without the words already in a lesson, and the hints for
  /// the words left in it, or null for an answer without vocabulary YAML.
  /// Worked out again when the number of words in the lessons changes, as it
  /// does once some are added.
  final Map<String, _VocabularyOffer?> _vocabularyOffers = {};
  int _knownWordCount = -1;

  _VocabularyOffer? _vocabularyOffer(Lesson lesson, String content) {
    final lessons = context.read<AppProvider>().lessons;
    final count = lessons.fold(0, (sum, l) => sum + l.vocabularies.length);
    if (count != _knownWordCount) {
      _vocabularyOffers.clear();
      _knownWordCount = count;
    }
    return _vocabularyOffers.putIfAbsent(content, () {
      final yaml = LessonAiPrompt.vocabularyYaml(content);
      if (yaml == null) return null;
      // Only words of the lesson's language: the same characters can be
      // another word in another language.
      final language = AiQuestionSuggestions.languageCode(
        lesson.targetLanguage,
      );
      final vocabularies = [
        for (final other in lessons)
          if (AiQuestionSuggestions.languageCode(other.targetLanguage) ==
              language)
            ...other.vocabularies,
      ];
      final filter = YamlParserService.withoutKnownVocabulary(yaml, [
        for (final vocab in vocabularies)
          // Words have no Hanja or reading to tell them apart yet.
          (
            word: vocab.targetWord,
            meaning: vocab.translation,
            hanja: '',
            reading: '',
          ),
      ]);
      return (
        filter: filter,
        hints: SuggestedVocabularyHints.forEntries(
          language: lesson.targetLanguage,
          entries: filter.keptEntries,
          known: [for (final vocab in vocabularies) vocab.targetWord],
        ),
      );
    });
  }

  /// An AI answer. In a lesson chat, an answer with vocabulary YAML in it
  /// gets a button that opens the YAML in the import screen, under the
  /// lesson's name, to edit and add to the lesson. Under the button are named
  /// the words left out because they are in a lesson or listed twice; the
  /// words kept though written like another with another meaning, which may
  /// be other words or the same one ([YamlParserService.withoutKnownVocabulary]);
  /// and the words that are another form of one the learner has or that is
  /// listed earlier ([SuggestedVocabularyHints]).
  Widget _answer(String content) {
    final markdown = MarkdownContent(content: content, selectable: true);
    final lesson = widget.lesson;
    if (lesson == null || widget.orphaned) return markdown;
    final found = _vocabularyOffer(lesson, content);
    if (found == null) return markdown;
    final (filter: offer, :hints) = found;
    final nothingNew = offer.kept.isEmpty && offer.removed.isNotEmpty;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        markdown,
        const SizedBox(height: 6),
        OutlinedButton.icon(
          icon: const Icon(Icons.playlist_add),
          label: Text(
            nothingNew
                ? 'Already in your lessons'
                : offer.removed.isEmpty
                ? 'Edit and add to lesson'
                : 'Edit and add ${offer.kept.length} new '
                      '${offer.kept.length == 1 ? 'word' : 'words'}',
          ),
          onPressed: nothingNew
              ? null
              : () => _addVocabulary(lesson, offer.yaml),
        ),
        if (offer.removed.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Left out (already in your lessons or listed twice): '
              '${offer.removed.toSet().join(', ')}',
              style: theme.textTheme.bodySmall,
            ),
          ),
        if (offer.possibleDuplicates.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Possible duplicates (same word, another meaning): '
              '${offer.possibleDuplicates.map(_describeDuplicate).join(', ')}',
              style: theme.textTheme.bodySmall,
            ),
          ),
        if (hints.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Consider editing out: '
              '${SuggestedVocabularyHints.summary(hints)}',
              style: theme.textTheme.bodySmall,
            ),
          ),
      ],
    );
  }

  /// 배 "ship" (you have "pear"), or (also listed as "pear").
  static String _describeDuplicate(PossibleDuplicate duplicate) =>
      '${duplicate.word} "${duplicate.meaning}" '
      '(${duplicate.inList ? 'also listed as' : 'you have'} '
      '"${duplicate.otherMeaning}")';

  /// Opens [yaml] in the import screen under [lesson]'s name. Nothing is added
  /// until the learner imports it there, so the words can be edited first.
  void _addVocabulary(Lesson lesson, String yaml) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => YamlImportView(
          initialLessonName: joinHierarchyPath([
            ...lesson.folderPath,
            lesson.displayTitle,
          ]),
          initialYaml: yaml,
          previewInitialYaml: true,
        ),
      ),
    );
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

  bool get _hasSentence => widget.sentenceTarget?.trim().isNotEmpty == true;

  bool get _isVerbOrAdjective => AiQuestionSuggestions.isVerbOrAdjective(
    language: widget.targetLanguage,
    word: widget.targetWord,
    categories: widget.categories,
  );

  TypedQuestionScope get _scope => widget.lesson != null
      ? TypedQuestionScope.lesson
      : TypedQuestionScope.word;

  /// Questions the learner typed before in chats like this one and has not
  /// asked in this one, with their ids.
  Map<String, String> _typedQuestions(
    AppProvider provider,
    List<AiDiscussionMessage> messages,
  ) {
    if (widget.orphaned) return const {};
    return {
      for (final offer in TypedQuestions.offer(
        provider.typedQuestions,
        language: widget.targetLanguage,
        scope: _scope,
        subject: widget.targetWord,
        leaveOut: [
          for (final message in messages)
            if (message.role == 'user') message.content,
        ],
      ))
        offer.question: offer.id,
    };
  }

  /// Questions for a chat that has no messages yet: ones typed before, then
  /// fixed ones.
  List<String> _firstQuestions(Iterable<String> typed) {
    // The questions are about a word or lesson that is not there to ask about.
    if (widget.orphaned) return const [];
    return AiQuestionSuggestions.firstQuestions(
      typed: typed,
      fixed: widget.lesson != null
          ? LessonAiPrompt.suggestedQuestions(false)
          : AiQuestionSuggestions.wordFirstQuestions(
              language: widget.targetLanguage,
              word: widget.targetWord,
              hasSentence: _hasSentence,
              verbOrAdjective: _isVerbOrAdjective,
            ),
    );
  }

  /// Questions to offer after an answer: ones typed before and fixed ones,
  /// not asked yet, and the AI's suggestions once they have arrived.
  List<String> _followUpQuestions(
    List<AiDiscussionMessage> messages, {
    Iterable<String> typed = const [],
  }) {
    if (widget.orphaned) return const [];
    return AiQuestionSuggestions.followUps(
      typed: typed,
      hardcoded: widget.lesson != null
          ? LessonAiPrompt.suggestedQuestions(true)
          : AiQuestionSuggestions.wordFollowUps(
              language: widget.targetLanguage,
              word: widget.targetWord,
              hasSentence: _hasSentence,
              verbOrAdjective: _isVerbOrAdjective,
            ),
      asked: [
        for (final message in messages)
          if (message.role == 'user') message.content,
      ],
      ai: _aiQuestions,
    );
  }

  /// Asks the AI what the learner may want to ask next. The questions are a
  /// bonus, so a failure is not shown.
  Future<void> _loadAiQuestions({
    required int round,
    required AppProvider provider,
    required String question,
    required String answer,
  }) async {
    final language = widget.targetLanguage;
    if (!AiQuestionSuggestions.supports(language)) return;
    final isLesson = widget.lesson != null;
    try {
      final reply = await DeepSeekService.completeJson(
        apiKey: provider.deepSeekApiKey,
        maxTokens: 400,
        messages: AiQuestionSuggestions.aiRequest(
          language: language,
          subject: isLesson
              ? AiQuestionSuggestions.lessonSubject(
                  language: language,
                  title: widget.targetWord,
                )
              : AiQuestionSuggestions.wordSubject(
                  language: language,
                  word: widget.targetWord,
                  translation: widget.translation,
                  verbOrAdjective: _isVerbOrAdjective,
                ),
          nativeLanguage: widget.nativeLanguage,
          question: question,
          answer: answer,
          asked: [
            for (final message in provider.getAiDiscussion(widget.discussionId))
              if (message.role == 'user') message.content,
          ],
          // The other questions on screen, which the AI should not repeat.
          // Its own are not on screen yet.
          shown: _followUpQuestions(
            provider.getAiDiscussion(widget.discussionId),
            typed: _typedQuestions(
              provider,
              provider.getAiDiscussion(widget.discussionId),
            ).keys,
          ),
          sentenceTarget: isLesson ? null : widget.sentenceTarget,
          sentenceTranslation: isLesson ? null : widget.sentenceTranslation,
        ),
      );
      if (!mounted || round != _suggestionRound) return;
      setState(
        () => _aiQuestions = AiQuestionSuggestions.parseAiQuestions(reply),
      );
    } catch (_) {
      // The fixed questions are shown without them.
    }
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

  void _selectSuggestedQuestion(String question, {bool typed = false}) {
    _pickedQuestion = question;
    _pickedTyped = typed;
    _questionController.value = TextEditingValue(
      text: question,
      selection: TextSelection.collapsed(offset: question.length),
    );
    _questionFocusNode.requestFocus();
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

  Future<void> _sendQuestion() async {
    final question = _questionController.text.trim();
    if (_sending || question.isEmpty) return;

    if (_followUpsController.isExpanded) {
      _followUpsController.collapse();
    }
    FocusScope.of(context).unfocus();
    final provider = context.read<AppProvider>();
    if (provider.deepSeekApiKey.isEmpty) {
      setState(() => _error = 'Add your DeepSeek API key in settings first.');
      return;
    }

    // A question tapped and sent as it was is the app's or the AI's, not
    // the learner's, unless it was offered as one they typed before.
    final picked = _pickedQuestion;
    final typed =
        picked == null ||
        _pickedTyped ||
        AiQuestionSuggestions.questionKey(picked) !=
            AiQuestionSuggestions.questionKey(question);
    _pickedQuestion = null;
    _pickedTyped = false;

    _questionController.clear();
    setState(() {
      _sending = true;
      _error = null;
      _streamingAnswer = '';
      _aiQuestions = const [];
      _suggestionRound++;
    });

    try {
      await provider.addAiDiscussionMessage(
        widget.discussionId,
        AiDiscussionMessage(role: 'user', content: question),
      );
      if (typed && !widget.orphaned) {
        try {
          await provider.recordTypedQuestion(
            question: question,
            subject: widget.targetWord,
            language: widget.targetLanguage,
            scope: _scope,
          );
        } catch (_) {
          // Offering it again later is a bonus; the answer still comes.
        }
      }
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
      if (!widget.orphaned) {
        unawaited(
          _loadAiQuestions(
            round: _suggestionRound,
            provider: provider,
            question: question,
            answer: answer.toString(),
          ),
        );
      }
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

  /// A chip for an offered [question]. One the learner typed before has the
  /// [typedId] it is kept under, and can be removed.
  Widget _questionChip(String question, String? typedId) => AiQuestionChip(
    label: question,
    onPressed: _sending
        ? null
        : () => _selectSuggestedQuestion(question, typed: typedId != null),
    onRemove: typedId == null || _sending
        ? null
        : () => context.read<AppProvider>().removeTypedQuestion(typedId),
  );

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppProvider>();
    final messages = provider.getAiDiscussion(widget.discussionId);
    final typedQuestions = _typedQuestions(provider, messages);
    final firstQuestions = _firstQuestions(typedQuestions.keys);
    final followUps = _followUpQuestions(messages, typed: typedQuestions.keys);
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
                                if (firstQuestions.isNotEmpty) ...[
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: Text(
                                      'Try asking',
                                      style: theme.textTheme.labelMedium,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  SizedBox(
                                    width: double.infinity,
                                    child: Wrap(
                                      alignment: WrapAlignment.center,
                                      spacing: 6,
                                      runSpacing: 6,
                                      children: firstQuestions
                                          .map(
                                            (question) => _questionChip(
                                              question,
                                              typedQuestions[question],
                                            ),
                                          )
                                          .toList(),
                                    ),
                                  ),
                                ],
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
                                    : _answer(message.content),
                              ),
                            );
                          },
                        ),
                ),
                if (messages.isNotEmpty && followUps.isNotEmpty)
                  ExpansionTile(
                    controller: _followUpsController,
                    title: Text(
                      'Suggested next questions',
                      style: theme.textTheme.labelMedium,
                    ),
                    tilePadding: EdgeInsets.zero,
                    expandedAlignment: Alignment.centerLeft,
                    expandedCrossAxisAlignment: CrossAxisAlignment.start,
                    visualDensity: VisualDensity.compact,
                    initiallyExpanded: height > 1000,
                    children: [
                      SizedBox(
                        width: double.infinity,
                        child: Wrap(
                          alignment: WrapAlignment.center,
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final question in followUps)
                              _questionChip(question, typedQuestions[question]),
                          ],
                        ),
                      ),
                    ],
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
                            focusNode: _questionFocusNode,
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
    categories: discussion.vocab?.categoryLabels ?? const [],
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
