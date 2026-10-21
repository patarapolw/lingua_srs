import 'dart:math';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:provider/provider.dart';

import '../models/srs_card.dart';
import '../providers/app_provider.dart';
import '../services/audio_service.dart';
import '../services/srs_service.dart';
import '../widgets/audio_button.dart';
import '../widgets/markdown_content.dart';
import '../widgets/pronunciation_line.dart';
import '../widgets/pronunciation_toggle.dart';
import 'ai_discussion_dialog.dart';
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
  final int oldLapses;
  final DateTime? oldLastMistakeDate;
  final SrsRating? oldLastRating;
  SrsRating ratingGiven;
  StudyCardItem? requeuedItem;
  final bool wasInAgainSet;
  final bool wasFirstSessionRating;
  final DateTime? oldMistakesClearedAt;

  ReviewHistoryRecord({
    required this.queueIndex,
    required this.card,
    required this.oldInterval,
    required this.oldRepetitions,
    required this.oldEaseFactor,
    required this.oldDueDate,
    required this.oldLastReviewed,
    required this.oldStatus,
    required this.oldLapses,
    required this.oldLastMistakeDate,
    required this.oldLastRating,
    required this.ratingGiven,
    this.wasInAgainSet = false,
    this.wasFirstSessionRating = true,
    this.oldMistakesClearedAt,
  });

  /// Must be called BEFORE the review mutates [card].
  factory ReviewHistoryRecord.capture({
    required int queueIndex,
    required SrsCard card,
    required SrsRating rating,
    bool wasInAgainSet = false,
    bool wasFirstSessionRating = true,
  }) => ReviewHistoryRecord(
    queueIndex: queueIndex,
    card: card,
    oldInterval: card.interval,
    oldRepetitions: card.repetitions,
    oldEaseFactor: card.easeFactor,
    oldDueDate: card.dueDate,
    oldLastReviewed: card.lastReviewed,
    oldStatus: card.status,
    oldLapses: card.lapses,
    oldLastMistakeDate: card.lastMistakeDate,
    oldLastRating: card.lastRating,
    ratingGiven: rating,
    wasInAgainSet: wasInAgainSet,
    wasFirstSessionRating: wasFirstSessionRating,
    oldMistakesClearedAt: card.mistakesClearedAt,
  );

  void restore() {
    card.interval = oldInterval;
    card.repetitions = oldRepetitions;
    card.easeFactor = oldEaseFactor;
    card.dueDate = oldDueDate;
    card.lastReviewed = oldLastReviewed;
    card.status = oldStatus;
    card.lapses = oldLapses;
    card.lastMistakeDate = oldLastMistakeDate;
    card.lastRating = oldLastRating;
    card.mistakesClearedAt = oldMistakesClearedAt;
  }
}

/// Cards marked something other than Again on their FIRST pass.
int firstPassRightCount(Iterable<ReviewHistoryRecord> history) => history
    .where((r) => r.wasFirstSessionRating && r.ratingGiven != SrsRating.again)
    .length;

/// Cards marked Again on their FIRST pass. Second-pass answers don't count.
int firstPassWrongCount(Iterable<ReviewHistoryRecord> history) => history
    .where((r) => r.wasFirstSessionRating && r.ratingGiven == SrsRating.again)
    .length;

/// Number of different cards in the queue. A card that was re-queued after
/// Again appears twice in the queue but is still one card.
int distinctCardCount(List<StudyCardItem> queue) =>
    queue.map((i) => i.card.id).toSet().length;

/// 1-based progress through the DISTINCT cards in [queue], up to and
/// including [index]. A re-queued repeat doesn't advance it.
int distinctProgress(List<StudyCardItem> queue, int index) {
  final seen = <String>{};
  for (var i = 0; i <= index && i < queue.length; i++) {
    seen.add(queue[i].card.id);
  }
  return seen.length;
}

/// Changes the rating of an already-answered card.
/// Mutates the card, [queue], [againCardIds] and [record].
void reRateRecord({
  required ReviewHistoryRecord record,
  required SrsRating rating,
  required bool practiceOnly,
  required List<ReviewHistoryRecord> history,
  required List<StudyCardItem> queue,
  required int answeredCount,
  required Set<String> againCardIds,
  required StudyCardItem Function(StudyCardItem source) makeDuplicate,
}) {
  final card = record.card;
  final wasAgain = record.ratingGiven == SrsRating.again;
  final nowAgain = rating == SrsRating.again;

  // 1. Card state.
  if (practiceOnly) {
    // Mistakes practice never touches SRS; it only clears/restores the mistake.
    card.mistakesClearedAt = nowAgain
        ? record.oldMistakesClearedAt
        : DateTime.now();
  } else if (record.wasFirstSessionRating) {
    record.restore();
    // processReview directly, not recordCardReview: a re-mark must not add
    // another entry to the 24h review counter.
    SrsService.processReview(card, rating);
  } else {
    // A repeat review no longer changes the card
  }

  // 2. Queue and Again set. Positions before answeredCount are never shifted,
  //    so queue[record.queueIndex] is still this card.
  if (!wasAgain && nowAgain) {
    againCardIds.add(card.id);
    final remainingAhead = queue.length - answeredCount;
    StudyCardItem? dup;
    if (remainingAhead >= 3) {
      dup = makeDuplicate(queue[record.queueIndex]);
      queue.insert(min(queue.length, answeredCount + 3), dup);
    } else if (remainingAhead > 0 || againCardIds.length > 1) {
      // Same end-of-queue rule as _rateCard: only re-queue at the very end
      // if more than one Again'd card remains.
      dup = makeDuplicate(queue[record.queueIndex]);
      queue.add(dup);
    }
    record.requeuedItem = dup;
  } else if (wasAgain && !nowAgain) {
    againCardIds.remove(card.id);
    final dup = record.requeuedItem;
    if (dup != null) {
      final at = queue.indexOf(dup);
      // Keep the duplicate if it was already shown and answered.
      if (at >= answeredCount) queue.removeAt(at);
      record.requeuedItem = null;
    }
  }

  record.ratingGiven = rating;
}

class StudyView extends StatefulWidget {
  final String? lessonId;
  final bool dueOnly;
  final bool recentMistakesOnly;

  const StudyView({
    super.key,
    this.lessonId,
    this.dueOnly = true,
    this.recentMistakesOnly = false,
  });

  @override
  State<StudyView> createState() => _StudyViewState();
}

class _StudyViewState extends State<StudyView> {
  List<StudyCardItem> _queue = [];
  int _currentIndex = 0;
  int _answeredCount = 0; // Highest index of card answered so far
  bool _isAnswerRevealed = false;
  final List<ReviewHistoryRecord> _history = [];
  final Set<String> _againCardIds = {};
  final Set<String> _sessionRatedCardIds = {};
  final FocusNode _keyboardFocusNode = FocusNode();

  // Keyboard hints are noise on touch platforms; the handlers still work for
  // attached keyboards.
  bool get _showKeyHints => switch (defaultTargetPlatform) {
    TargetPlatform.android ||
    TargetPlatform.iOS ||
    TargetPlatform.fuchsia => false,
    _ => true,
  };
  int get rightCount => firstPassRightCount(_history);
  int get wrongCount => firstPassWrongCount(_history);

  bool get _isReviewingPast => _currentIndex < _answeredCount;

  ReviewHistoryRecord? _recordAt(int index) {
    final i = _history.lastIndexWhere((r) => r.queueIndex == index);
    return i == -1 ? null : _history[i];
  }

  String _nextIn(SrsRating rating) {
    var card = _queue[_currentIndex].card;
    final record = _isReviewingPast ? _recordAt(_currentIndex) : null;
    if (record != null) {
      card = SrsCard(
        direction: card.direction,
        interval: record.oldInterval,
        repetitions: record.oldRepetitions,
        easeFactor: record.oldEaseFactor,
        dueDate: record.oldDueDate,
        status: record.oldStatus,
      );
    }
    return SrsService.formatDuration(SrsService.previewInterval(card, rating));
  }

  bool get _isPracticeOnly => widget.recentMistakesOnly;

  // Cards already rated this session (Again interleaving), and all cards in
  // mistakes practice, only offer Again/Good.
  bool get _isRepeatCard {
    if (_isPracticeOnly) return true;
    if (_currentIndex >= _queue.length) return false;
    if (_isReviewingPast) {
      final r = _recordAt(_currentIndex);
      return r != null && !r.wasFirstSessionRating;
    }
    return _sessionRatedCardIds.contains(_queue[_currentIndex].card.id);
  }

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
      dueOnly: widget.recentMistakesOnly ? false : widget.dueOnly,
      mistakesOnly: widget.recentMistakesOnly,
    );
    setState(() {
      _queue = queue;
      _currentIndex = 0;
      _answeredCount = 0;
      _isAnswerRevealed = false;
      _history.clear();
      _againCardIds.clear();
      _sessionRatedCardIds.clear();
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

  Widget _notePanel(BuildContext context, String title, String content) {
    if (content.trim().isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.labelMedium),
          const SizedBox(height: 6),
          MarkdownContent(content: content),
        ],
      ),
    );
  }

  Widget _disambiguationCue(BuildContext context, String cue) {
    if (cue.trim().isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.tertiaryContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          child: MarkdownContent(
            content: cue,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onTertiaryContainer,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
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
    if (_isReviewingPast) {
      _reRatePast(rating);
      return;
    }
    final isRepeat = _isRepeatCard;
    if (isRepeat && (rating == SrsRating.hard || rating == SrsRating.easy)) {
      return;
    }
    context.read<AudioService>().stop();
    final item = _queue[_currentIndex];
    final card = item.card;
    final cardId = card.id;
    final provider = context.read<AppProvider>();
    final wasInAgainSet = _againCardIds.contains(cardId);

    StudyCardItem? requeuedItem;

    final isFirstSessionRating = !_sessionRatedCardIds.contains(cardId);
    _sessionRatedCardIds.add(cardId);

    // Snapshot BEFORE the review mutates the card.
    final record = ReviewHistoryRecord.capture(
      queueIndex: _currentIndex,
      card: card,
      rating: rating,
      wasInAgainSet: wasInAgainSet,
      wasFirstSessionRating: isFirstSessionRating,
    );

    if (rating == SrsRating.again) {
      _againCardIds.add(cardId);
      if (_isPracticeOnly) {
        // Mistakes practice never touches SRS state.
      } else if (isFirstSessionRating) {
        provider.recordCardReview(card, SrsRating.again);
      }

      // Interleaved re-queuing:
      // Do not end the session unless there is only 1 Again'd card left.
      final remainingAhead = _queue.length - (_currentIndex + 1);
      final newItem = StudyCardItem(
        vocab: item.vocab,
        card: item.card,
        lesson: item.lesson,
        sentence: provider.getRandomSentenceForVocab(item.vocab),
      );

      if (remainingAhead >= 3) {
        final targetIndex = min(_queue.length, _currentIndex + 4);
        _queue.insert(targetIndex, newItem);
        requeuedItem = newItem;
      } else if (remainingAhead > 0) {
        _queue.add(newItem);
        requeuedItem = newItem;
      } else {
        // At the very end of the queue:
        // If more than 1 Again'd card remains, keep re-queuing interleaved!
        // If only 1 Again'd card remains, do not re-queue so the session can conclude.
        if (_againCardIds.length > 1) {
          _queue.add(newItem);
          requeuedItem = newItem;
        }
      }
    } else {
      _againCardIds.remove(cardId);
      if (_isPracticeOnly) {
        // Good in mistakes practice dismisses the mistake without touching SRS.
        card.mistakesClearedAt = DateTime.now();
        provider.saveState();
      } else if (isFirstSessionRating) {
        provider.recordCardReview(card, rating);
      }
    }

    record.requeuedItem = requeuedItem;

    // Save snapshot in history for Undo (values captured before the review)
    _history.add(record);

    setState(() {
      if (_currentIndex == _answeredCount) {
        _answeredCount++;
      }
      _currentIndex++;
      _isAnswerRevealed = false;
    });

    _triggerPreload(_currentIndex);
  }

  void _reRatePast(SrsRating rating) {
    final record = _recordAt(_currentIndex);
    if (record == null) return;
    if (record.ratingGiven == rating) {
      _navigateForward();
      return;
    }
    if (_isRepeatCard &&
        (rating == SrsRating.hard || rating == SrsRating.easy)) {
      return;
    }
    context.read<AudioService>().stop();
    final provider = context.read<AppProvider>();
    reRateRecord(
      record: record,
      rating: rating,
      practiceOnly: _isPracticeOnly,
      history: _history,
      queue: _queue,
      answeredCount: _answeredCount,
      againCardIds: _againCardIds,
      makeDuplicate: (source) => StudyCardItem(
        vocab: source.vocab,
        card: source.card,
        lesson: source.lesson,
        sentence: provider.getRandomSentenceForVocab(source.vocab),
      ),
    );
    provider.saveState();
    _navigateForward();
  }

  void _undo() {
    if (_history.isEmpty) return;
    context.read<AudioService>().stop();
    final provider = context.read<AppProvider>();
    final record = _history.removeLast();

    // Remove the re-queued duplicate if one was inserted
    final dup = record.requeuedItem;
    if (dup != null) _queue.remove(dup); // StudyCardItem has no ==, so identity

    if (record.wasFirstSessionRating) {
      _sessionRatedCardIds.remove(record.card.id);
    }

    if (record.wasInAgainSet) {
      _againCardIds.add(record.card.id);
    } else {
      _againCardIds.remove(record.card.id);
    }

    // Restore previous SRS state
    record.restore();
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

  void _openAiDiscussion(StudyCardItem item) {
    final sentence = item.sentence;
    showDialog<void>(
      context: context,
      builder: (_) => AiDiscussionDialog(
        discussionId: '${item.vocab.id}:${sentence?.id ?? 'no-sentence'}',
        targetWord: item.vocab.targetWord,
        translation: item.vocab.translation,
        targetLanguage: item.lesson.targetLanguage,
        nativeLanguage: item.lesson.nativeLanguage,
        sentenceTarget: sentence?.targetText,
        sentenceTranslation: sentence?.translationText,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.watch<AppProvider>();

    if (_queue.isEmpty || _currentIndex >= _queue.length) {
      final isMistakesMode = widget.recentMistakesOnly;
      final hasPostponedCard = _againCardIds.length == 1;

      return Scaffold(
        appBar: AppBar(
          title: Text(
            isMistakesMode ? 'Recent Mistakes Complete' : 'Study Complete',
          ),
        ),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                hasPostponedCard
                    ? Icons.pending_actions_rounded
                    : Icons.check_circle_outline_rounded,
                size: 72,
                color: hasPostponedCard
                    ? Colors.amber.shade700
                    : Colors.green.shade600,
              ),
              const SizedBox(height: 16),
              Text(
                isMistakesMode
                    ? (hasPostponedCard
                          ? 'Mistakes Review Finished'
                          : 'All Recent Mistakes Cleared!')
                    : 'Session Complete!',
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                hasPostponedCard
                    ? '1 difficult card was postponed for your next review session.'
                    : (_queue.isEmpty
                          ? 'No cards found matching this queue.'
                          : 'You have completed all cards in this review queue.'),
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 24),
              Wrap(
                alignment: WrapAlignment.center,
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
                      label: Text(
                        _showKeyHints ? 'Undo Last Card (Z)' : 'Undo Last Card',
                      ),
                      onPressed: _undo,
                    ),
                    const SizedBox(width: 16),
                  ],
                  if (hasPostponedCard) ...[
                    FilledButton.icon(
                      icon: const Icon(Icons.replay),
                      label: const Text('Retry Remaining Card'),
                      onPressed: () {
                        final remainingCardId = _againCardIds.first;
                        final retryQueue = provider
                            .getStudyQueue(dueOnly: false)
                            .where((item) => item.card.id == remainingCardId)
                            .toList();
                        setState(() {
                          _queue = retryQueue;
                          _currentIndex = 0;
                          _answeredCount = 0;
                          _isAnswerRevealed = false;
                          _history.clear();
                          _againCardIds.clear();
                          _sessionRatedCardIds.clear();
                        });
                      },
                    ),
                  ] else ...[
                    FilledButton.icon(
                      icon: const Icon(Icons.refresh),
                      label: Text(
                        isMistakesMode
                            ? 'Review Mistakes Again'
                            : 'Review All (Cram Mode)',
                      ),
                      onPressed: () {
                        final reloadQueue = provider.getStudyQueue(
                          lessonId: widget.lessonId,
                          dueOnly: false,
                          mistakesOnly: isMistakesMode,
                        );
                        setState(() {
                          _queue = reloadQueue;
                          _currentIndex = 0;
                          _answeredCount = 0;
                          _isAnswerRevealed = false;
                          _history.clear();
                          _againCardIds.clear();
                          _sessionRatedCardIds.clear();
                        });
                      },
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      );
    }

    final item = _queue[_currentIndex];
    final isTargetToNative = item.isTargetToNative;
    final total = distinctCardCount(_queue);
    final currentNumber = distinctProgress(_queue, _currentIndex);
    final canGoBack = _currentIndex > 0;
    final canGoForward = _currentIndex < _answeredCount;
    final canUndo = _history.isNotEmpty;

    PopupMenuItem<String> moreItem(
      String value,
      IconData icon,
      String title, {
      bool enabled = true,
    }) => PopupMenuItem<String>(
      value: value,
      enabled: enabled,
      child: ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: Icon(icon),
        title: Text(title),
      ),
    );

    return KeyboardListener(
      focusNode: _keyboardFocusNode,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: Scaffold(
        appBar: AppBar(
          title: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (widget.recentMistakesOnly) ...[
                      const Text('Recent Mistakes Review'),
                      Text(
                        'Card $currentNumber of $total',
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ] else if (MediaQuery.sizeOf(context).width < 700)
                      Text(
                        '$currentNumber / $total',
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.fade,
                      )
                    else ...[
                      if (item.lesson.effectiveUnitTitle != null)
                        Text(
                          item.lesson.effectiveUnitTitle!,
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      Text(
                        '${item.lesson.displayTitle} ($currentNumber/$total)',
                      ),
                    ],
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '✓ $rightCount',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Colors.green.shade800,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '✗ $wrongCount',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Colors.red.shade800,
                  ),
                ),
              ),
            ],
          ),
          actions: [
            // Back button (without undoing)
            IconButton(
              icon: const Icon(Icons.chevron_left),
              tooltip: _showKeyHints
                  ? 'Previous Card (Left Arrow)'
                  : 'Previous Card',
              onPressed: canGoBack ? _navigateBack : null,
            ),
            // Forward button (no forward beyond unanswered cards)
            IconButton(
              icon: const Icon(Icons.chevron_right),
              tooltip: canGoForward
                  ? (_showKeyHints ? 'Next Card (Right Arrow)' : 'Next Card')
                  : 'Cannot go forward beyond unanswered cards',
              onPressed: canGoForward ? _navigateForward : null,
            ),
            if (canUndo && MediaQuery.sizeOf(context).width >= 700)
              IconButton(
                icon: const Icon(Icons.undo),
                tooltip: canUndo
                    ? (_showKeyHints
                          ? 'Undo Last Rating (Z / Ctrl+Z)'
                          : 'Undo Last Rating')
                    : 'Nothing to undo',
                onPressed: canUndo ? _undo : null,
              ),
            IconButton(
              tooltip: 'Autoplay audio',
              isSelected: provider.autoplayAudio,
              icon: const Icon(Icons.volume_off),
              selectedIcon: const Icon(Icons.volume_up),
              onPressed: provider.toggleAutoplay,
            ),
            PopupMenuButton<String>(
              tooltip: 'More',
              onSelected: (value) {
                switch (value) {
                  case 'undo':
                    _undo();
                  case 'edit':
                    _openEditCurrentCard();
                  case 'ai':
                    _openAiDiscussion(item);
                }
              },
              itemBuilder: (context) => [
                if (canUndo && MediaQuery.sizeOf(context).width < 700)
                  moreItem(
                    'undo',
                    Icons.undo,
                    _showKeyHints
                        ? 'Undo last rating (Z / Ctrl+Z)'
                        : 'Undo last rating',
                    enabled: canUndo,
                  ),
                moreItem(
                  'edit',
                  Icons.edit_outlined,
                  _showKeyHints ? 'Edit card (E)' : 'Edit card',
                ),
                moreItem(
                  'ai',
                  Icons.forum_outlined,
                  'Ask AI',
                  enabled: _isAnswerRevealed,
                ),
                if (item.lesson.targetLanguage == 'ko') ...[
                  const PopupMenuDivider(),
                  PronunciationToggleMenuEntry(enabled: _isAnswerRevealed),
                ],
              ],
            ),
            const SizedBox(width: 8),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(6),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final totalWidth = constraints.maxWidth;
                final totalCards = _queue.isEmpty
                    ? 1
                    : distinctCardCount(_queue);
                final rightWidth =
                    (rightCount / totalCards).clamp(0.0, 1.0) * totalWidth;
                final wrongWidth =
                    (wrongCount / totalCards).clamp(0.0, 1.0) * totalWidth;
                final remainingWidth = max(
                  0.0,
                  totalWidth - rightWidth - wrongWidth,
                );

                return SizedBox(
                  height: 6,
                  child: Row(
                    children: [
                      if (rightWidth > 0)
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          width: rightWidth,
                          color: Colors.green.shade600,
                        ),
                      if (wrongWidth > 0)
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          width: wrongWidth,
                          color: Colors.red.shade600,
                        ),
                      if (remainingWidth > 0)
                        Expanded(
                          child: Container(
                            color: theme.colorScheme.surfaceContainerHighest,
                          ),
                        ),
                    ],
                  ),
                );
              },
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
                        onTap: _isAnswerRevealed ? null : _toggleFlip,
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
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 4,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    Chip(
                                      visualDensity: VisualDensity.compact,
                                      avatar: Icon(
                                        isTargetToNative
                                            ? Icons.translate
                                            : Icons.format_paint,
                                        size: 16,
                                      ),
                                      label: Text(
                                        isTargetToNative
                                            ? '${item.lesson.targetLanguage.toUpperCase()} ➔ ${item.lesson.nativeLanguage.toUpperCase()}'
                                            : '${item.lesson.nativeLanguage.toUpperCase()} ➔ ${item.lesson.targetLanguage.toUpperCase()}',
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
                                    Chip(
                                      visualDensity: VisualDensity.compact,
                                      label: Text(
                                        item.vocab.pos
                                            .replaceAll('_', ' ')
                                            .toUpperCase(),
                                      ),
                                      backgroundColor: theme
                                          .colorScheme
                                          .surfaceContainerHighest,
                                    ),
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
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Text(
                                        _isAnswerRevealed ? 'BACK' : 'FRONT',
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
                                    _disambiguationCue(
                                      context,
                                      item.vocab.frontHintFor(
                                        CardDirection.targetToNative,
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
                                              CrossAxisAlignment.center,
                                          children: [
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
                                    _disambiguationCue(
                                      context,
                                      item.vocab.frontHintFor(
                                        CardDirection.nativeToTarget,
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
                                              CrossAxisAlignment.center,
                                          children: [
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
                                      label: Text(
                                        _showKeyHints
                                            ? 'Show Answer (Space / Enter)'
                                            : 'Show Answer',
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
                                        Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Flexible(
                                              child: Text(
                                                item.vocab.targetWord,
                                                style: theme
                                                    .textTheme
                                                    .headlineMedium
                                                    ?.copyWith(
                                                      fontWeight:
                                                          FontWeight.bold,
                                                      color: theme
                                                          .colorScheme
                                                          .primary,
                                                    ),
                                                textAlign: TextAlign.center,
                                              ),
                                            ),
                                            AudioButton(
                                              audioUrl: item.vocab.audioUrl,
                                              fallbackText:
                                                  item.vocab.targetWord,
                                              language:
                                                  item.lesson.targetLanguage,
                                              compact: true,
                                            ),
                                          ],
                                        ),
                                        PronunciationLine(
                                          text: item.vocab.targetWord,
                                          languageCode:
                                              item.lesson.targetLanguage,
                                          target:
                                              PronunciationTarget.vocabulary,
                                        ),
                                        const SizedBox(height: 6),
                                        Text(
                                          item.vocab.translation,
                                          style: theme.textTheme.titleLarge,
                                          textAlign: TextAlign.center,
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
                                              Expanded(
                                                child: MarkdownContent(
                                                  content:
                                                      item.sentence!.targetText,
                                                  style: theme
                                                      .textTheme
                                                      .titleMedium
                                                      ?.copyWith(
                                                        fontWeight:
                                                            FontWeight.w600,
                                                      ),
                                                ),
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
                                          PronunciationLine(
                                            text: item.sentence!.targetText,
                                            languageCode:
                                                item.lesson.targetLanguage,
                                            centered: false,
                                            target:
                                                PronunciationTarget.sentence,
                                          ),
                                          const SizedBox(height: 6),
                                          SpoilerBlock(
                                            key: ValueKey(
                                              '$_currentIndex-${item.sentence!.id}',
                                            ),
                                            child: MarkdownContent(
                                              content: item
                                                  .sentence!
                                                  .translationText,
                                              style: theme.textTheme.bodyMedium
                                                  ?.copyWith(
                                                    color: theme
                                                        .colorScheme
                                                        .onSurfaceVariant,
                                                  ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(height: 16),
                                  ],

                                  _notePanel(
                                    context,
                                    'Back notes',
                                    item.card.backNotes,
                                  ),
                                  if (item.sentence != null)
                                    _notePanel(
                                      context,
                                      'Sentence notes',
                                      item.sentence!.notes,
                                    ),

                                  // Notes (Markdown)
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
                                            selectable: true,
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
                                      label: Text(
                                        _showKeyHints
                                            ? 'Flip back to Front (Space)'
                                            : 'Flip back to Front',
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

              if (_isReviewingPast)
                Text(
                  'Currently ${_recordAt(_currentIndex)?.ratingGiven.name.toUpperCase()}',
                  style: Theme.of(context).textTheme.labelSmall,
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
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        _showKeyHints ? 'Again [⌫]' : 'Again',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      if (!_isRepeatCard)
                                        Text(
                                          _nextIn(SrsRating.again),
                                          style: const TextStyle(fontSize: 11),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                              if (!_isRepeatCard) ...[
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
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Text(
                                          'Hard',
                                          style: TextStyle(
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        Text(
                                          _nextIn(SrsRating.hard),
                                          style: const TextStyle(fontSize: 11),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
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
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        _showKeyHints
                                            ? 'Good [Enter ↵]'
                                            : 'Good',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 16,
                                        ),
                                      ),
                                      if (!_isRepeatCard)
                                        Text(
                                          _nextIn(SrsRating.good),
                                          style: const TextStyle(fontSize: 11),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                              if (!_isRepeatCard) ...[
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
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Text(
                                          'Easy',
                                          style: TextStyle(
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        Text(
                                          _nextIn(SrsRating.easy),
                                          style: const TextStyle(fontSize: 11),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          if (_showKeyHints) ...[
                            const SizedBox(height: 6),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  _isRepeatCard
                                      ? 'Shortcuts: [Space] Flip • [1 / ⌫] Again • [3 / Enter] Good • [← / →] Back/Fwd • [Z] Undo'
                                      : 'Shortcuts: [Space] Flip • [1] Again • [2] Hard • [3 / Enter] Good • [4] Easy • [⌫] Again • [← / →] Back/Fwd • [Z] Undo',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.outline,
                                  ),
                                ),
                              ],
                            ),
                          ],
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
