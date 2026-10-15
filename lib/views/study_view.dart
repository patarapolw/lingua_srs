import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/srs_card.dart';
import '../providers/app_provider.dart';
import '../services/audio_service.dart';
import '../widgets/audio_button.dart';
import '../widgets/markdown_content.dart';
import 'vocab_edit_dialog.dart';

class ReviewHistoryRecord {
  final int queueIndex;
  final SrsCard card;
  final int oldInterval;
  final int oldRepetitions;
  final double oldEaseFactor;
  final DateTime oldDueDate;
  final DateTime? oldLastReviewed;
  final SrsStatus oldStatus;
  final SrsRating ratingGiven;

  ReviewHistoryRecord({
    required this.queueIndex,
    required this.card,
    required this.oldInterval,
    required this.oldRepetitions,
    required this.oldEaseFactor,
    required this.oldDueDate,
    required this.oldLastReviewed,
    required this.oldStatus,
    required this.ratingGiven,
  });
}

class StudyView extends StatefulWidget {
  final String? lessonId;
  final bool dueOnly;

  const StudyView({super.key, this.lessonId, this.dueOnly = true});

  @override
  State<StudyView> createState() => _StudyViewState();
}

class _StudyViewState extends State<StudyView> {
  List<StudyCardItem> _queue = [];
  int _currentIndex = 0;
  int _answeredCount = 0; // Highest index of card answered so far
  bool _isAnswerRevealed = false;
  final List<ReviewHistoryRecord> _history = [];
  final FocusNode _keyboardFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadQueue();
    });
  }

  @override
  void dispose() {
    _keyboardFocusNode.dispose();
    super.dispose();
  }

  void _loadQueue() {
    final provider = context.read<AppProvider>();
    final queue = provider.getStudyQueue(
      lessonId: widget.lessonId,
      dueOnly: widget.dueOnly,
    );
    setState(() {
      _queue = queue;
      _currentIndex = 0;
      _answeredCount = 0;
      _isAnswerRevealed = false;
      _history.clear();
    });

    _triggerPreload(0);
  }

  /// Pre-buffers audio in background for the next few cards
  void _triggerPreload(int startIndex) {
    if (_queue.isEmpty) return;
    final audioService = context.read<AudioService>();
    final List<String?> urlsToPreload = [];

    for (int i = startIndex; i < startIndex + 3 && i < _queue.length; i++) {
      final item = _queue[i];
      if (item.vocab.audioUrl != null) {
        urlsToPreload.add(item.vocab.audioUrl);
      } else if (!audioService.usesOfflineTts) {
        urlsToPreload.add(
          audioService.getTtsUrl(
            item.vocab.targetWord,
            language: item.lesson.targetLanguage,
          ),
        );
      }
      if (item.sentence?.audioUrl != null) {
        urlsToPreload.add(item.sentence!.audioUrl);
      } else if (item.sentence != null && !audioService.usesOfflineTts) {
        urlsToPreload.add(
          audioService.getTtsUrl(
            item.sentence!.targetText,
            language: item.lesson.targetLanguage,
          ),
        );
      }
    }

    audioService.prefetchAudios(urlsToPreload);
  }

  void _toggleFlip() {
    if (_isAnswerRevealed) {
      // Flip back to front
      context.read<AudioService>().stop();
      setState(() => _isAnswerRevealed = false);
    } else {
      _revealAnswer();
    }
  }

  void _revealAnswer() {
    setState(() {
      _isAnswerRevealed = true;
    });

    final provider = context.read<AppProvider>();
    if (provider.autoplayAudio && _currentIndex < _queue.length) {
      final item = _queue[_currentIndex];
      final audioService = context.read<AudioService>();
      audioService.playAnswerSequence(
        vocabAudio: item.vocab.audioUrl,
        vocabText: item.vocab.targetWord,
        sentenceAudio: item.sentence?.audioUrl,
        sentenceText: item.sentence?.targetText,
        targetLanguage: item.lesson.targetLanguage,
      );
    }
  }

  void _rateCard(SrsRating rating) {
    if (_currentIndex >= _queue.length) return;
    context.read<AudioService>().stop();
    final item = _queue[_currentIndex];
    final provider = context.read<AppProvider>();

    // Save snapshot in history for Undo
    _history.add(
      ReviewHistoryRecord(
        queueIndex: _currentIndex,
        card: item.card,
        oldInterval: item.card.interval,
        oldRepetitions: item.card.repetitions,
        oldEaseFactor: item.card.easeFactor,
        oldDueDate: item.card.dueDate,
        oldLastReviewed: item.card.lastReviewed,
        oldStatus: item.card.status,
        ratingGiven: rating,
      ),
    );

    provider.recordCardReview(item.card, rating);

    setState(() {
      if (_currentIndex == _answeredCount) {
        _answeredCount++;
      }
      _currentIndex++;
      _isAnswerRevealed = false;
    });

    _triggerPreload(_currentIndex);
  }

  void _undo() {
    if (_history.isEmpty) return;
    context.read<AudioService>().stop();
    final provider = context.read<AppProvider>();
    final record = _history.removeLast();

    // Restore previous SRS state
    record.card.interval = record.oldInterval;
    record.card.repetitions = record.oldRepetitions;
    record.card.easeFactor = record.oldEaseFactor;
    record.card.dueDate = record.oldDueDate;
    record.card.lastReviewed = record.oldLastReviewed;
    record.card.status = record.oldStatus;
    provider.saveState();

    setState(() {
      _currentIndex = record.queueIndex;
      if (_answeredCount > _currentIndex) {
        _answeredCount = _currentIndex;
      }
      _isAnswerRevealed = true; // Show back of undone card ready to re-rate
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Undid rating (${record.ratingGiven.name.toUpperCase()}) for ${_queue[_currentIndex].vocab.targetWord}',
        ),
        duration: const Duration(milliseconds: 1400),
      ),
    );
  }

  void _navigateBack() {
    if (_currentIndex > 0) {
      context.read<AudioService>().stop();
      setState(() {
        _currentIndex--;
        _isAnswerRevealed =
            true; // Already answered card, show answer by default
      });
    }
  }

  void _navigateForward() {
    // Cannot go forward beyond unanswered cards
    if (_currentIndex < _answeredCount) {
      context.read<AudioService>().stop();
      setState(() {
        _currentIndex++;
        // If arrived at the unanswered card, show front, otherwise back
        _isAnswerRevealed = _currentIndex < _answeredCount;
      });
    }
  }

  void _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return;

    // Space: Flip between Front and Back
    if (event.logicalKey == LogicalKeyboardKey.space) {
      _toggleFlip();
      return;
    }

    // Enter key: If on front, reveals answer. If on back, presses GOOD (Rating 3)!
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      if (!_isAnswerRevealed) {
        _revealAnswer();
      } else {
        _rateCard(SrsRating.good);
      }
      return;
    }

    // Backspace key: Presses AGAIN (Rating 1) when answer is revealed
    if (event.logicalKey == LogicalKeyboardKey.backspace) {
      if (_isAnswerRevealed) {
        _rateCard(SrsRating.again);
      }
      return;
    }

    // Number keys 1-4 for SRS ratings
    if (_isAnswerRevealed) {
      if (event.logicalKey == LogicalKeyboardKey.digit1 ||
          event.logicalKey == LogicalKeyboardKey.numpad1) {
        _rateCard(SrsRating.again);
      } else if (event.logicalKey == LogicalKeyboardKey.digit2 ||
          event.logicalKey == LogicalKeyboardKey.numpad2) {
        _rateCard(SrsRating.hard);
      } else if (event.logicalKey == LogicalKeyboardKey.digit3 ||
          event.logicalKey == LogicalKeyboardKey.numpad3) {
        _rateCard(SrsRating.good);
      } else if (event.logicalKey == LogicalKeyboardKey.digit4 ||
          event.logicalKey == LogicalKeyboardKey.numpad4) {
        _rateCard(SrsRating.easy);
      }
    }

    // Navigation arrows (Back / Forward)
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _navigateBack();
    } else if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _navigateForward();
    }

    // Undo (Z or Ctrl+Z)
    if (event.logicalKey == LogicalKeyboardKey.keyZ) {
      _undo();
    }

    // Audio replay shortcuts
    if (event.logicalKey == LogicalKeyboardKey.keyR &&
        _currentIndex < _queue.length) {
      final item = _queue[_currentIndex];
      final audioService = context.read<AudioService>();
      if (item.vocab.audioUrl != null &&
          item.vocab.audioUrl!.trim().isNotEmpty) {
        audioService.playAudio(item.vocab.audioUrl);
      } else {
        audioService.speak(
          item.vocab.targetWord,
          language: item.lesson.targetLanguage,
        );
      }
    } else if (event.logicalKey == LogicalKeyboardKey.keyS &&
        _currentIndex < _queue.length) {
      final item = _queue[_currentIndex];
      if (item.sentence != null) {
        final audioService = context.read<AudioService>();
        if (item.sentence!.audioUrl != null &&
            item.sentence!.audioUrl!.trim().isNotEmpty) {
          audioService.playAudio(item.sentence!.audioUrl);
        } else {
          audioService.speak(
            item.sentence!.targetText,
            language: item.lesson.targetLanguage,
          );
        }
      }
    } else if (event.logicalKey == LogicalKeyboardKey.keyE &&
        _currentIndex < _queue.length) {
      _openEditCurrentCard();
    }
  }

  void _openEditCurrentCard() {
    if (_currentIndex >= _queue.length) return;
    final item = _queue[_currentIndex];
    VocabEditDialog.show(context, item.vocab, lessonId: item.lesson.id).then((
      _,
    ) {
      setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.watch<AppProvider>();

    if (_queue.isEmpty || _currentIndex >= _queue.length) {
      return Scaffold(
        appBar: AppBar(title: const Text('Study Complete')),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.check_circle_outline_rounded,
                size: 72,
                color: Colors.green.shade600,
              ),
              const SizedBox(height: 16),
              Text(
                'Session Complete!',
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'You have reviewed all available flashcards in this queue.',
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  OutlinedButton.icon(
                    icon: const Icon(Icons.arrow_back),
                    label: const Text('Back to Lessons'),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(width: 16),
                  if (_history.isNotEmpty) ...[
                    FilledButton.tonalIcon(
                      icon: const Icon(Icons.undo),
                      label: const Text('Undo Last Card (Z)'),
                      onPressed: _undo,
                    ),
                    const SizedBox(width: 16),
                  ],
                  FilledButton.icon(
                    icon: const Icon(Icons.refresh),
                    label: const Text('Review All (Cram Mode)'),
                    onPressed: () {
                      final allQueue = provider.getStudyQueue(
                        lessonId: widget.lessonId,
                        dueOnly: false,
                      );
                      setState(() {
                        _queue = allQueue;
                        _currentIndex = 0;
                        _answeredCount = 0;
                        _isAnswerRevealed = false;
                        _history.clear();
                      });
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    final item = _queue[_currentIndex];
    final isTargetToNative = item.isTargetToNative;
    final total = _queue.length;
    final currentNumber = _currentIndex + 1;
    final canGoBack = _currentIndex > 0;
    final canGoForward = _currentIndex < _answeredCount;
    final canUndo = _history.isNotEmpty;

    return KeyboardListener(
      focusNode: _keyboardFocusNode,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: Scaffold(
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (item.lesson.effectiveUnitTitle != null)
                Text(
                  item.lesson.effectiveUnitTitle!,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              Text('${item.lesson.displayTitle} ($currentNumber/$total)'),
            ],
          ),
          actions: [
            // Back button (without undoing)
            IconButton(
              icon: const Icon(Icons.chevron_left),
              tooltip: 'Previous Card (Left Arrow)',
              onPressed: canGoBack ? _navigateBack : null,
            ),
            // Forward button (no forward beyond unanswered cards)
            IconButton(
              icon: const Icon(Icons.chevron_right),
              tooltip: canGoForward
                  ? 'Next Card (Right Arrow)'
                  : 'Cannot go forward beyond unanswered cards',
              onPressed: canGoForward ? _navigateForward : null,
            ),
            // Undo button
            IconButton(
              icon: const Icon(Icons.undo),
              tooltip: canUndo
                  ? 'Undo Last Rating (Z / Ctrl+Z)'
                  : 'Nothing to undo',
              onPressed: canUndo ? _undo : null,
            ),
            const VerticalDivider(width: 20, indent: 12, endIndent: 12),
            // Autoplay toggle
            Tooltip(
              message: 'Autoplay audio (with instant local caching)',
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    provider.autoplayAudio ? Icons.volume_up : Icons.volume_off,
                    size: 20,
                    color: provider.autoplayAudio
                        ? theme.colorScheme.primary
                        : theme.colorScheme.outline,
                  ),
                  const SizedBox(width: 4),
                  Switch(
                    value: provider.autoplayAudio,
                    onChanged: (_) => provider.toggleAutoplay(),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            // Edit card button
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: 'Edit Card (E)',
              onPressed: _openEditCurrentCard,
            ),
            const SizedBox(width: 14),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(4),
            child: LinearProgressIndicator(
              value: (_answeredCount) / total,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
            ),
          ),
        ),
        body: SafeArea(
          child: Column(
            children: [
              // Flashcard Canvas
              Expanded(
                child: Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 16,
                    ),
                    child: Container(
                      constraints: const BoxConstraints(maxWidth: 720),
                      child: InkWell(
                        onTap: _toggleFlip,
                        borderRadius: BorderRadius.circular(20),
                        child: Card(
                          elevation: 4,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(28),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                // Top Badges Row
                                Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Chip(
                                      avatar: Icon(
                                        isTargetToNative
                                            ? Icons.translate
                                            : Icons.format_paint,
                                        size: 16,
                                      ),
                                      label: Text(
                                        isTargetToNative
                                            ? '${item.lesson.targetLanguage.toUpperCase()} ➔ ${item.lesson.nativeLanguage.toUpperCase()}'
                                            : '${item.lesson.nativeLanguage.toUpperCase()} ➔ ${item.lesson.targetLanguage.toUpperCase()} (Cloze)',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      backgroundColor:
                                          theme.colorScheme.primaryContainer,
                                      labelStyle: TextStyle(
                                        color: theme
                                            .colorScheme
                                            .onPrimaryContainer,
                                      ),
                                    ),
                                    Row(
                                      children: [
                                        Chip(
                                          label: Text(
                                            item.vocab.pos.toUpperCase(),
                                          ),
                                          backgroundColor: theme
                                              .colorScheme
                                              .surfaceContainerHighest,
                                        ),
                                        const SizedBox(width: 6),
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 4,
                                          ),
                                          decoration: BoxDecoration(
                                            color: _isAnswerRevealed
                                                ? Colors.green.withValues(
                                                    alpha: 0.15,
                                                  )
                                                : Colors.blue.withValues(
                                                    alpha: 0.15,
                                                  ),
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                          ),
                                          child: Text(
                                            _isAnswerRevealed
                                                ? 'BACK (Answer)'
                                                : 'FRONT (Prompt)',
                                            style: TextStyle(
                                              fontSize: 11,
                                              fontWeight: FontWeight.bold,
                                              color: _isAnswerRevealed
                                                  ? Colors.green.shade800
                                                  : Colors.blue.shade800,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 24),

                                // ---------------- FRONT VIEW ----------------
                                if (!_isAnswerRevealed) ...[
                                  if (isTargetToNative) ...[
                                    // KO -> EN: Target Word on Front
                                    Center(
                                      child: Text(
                                        item.vocab.targetWord,
                                        style: theme.textTheme.displaySmall
                                            ?.copyWith(
                                              fontWeight: FontWeight.bold,
                                              color: theme.colorScheme.primary,
                                            ),
                                      ),
                                    ),
                                    const SizedBox(height: 20),
                                    // One Random Sentence always on front
                                    if (item.sentence != null)
                                      Container(
                                        padding: const EdgeInsets.all(16),
                                        decoration: BoxDecoration(
                                          color: theme
                                              .colorScheme
                                              .surfaceContainerHighest
                                              .withValues(alpha: 0.4),
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                          border: Border.all(
                                            color: theme
                                                .colorScheme
                                                .outlineVariant,
                                          ),
                                        ),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Row(
                                              children: [
                                                const Icon(
                                                  Icons.format_quote_rounded,
                                                  size: 18,
                                                ),
                                                const SizedBox(width: 6),
                                                Text(
                                                  'Context Sentence:',
                                                  style: theme
                                                      .textTheme
                                                      .labelMedium,
                                                ),
                                              ],
                                            ),
                                            const SizedBox(height: 8),
                                            MarkdownContent(
                                              content:
                                                  item.sentence!.targetText,
                                              style: theme.textTheme.titleMedium
                                                  ?.copyWith(height: 1.4),
                                            ),
                                          ],
                                        ),
                                      ),
                                  ] else ...[
                                    // EN -> KO: Native prompt + One Random Sentence with CLOZE DELETION on Front
                                    Center(
                                      child: Text(
                                        item.vocab.translation,
                                        style: theme.textTheme.headlineMedium
                                            ?.copyWith(
                                              fontWeight: FontWeight.bold,
                                              color: theme.colorScheme.primary,
                                            ),
                                        textAlign: TextAlign.center,
                                      ),
                                    ),
                                    const SizedBox(height: 20),
                                    // One Random Sentence with Cloze Deletion
                                    if (item.sentence != null)
                                      Container(
                                        padding: const EdgeInsets.all(16),
                                        decoration: BoxDecoration(
                                          color: theme
                                              .colorScheme
                                              .surfaceContainerHighest
                                              .withValues(alpha: 0.5),
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                          border: Border.all(
                                            color: theme.colorScheme.primary
                                                .withValues(alpha: 0.35),
                                            width: 1.5,
                                          ),
                                        ),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Row(
                                              children: [
                                                Icon(
                                                  Icons.quiz_outlined,
                                                  size: 18,
                                                  color:
                                                      theme.colorScheme.primary,
                                                ),
                                                const SizedBox(width: 6),
                                                Text(
                                                  'Fill in the blank (Cloze Deletion):',
                                                  style: theme
                                                      .textTheme
                                                      .labelMedium
                                                      ?.copyWith(
                                                        fontWeight:
                                                            FontWeight.bold,
                                                        color: theme
                                                            .colorScheme
                                                            .primary,
                                                      ),
                                                ),
                                              ],
                                            ),
                                            const SizedBox(height: 10),
                                            MarkdownContent(
                                              content: item.sentence!.toCloze(
                                                targetWord:
                                                    item.vocab.targetWord,
                                              ),
                                              style: theme.textTheme.titleLarge
                                                  ?.copyWith(
                                                    height: 1.4,
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                            ),
                                          ],
                                        ),
                                      ),
                                  ],

                                  const SizedBox(height: 28),
                                  Center(
                                    child: FilledButton.icon(
                                      style: FilledButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 36,
                                          vertical: 16,
                                        ),
                                        textStyle: const TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      icon: const Icon(Icons.touch_app),
                                      label: const Text(
                                        'Show Answer (Space / Enter)',
                                      ),
                                      onPressed: _revealAnswer,
                                    ),
                                  ),
                                ]
                                // ---------------- BACK VIEW ----------------
                                else ...[
                                  // Back Header: Target Word & Translation
                                  Center(
                                    child: Column(
                                      children: [
                                        Text(
                                          item.vocab.targetWord,
                                          style: theme.textTheme.headlineMedium
                                              ?.copyWith(
                                                fontWeight: FontWeight.bold,
                                                color:
                                                    theme.colorScheme.primary,
                                              ),
                                          textAlign: TextAlign.center,
                                        ),
                                        const SizedBox(height: 6),
                                        Text(
                                          item.vocab.translation,
                                          style: theme.textTheme.titleLarge,
                                          textAlign: TextAlign.center,
                                        ),
                                        const SizedBox(height: 14),

                                        // Audio Controls with Caching and TTS
                                        Wrap(
                                          spacing: 12,
                                          runSpacing: 8,
                                          alignment: WrapAlignment.center,
                                          children: [
                                            AudioButton(
                                              audioUrl: item.vocab.audioUrl,
                                              fallbackText:
                                                  item.vocab.targetWord,
                                              language:
                                                  item.lesson.targetLanguage,
                                              label: item.vocab.audioUrl != null
                                                  ? 'Vocab Audio (R)'
                                                  : 'Vocab TTS (R)',
                                            ),
                                            if (item.sentence != null)
                                              AudioButton(
                                                audioUrl:
                                                    item.sentence!.audioUrl,
                                                fallbackText:
                                                    item.sentence!.targetText,
                                                language:
                                                    item.lesson.targetLanguage,
                                                label:
                                                    item.sentence!.audioUrl !=
                                                        null
                                                    ? 'Sentence Audio (S)'
                                                    : 'Sentence TTS (S)',
                                              ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: 20),

                                  // Full Example Sentence
                                  if (item.sentence != null) ...[
                                    Container(
                                      padding: const EdgeInsets.all(16),
                                      decoration: BoxDecoration(
                                        color: theme
                                            .colorScheme
                                            .surfaceContainerHighest
                                            .withValues(alpha: 0.3),
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(
                                          color:
                                              theme.colorScheme.outlineVariant,
                                        ),
                                      ),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            mainAxisAlignment:
                                                MainAxisAlignment.spaceBetween,
                                            children: [
                                              Text(
                                                'Full Example Sentence:',
                                                style:
                                                    theme.textTheme.labelMedium,
                                              ),
                                              AudioButton(
                                                audioUrl:
                                                    item.sentence!.audioUrl,
                                                fallbackText:
                                                    item.sentence!.targetText,
                                                language:
                                                    item.lesson.targetLanguage,
                                                compact: true,
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 6),
                                          MarkdownContent(
                                            content: item.sentence!.targetText,
                                            style: theme.textTheme.titleMedium
                                                ?.copyWith(
                                                  fontWeight: FontWeight.w600,
                                                ),
                                          ),
                                          const SizedBox(height: 6),
                                          MarkdownContent(
                                            content: item.sentence!.translationText,
                                            style: theme.textTheme.bodyMedium
                                                ?.copyWith(
                                                  color: theme
                                                      .colorScheme
                                                      .onSurfaceVariant,
                                                ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(height: 16),
                                  ],

                                  // Notes (Markdown / HTML)
                                  if (item.vocab.notes.isNotEmpty) ...[
                                    Container(
                                      width: double.infinity,
                                      padding: const EdgeInsets.all(14),
                                      decoration: BoxDecoration(
                                        color: theme
                                            .colorScheme
                                            .secondaryContainer
                                            .withValues(alpha: 0.3),
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              const Icon(
                                                Icons.info_outline,
                                                size: 16,
                                              ),
                                              const SizedBox(width: 6),
                                              Text(
                                                'Notes & Nuances:',
                                                style:
                                                    theme.textTheme.labelMedium,
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 6),
                                          MarkdownContent(
                                            content: item.vocab.notes,
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(height: 16),
                                  ],

                                  // Flip back button
                                  Center(
                                    child: OutlinedButton.icon(
                                      icon: const Icon(Icons.flip_to_front),
                                      label: const Text(
                                        'Flip Back to Front (Space)',
                                      ),
                                      onPressed: _toggleFlip,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),

              // Bottom SRS Rating Bar (Accessible when answer revealed)
              if (_isAnswerRevealed)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.08),
                        blurRadius: 8,
                        offset: const Offset(0, -3),
                      ),
                    ],
                  ),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 720),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: FilledButton.tonal(
                                  style: FilledButton.styleFrom(
                                    backgroundColor: Colors.red.shade100,
                                    foregroundColor: Colors.red.shade900,
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 14,
                                    ),
                                  ),
                                  onPressed: () => _rateCard(SrsRating.again),
                                  child: const Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        'Again [⌫]',
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      Text(
                                        'Key 1 / Backspace',
                                        style: TextStyle(fontSize: 10),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: FilledButton.tonal(
                                  style: FilledButton.styleFrom(
                                    backgroundColor: Colors.orange.shade100,
                                    foregroundColor: Colors.orange.shade900,
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 14,
                                    ),
                                  ),
                                  onPressed: () => _rateCard(SrsRating.hard),
                                  child: const Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        'Hard',
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      Text(
                                        'Key 2',
                                        style: TextStyle(fontSize: 10),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                flex: 2,
                                child: FilledButton(
                                  style: FilledButton.styleFrom(
                                    backgroundColor: Colors.green.shade700,
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 14,
                                    ),
                                  ),
                                  onPressed: () => _rateCard(SrsRating.good),
                                  child: const Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        'Good [Enter ↵]',
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 16,
                                        ),
                                      ),
                                      Text(
                                        'Key 3 or Enter',
                                        style: TextStyle(fontSize: 10),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: FilledButton.tonal(
                                  style: FilledButton.styleFrom(
                                    backgroundColor: Colors.blue.shade100,
                                    foregroundColor: Colors.blue.shade900,
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 14,
                                    ),
                                  ),
                                  onPressed: () => _rateCard(SrsRating.easy),
                                  child: const Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        'Easy',
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      Text(
                                        'Key 4',
                                        style: TextStyle(fontSize: 10),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                'Shortcuts: [Space] Flip • [Enter] Good • [Backspace] Again • [← / →] Back/Fwd • [Z] Undo',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.outline,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
