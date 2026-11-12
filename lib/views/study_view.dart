import 'dart:async' show scheduleMicrotask, unawaited;
import 'dart:math';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import 'package:provider/provider.dart';

import '../models/srs_card.dart';
import '../models/vocab_item.dart';
import '../providers/app_provider.dart';
import '../services/ai_discussion_search.dart';
import '../services/audio_service.dart';
import '../services/srs_service.dart';
import '../services/study_queue_order.dart';
import '../widgets/audio_button.dart';
import '../widgets/answer_workspace.dart';
import '../widgets/emphasis_text.dart';
import '../widgets/markdown_content.dart';
import '../widgets/pronunciation_line.dart';
import '../widgets/pronunciation_toggle.dart';
import '../widgets/review_notes_editor.dart';
import '../widgets/vocab_forms.dart';
import 'ai_discussion_dialog.dart';
import 'vocab_edit_dialog.dart';

/// A study-session action that Undo takes back, newest last: a rating
/// ([ReviewHistoryRecord]), [SendToBackRecord], [SuspendRecord] or
/// [ResetRecord]. Wrap up is not one: it is turned on and off on its
/// own ([WrapUpRecord]).
sealed class SessionUndoEntry {}

class ReviewHistoryRecord implements SessionUndoEntry {
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
  final DateTime? oldIntroducedAt;

  /// When this rating was counted by [AppProvider.recordCardReview], so that
  /// undo can take the count back. Null when it was not counted (a repeat in
  /// the session, or mistakes practice).
  DateTime? countedAt;

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
    this.oldIntroducedAt,
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
    oldIntroducedAt: card.introducedAt,
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
    card.introducedAt = oldIntroducedAt;
  }
}

/// The first-pass record that decides each card: of the records flagged as a
/// first session rating, the one at the latest queue position. A card normally
/// has one, but a card reset to New mid-session is rated as a first review
/// again, and must not be counted twice.
Iterable<ReviewHistoryRecord> _decidingFirstPassRecords(
  Iterable<ReviewHistoryRecord> history,
) {
  final latest = <String, ReviewHistoryRecord>{};
  for (final r in history) {
    if (!r.wasFirstSessionRating) continue;
    final current = latest[r.card.id];
    if (current == null || r.queueIndex >= current.queueIndex) {
      latest[r.card.id] = r;
    }
  }
  return latest.values;
}

/// Cards marked Good or Easy on their FIRST pass. Second-pass answers don't
/// count, and a card reset and re-rated this session counts once.
int firstPassRightCount(Iterable<ReviewHistoryRecord> history) =>
    _decidingFirstPassRecords(history)
        .where(
          (r) =>
              r.ratingGiven == SrsRating.good ||
              r.ratingGiven == SrsRating.easy,
        )
        .length;

/// Cards marked Again or Hard on their FIRST pass. Second-pass answers don't
/// count, and a card reset and re-rated this session counts once.
int firstPassWrongCount(Iterable<ReviewHistoryRecord> history) =>
    _decidingFirstPassRecords(history)
        .where(
          (r) =>
              r.ratingGiven == SrsRating.again ||
              r.ratingGiven == SrsRating.hard,
        )
        .length;

/// The rating that currently decides each card, keyed by card id: the answer
/// at the latest queue position, so a re-queued repeat overrides the first
/// pass, and re-rating an earlier position never overrides a later one.
Map<String, SrsRating> latestRatings(Iterable<ReviewHistoryRecord> history) {
  final latest = <String, ReviewHistoryRecord>{};
  for (final r in history) {
    final current = latest[r.card.id];
    if (current == null || r.queueIndex >= current.queueIndex) {
      latest[r.card.id] = r;
    }
  }
  return {for (final e in latest.entries) e.key: e.value.ratingGiven};
}

/// Cards whose latest answer is not Again (mistakes practice completion).
int lastAnswerRightCount(Iterable<ReviewHistoryRecord> history) =>
    latestRatings(history).values.where((r) => r != SrsRating.again).length;

/// Cards whose latest answer is Again, i.e. still to be cleared.
int lastAnswerWrongCount(Iterable<ReviewHistoryRecord> history) =>
    latestRatings(history).values.where((r) => r == SrsRating.again).length;

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

/// Marks a practised card answered Again as a recent mistake, so it shows
/// in Recent Mistakes (for 48 hours, as after a review's Again), without
/// changing its schedule. Undo restores the card from its history record.
void markPracticeMistake(SrsCard card) {
  card.lastMistakeDate = DateTime.now();
  card.lastRating = SrsRating.again;
}

/// Changes the rating of an already-answered card.
/// Mutates the card, [queue], [againCardIds] and [record].
void reRateRecord({
  required ReviewHistoryRecord record,
  required SrsRating rating,
  required bool practiceOnly,
  bool clearsMistakes = true,
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
    // Practice never touches the schedule. Mistakes practice only clears or
    // restores the mistake; other practice marks or unmarks one on Again.
    if (clearsMistakes) {
      card.mistakesClearedAt = nowAgain
          ? record.oldMistakesClearedAt
          : DateTime.now();
    } else if (nowAgain) {
      markPracticeMistake(card);
    } else {
      card.lastMistakeDate = record.oldLastMistakeDate;
      card.lastRating = record.oldLastRating;
    }
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

/// A queue entry taken out of a study session, with the position it had.
typedef RemovedQueueItem = ({int index, StudyCardItem item});

/// A card moved to the end of the session queue without being rated.
class SendToBackRecord implements SessionUndoEntry {
  final StudyCardItem item;
  final int fromIndex;
  SendToBackRecord({required this.item, required this.fromIndex});
}

/// A card left out of the rest of the session unrated: [SuspendRecord] or
/// [ResetRecord]. Like a rated card, it keeps its place at [index], so
/// going back shows it; only its later copies ([removed]) leave the queue.
sealed class SkipRecord implements SessionUndoEntry {
  StudyCardItem get item;
  int get index;
  List<RemovedQueueItem> get removed;
  bool get wasInAgainSet;
}

/// A card suspended during the session, and the later copies it lost.
class SuspendRecord implements SkipRecord {
  @override
  final StudyCardItem item;
  @override
  final int index;
  @override
  final List<RemovedQueueItem> removed;
  @override
  final bool wasInAgainSet;
  SuspendRecord({
    required this.item,
    required this.index,
    required this.removed,
    required this.wasInAgainSet,
  });
}

/// A card reset to New during a review, which also leaves it out of the rest
/// of the session, like a suspend: the progress it had before the reset, and
/// the later copies it lost.
class ResetRecord implements SkipRecord {
  @override
  final StudyCardItem item;
  @override
  final int index;
  @override
  final List<RemovedQueueItem> removed;
  @override
  final bool wasInAgainSet;

  /// The card's state before the reset; [ReviewHistoryRecord.restore] puts
  /// it back. Its rating is unused.
  final ReviewHistoryRecord before;
  ResetRecord({
    required this.item,
    required this.index,
    required this.removed,
    required this.wasInAgainSet,
    required this.before,
  });
}

/// The session is wrapped up: the unseen cards it dropped, and the copies
/// of Again cards it added back. Turning wrap up off ([resumeWrappedUpQueue])
/// uses it to bring the dropped cards back.
class WrapUpRecord {
  final int fromIndex;
  final List<RemovedQueueItem> removed;
  final List<StudyCardItem> added;
  WrapUpRecord({
    required this.fromIndex,
    required this.removed,
    this.added = const [],
  });
}

/// Moves the unanswered card at [index] to the end of [queue], unrated.
/// Returns null when no other card is left after it, so there is nothing to
/// move it behind.
SendToBackRecord? sendCardToBack(List<StudyCardItem> queue, int index) {
  if (index < 0 || index >= queue.length - 1) return null;
  final item = queue.removeAt(index);
  queue.add(item);
  return SendToBackRecord(item: item, fromIndex: index);
}

/// Puts a card sent to the back where it was.
void undoSendCardToBack(List<StudyCardItem> queue, SendToBackRecord record) {
  queue.remove(record.item); // StudyCardItem has no ==, so identity
  queue.insert(min(record.fromIndex, queue.length), record.item);
}

/// Removes every entry from [fromIndex] on for which [test] is true, and
/// returns them in queue order with their positions.
List<RemovedQueueItem> _removeFrom(
  List<StudyCardItem> queue,
  int fromIndex,
  bool Function(StudyCardItem item) test,
) {
  final removed = <RemovedQueueItem>[];
  for (var i = queue.length - 1; i >= max(fromIndex, 0); i--) {
    if (test(queue[i])) removed.add((index: i, item: queue.removeAt(i)));
  }
  return removed.reversed.toList();
}

/// Puts back entries taken out by [removeCardFromSession] or [wrapUpQueue].
void restoreRemovedItems(
  List<StudyCardItem> queue,
  List<RemovedQueueItem> removed,
) {
  for (final r in removed) {
    queue.insert(min(r.index, queue.length), r.item);
  }
}

/// Takes [card] out of the session from [fromIndex] on: the entry on screen
/// and any re-queued Again copy. It no longer counts as a pending Again
/// card. Mutates [queue] and [againCardIds].
List<RemovedQueueItem> removeCardFromSession({
  required SrsCard card,
  required List<StudyCardItem> queue,
  required int fromIndex,
  required Set<String> againCardIds,
}) {
  againCardIds.remove(card.id);
  return _removeFrom(queue, fromIndex, (i) => i.card.id == card.id);
}

/// Leaves the card on screen at [index] in place, as an answered card is,
/// and takes its later copies out of the session ([removeCardFromSession]
/// from `index + 1`). Mutates [queue] and [againCardIds].
List<RemovedQueueItem> skipCardInPlace({
  required List<StudyCardItem> queue,
  required int index,
  required Set<String> againCardIds,
}) => removeCardFromSession(
  card: queue[index].card,
  queue: queue,
  fromIndex: index + 1,
  againCardIds: againCardIds,
);

/// How many unseen due reviews a wrapped-up session still shows.
const wrapUpReviewCount = 5;

/// Wraps up a session. From [fromIndex] (the first unanswered position) on,
/// it keeps the re-queued copies of cards rated Again this session, so the
/// mistakes can still be cleared, and the next [reviewCount] unseen reviews
/// (cards that are not new). It drops the other unseen cards, new cards
/// included. A card in [againCardIds] with no copy left ahead gets one at
/// the end from [makeDuplicate], when given. Mutates [queue].
List<RemovedQueueItem> wrapUpQueue({
  required List<StudyCardItem> queue,
  required int fromIndex,
  required Set<String> againCardIds,
  int reviewCount = wrapUpReviewCount,
  StudyCardItem Function(String cardId)? makeDuplicate,
}) {
  final from = max(fromIndex, 0);
  final keptReviews = <String>{};
  for (var i = from; i < queue.length; i++) {
    final card = queue[i].card;
    if (keptReviews.length >= reviewCount) break;
    if (againCardIds.contains(card.id) || card.status == SrsStatus.isNew) {
      continue;
    }
    keptReviews.add(card.id);
  }
  final removed = _removeFrom(
    queue,
    from,
    (i) =>
        !againCardIds.contains(i.card.id) && !keptReviews.contains(i.card.id),
  );
  if (makeDuplicate != null) {
    final ahead = {for (final i in queue.skip(from)) i.card.id};
    for (final id in againCardIds) {
      if (!ahead.contains(id)) queue.add(makeDuplicate(id));
    }
  }
  return removed;
}

/// Turns off the wrap up in [record]: takes out the Again copies it added
/// that are not answered yet, and brings back the cards it dropped, in their
/// order. Nothing goes before [answeredCount], so cards answered since the
/// wrap up keep their places; with nothing answered since, [queue] is back
/// as it was. Mutates [queue].
void resumeWrappedUpQueue(
  List<StudyCardItem> queue,
  WrapUpRecord record, {
  required int answeredCount,
}) {
  for (final item in record.added) {
    final at = queue.indexOf(item); // StudyCardItem has no ==, so identity
    if (at >= answeredCount) queue.removeAt(at);
  }
  var previous = -1;
  for (final r in record.removed) {
    final at = min(
      max(max(r.index, previous + 1), answeredCount),
      queue.length,
    );
    queue.insert(at, r.item);
    previous = at;
  }
}

/// Re-picks the sentence of every card in [queue] from [fromIndex] on that
/// shows [vocab], when its sentence was deselected from the vocab (or the vocab
/// had none and now has some). Earlier cards are left as they were answered.
/// Returns whether any card changed.
bool refreshStaleSentences({
  required AppProvider provider,
  required List<StudyCardItem> queue,
  required int fromIndex,
  required VocabItem vocab,
}) {
  var changed = false;
  for (var i = max(fromIndex, 0); i < queue.length; i++) {
    final item = queue[i];
    if (!identical(item.vocab, vocab)) continue;
    final before = item.sentence;
    final after = provider.refreshSentenceForVocab(vocab, before);
    if (!identical(before, after)) {
      item.sentence = after;
      changed = true;
    }
  }
  return changed;
}

/// The cram sessions offered when a session ends. Cramming every lesson
/// offers practice only and updating schedules. Cramming one lesson
/// ([lessonCram]) offers Learn New Words, while [canLearnNew] (the lesson
/// has new cards), and practice only.
List<CramMode> cramChoicesAfterSession({
  required bool lessonCram,
  bool canLearnNew = false,
}) => lessonCram
    ? [if (canLearnNew) CramMode.learnNew, CramMode.practice]
    : const [CramMode.practice, CramMode.reschedule];

String cramButtonLabel(CramMode mode) => switch (mode) {
  CramMode.practice => 'Cram (Practice Only)',
  CramMode.reschedule => 'Cram and Update Schedules',
  CramMode.learnNew => 'Learn New Words',
};

IconData cramModeIcon(CramMode mode) => switch (mode) {
  CramMode.practice => Icons.refresh,
  CramMode.reschedule => Icons.event_repeat,
  CramMode.learnNew => Icons.school_outlined,
};

String cramModeTitle(CramMode mode) => switch (mode) {
  CramMode.practice => 'Cram: practice only',
  CramMode.reschedule => 'Cram: updates schedules',
  CramMode.learnNew => 'Learn new words',
};

/// The chip on a card whose rating doesn't change its schedule: one only
/// practised ([practice]: practice-only cram, the seen cards of Learn New
/// Words, Recent Mistakes), or a repeat of a card already rated this
/// session, back after Again.
({String label, String tooltip}) unscheduledCardChip({
  required bool practice,
}) => practice
    ? (
        label: 'PRACTICE',
        tooltip:
            "Practice only: this answer doesn't change the card's "
            'schedule.',
      )
    : (
        label: 'REPEAT',
        tooltip:
            'Already rated in this session: this answer only decides '
            "whether it comes back again. It doesn't change the schedule.",
      );

/// [cards] in the order a preview goes through them: shuffled and spread
/// across parts of speech, as new cards are in a study session.
List<StudyCardItem> previewQueue(List<StudyCardItem> cards, Random rand) =>
    interleaveByGroup(cards, AppProvider.posKeyOf, rand);

/// The line under a card gone back to: its rating, or how it was left out of
/// the session ([skip]).
String pastCardStatus({SrsRating? rating, SkipRecord? skip}) => switch (skip) {
  SuspendRecord() => 'Suspended',
  ResetRecord() => 'Reset to New',
  null => rating == null ? '' : 'Currently ${rating.name.toUpperCase()}',
};

/// The queue position the card [entry] acted on: a rated card, or one
/// suspended or skipped. Null for send to back, which leaves no card behind.
int? undoEntryIndex(SessionUndoEntry entry) => switch (entry) {
  ReviewHistoryRecord() => entry.queueIndex,
  SkipRecord() => entry.index,
  SendToBackRecord() => null,
};

/// The chip on every card of a preview.
const previewCardChip = (
  label: 'PREVIEW',
  tooltip: "Preview only: the card stays new and isn't added to your reviews.",
);

/// How a cram session treats ratings.
enum CramMode {
  /// Ratings never change a card's schedule; new cards stay new. From one
  /// lesson, its new cards come first.
  practice,

  /// Every lesson's seen cards, rated as a normal review would, due or not.
  reschedule,

  /// A batch of one lesson's new cards, started and scheduled even past the
  /// daily new-card limit (they still count toward it), mixed with a few of
  /// its seen cards practised without changing their schedules.
  learnNew,
}

class StudyView extends StatefulWidget {
  final String? lessonId;

  /// Null for a normal review of due and new cards.
  final CramMode? cramMode;
  final bool recentMistakesOnly;

  /// Cards to preview instead of studying, shuffled ([previewQueue]) each
  /// time the preview starts. As in practice-only cram, ratings never change
  /// a schedule and new cards stay new, but Again still shows the card in
  /// Recent Mistakes.
  final List<StudyCardItem>? previewCards;

  /// What [previewCards] were picked by, such as a part of speech.
  final String? previewLabel;

  const StudyView({
    super.key,
    this.lessonId,
    this.cramMode,
    this.recentMistakesOnly = false,
    this.previewCards,
    this.previewLabel,
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
  // Every undoable action, ratings included, newest last.
  final List<SessionUndoEntry> _undoStack = [];
  final Set<String> _againCardIds = {};
  // The session's cram mode; a finished session can start a cram session.
  CramMode? _cramMode;
  // Learn New Words: the cards that were new when the session started, the
  // only ones its ratings schedule.
  final Set<String> _learnNewCardIds = {};
  // Wrapped up: no unseen cards are brought in any more.
  WrapUpRecord? _wrapUpRecord;
  bool get _wrappedUp => _wrapUpRecord != null;
  final Set<String> _sessionRatedCardIds = {};
  final FocusNode _keyboardFocusNode = FocusNode();
  // Held so dispose() can stop audio without a BuildContext lookup.
  late final AudioService _audio;

  // Keyboard hints are noise on touch platforms; the handlers still work for
  // attached keyboards.
  bool get _showKeyHints => switch (defaultTargetPlatform) {
    TargetPlatform.android ||
    TargetPlatform.iOS ||
    TargetPlatform.fuchsia => false,
    _ => true,
  };
  // Study review judges a card by its first pass (Again/Hard = wrong).
  // Mistakes practice judges it by its latest answer, so a mistake that is
  // answered correctly on retry counts as complete.
  int get rightCount => _isMistakesMode
      ? lastAnswerRightCount(_history)
      : firstPassRightCount(_history);
  int get wrongCount => _isMistakesMode
      ? lastAnswerWrongCount(_history)
      : firstPassWrongCount(_history);

  bool get _isReviewingPast => _currentIndex < _answeredCount;

  ReviewHistoryRecord? _recordAt(int index) {
    final i = _history.lastIndexWhere((r) => r.queueIndex == index);
    return i == -1 ? null : _history[i];
  }

  /// The suspend or reset to New that left the card at [index] behind.
  SkipRecord? _skipAt(int index) {
    for (final entry in _undoStack.reversed) {
      if (entry is SkipRecord && entry.index == index) return entry;
    }
    return null;
  }

  /// Whether Undo would take back what was done to the card on screen, gone
  /// back to: its rating, suspend or skip is the newest undoable action.
  bool get _canUndoCardOnScreen =>
      _isReviewingPast &&
      _undoStack.isNotEmpty &&
      undoEntryIndex(_undoStack.last) == _currentIndex;

  /// Whether the card on screen was suspended or skipped, not rated: going
  /// back shows it, but it has no rating to change.
  bool get _isOnSkippedCard =>
      _isReviewingPast && _skipAt(_currentIndex) != null;

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

  bool get _isMistakesMode => widget.recentMistakesOnly;

  bool get _isPreview => widget.previewCards != null;

  // Mistakes practice and practice-only cram never change a card's
  // schedule; Learn New Words changes only its new cards'.
  bool _isPracticeCard(SrsCard card) {
    if (_isMistakesMode || _isPreview) return true;
    return switch (_cramMode) {
      CramMode.practice => true,
      CramMode.learnNew => !_learnNewCardIds.contains(card.id),
      CramMode.reschedule || null => false,
    };
  }

  // Whether the card on screen is only practised.
  bool get _isPracticeOnly =>
      _currentIndex < _queue.length &&
      _isPracticeCard(_queue[_currentIndex].card);

  // Cards already rated this session (Again interleaving), and all cards in
  // practice, only offer Again/Good.
  bool get _isRepeatCard {
    if (_isPracticeOnly) return true;
    if (_currentIndex >= _queue.length) return false;
    if (_isReviewingPast) {
      final r = _recordAt(_currentIndex);
      return r != null && !r.wasFirstSessionRating;
    }
    return _sessionRatedCardIds.contains(_queue[_currentIndex].card.id);
  }

  // The very first review of a never-seen card has nothing to judge Hard or
  // Easy against, so it only offers Again/Good (still with their next-review
  // hints, unlike repeat cards).
  bool get _isFreshCard {
    if (_isPracticeOnly || _currentIndex >= _queue.length) return false;
    if (_isReviewingPast) {
      final r = _recordAt(_currentIndex);
      return r != null &&
          r.wasFirstSessionRating &&
          r.oldStatus == SrsStatus.isNew;
    }
    return _queue[_currentIndex].card.isNewCard;
  }

  bool get _offersOnlyAgainAndGood => _isRepeatCard || _isFreshCard;

  // The chip on a card whose rating doesn't change its schedule: practice,
  // or a repeat of a card already rated this session.
  ({String label, String tooltip})? get _unscheduledChip {
    if (_isPreview) return previewCardChip;
    if (!_isRepeatCard) return null;
    return unscheduledCardChip(practice: _isPracticeOnly);
  }

  @override
  void initState() {
    super.initState();
    _cramMode = widget.recentMistakesOnly || widget.previewCards != null
        ? null
        : widget.cramMode;
    _audio = context.read<AudioService>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadQueue();
    });
  }

  @override
  void dispose() {
    // Safety net for ways out of the review that do not go through
    // PopScope. Deferred: stop() notifies listeners, which must not happen
    // while the widget tree is being torn down.
    final audio = _audio;
    scheduleMicrotask(() => unawaited(audio.stop()));
    _keyboardFocusNode.dispose();
    super.dispose();
  }

  /// The language of the lesson [card] is studied from, which its reviews
  /// are counted under.
  String? _languageOf(SrsCard card) {
    for (final item in _queue) {
      if (item.card.id == card.id) return item.lesson.languageKey;
    }
    return null;
  }

  void _loadQueue() {
    final provider = context.read<AppProvider>();
    final cramMode = _cramMode;
    final preview = widget.previewCards;
    final queue = preview != null
        ? previewQueue(preview, Random())
        : cramMode != null
        ? _cramQueue(provider, cramMode)
        : provider.getStudyQueue(
            lessonId: widget.lessonId,
            dueOnly: !widget.recentMistakesOnly,
            mistakesOnly: widget.recentMistakesOnly,
          );
    setState(() => _startSession(queue));

    _triggerPreload(0);
  }

  /// Starts a cram session in [mode] over the same lesson, or all lessons.
  void _startCram(CramMode mode) {
    final queue = _cramQueue(context.read<AppProvider>(), mode);
    setState(() {
      _cramMode = mode;
      _startSession(queue);
    });
    _triggerPreload(0);
  }

  List<StudyCardItem> _cramQueue(AppProvider provider, CramMode mode) {
    final lessonId = widget.lessonId;
    if (mode == CramMode.learnNew && lessonId != null) {
      return provider.getLearnNewQueue(lessonId);
    }
    return provider.getCramQueue(lessonId: lessonId);
  }

  /// Starts a fresh session over [queue]. Call inside setState.
  void _startSession(List<StudyCardItem> queue) {
    _queue = queue;
    _currentIndex = 0;
    _answeredCount = 0;
    _isAnswerRevealed = false;
    _history.clear();
    _undoStack.clear();
    _againCardIds.clear();
    _sessionRatedCardIds.clear();
    _wrapUpRecord = null;
    _learnNewCardIds.clear();
    if (_cramMode == CramMode.learnNew) {
      _learnNewCardIds.addAll([
        for (final item in queue)
          if (item.card.isNewCard) item.card.id,
      ]);
    }
  }

  /// Pre-buffers audio in background for the next few cards
  void _triggerPreload(int startIndex) {
    if (_queue.isEmpty) return;
    final audioService = context.read<AudioService>();
    final List<String?> urlsToPreload = [];

    for (int i = startIndex; i < startIndex + 3 && i < _queue.length; i++) {
      final item = _queue[i];
      if (item.vocab.playableAudioUrl != null) {
        urlsToPreload.add(item.vocab.playableAudioUrl);
      } else if (!audioService.usesOfflineTts) {
        urlsToPreload.add(
          audioService.getTtsUrl(
            item.vocab.speechText,
            language: item.lesson.targetLanguage,
          ),
        );
      }
      if (item.sentence?.playableAudioUrl != null) {
        urlsToPreload.add(item.sentence!.playableAudioUrl);
      } else if (item.sentence != null && !audioService.usesOfflineTts) {
        urlsToPreload.add(
          audioService.getTtsUrl(
            item.sentence!.speechText,
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
        vocabAudio: item.vocab.playableAudioUrl,
        vocabText: item.vocab.speechText,
        sentenceAudio: item.sentence?.playableAudioUrl,
        sentenceText: item.sentence?.speechText,
        targetLanguage: item.lesson.targetLanguage,
      );
    }
  }

  void _submitAnswerWorkspace() {
    FocusManager.instance.primaryFocus?.unfocus();
    if (_isAnswerRevealed) {
      _rateCard(SrsRating.good);
    } else {
      _revealAnswer();
    }
  }

  void _rateCard(SrsRating rating) {
    if (_currentIndex >= _queue.length) return;
    if (_isReviewingPast) {
      _reRatePast(rating);
      return;
    }
    if (_offersOnlyAgainAndGood &&
        (rating == SrsRating.hard || rating == SrsRating.easy)) {
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
      if (_isMistakesMode) {
        // Already a recent mistake; mistakes practice never touches SRS.
      } else if (_isPracticeCard(card)) {
        // Practice leaves the schedule alone but still records the mistake.
        markPracticeMistake(card);
        provider.saveState();
      } else if (isFirstSessionRating) {
        final countedAt = record.countedAt = DateTime.now();
        provider.recordCardReview(
          card,
          SrsRating.again,
          at: countedAt,
          language: _languageOf(card),
        );
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
      if (_isMistakesMode) {
        // Good in mistakes practice dismisses the mistake without touching SRS.
        card.mistakesClearedAt = DateTime.now();
        provider.saveState();
      } else if (_isPracticeCard(card)) {
        // Practice-only cram never touches the card.
      } else if (isFirstSessionRating) {
        final countedAt = record.countedAt = DateTime.now();
        provider.recordCardReview(
          card,
          rating,
          at: countedAt,
          language: _languageOf(card),
        );
      }
    }

    record.requeuedItem = requeuedItem;

    // Save snapshot in history for Undo (values captured before the review)
    _history.add(record);
    _undoStack.add(record);

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
    if (record == null) {
      // A suspended or skipped card: rating keys just move on, as
      // repeating the same rating does.
      if (_isOnSkippedCard) _navigateForward();
      return;
    }
    if (record.ratingGiven == rating) {
      _navigateForward();
      return;
    }
    if (_offersOnlyAgainAndGood &&
        (rating == SrsRating.hard || rating == SrsRating.easy)) {
      return;
    }
    context.read<AudioService>().stop();
    final provider = context.read<AppProvider>();
    final previousRating = record.ratingGiven;
    reRateRecord(
      record: record,
      rating: rating,
      practiceOnly: _isPracticeCard(record.card),
      clearsMistakes: _isMistakesMode,
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
    // Still one review, now under the new rating.
    final countedAt = record.countedAt;
    if (countedAt != null) {
      provider.recountCardReview(
        countedAt,
        previousRating,
        rating,
        language: _languageOf(record.card),
      );
    }
    provider.saveState();
    _navigateForward();
  }

  void _undo() {
    if (_undoStack.isEmpty) return;
    context.read<AudioService>().stop();
    switch (_undoStack.removeLast()) {
      case final ReviewHistoryRecord record:
        _undoRating(record);
      case final SendToBackRecord record:
        _undoSendToBack(record);
      case final SuspendRecord record:
        _undoSuspend(record);
      case final ResetRecord record:
        _undoReset(record);
    }
  }

  /// Leaves the unanswered card on screen behind in place, as rating it
  /// would, and moves on to the next card. Returns what Undo needs to put
  /// back. Call inside setState.
  ({int index, List<RemovedQueueItem> removed, bool wasInAgainSet})
  _skipCurrentCard() {
    final index = _currentIndex;
    final wasInAgainSet = _againCardIds.contains(_queue[index].card.id);
    final removed = skipCardInPlace(
      queue: _queue,
      index: index,
      againCardIds: _againCardIds,
    );
    if (_currentIndex == _answeredCount) _answeredCount++;
    _currentIndex++;
    _isAnswerRevealed = false;
    return (index: index, removed: removed, wasInAgainSet: wasInAgainSet);
  }

  /// Takes back [_skipCurrentCard]: the card's later copies come back and it
  /// is on screen again, unanswered. Call inside setState.
  void _unskip(SkipRecord record) {
    restoreRemovedItems(_queue, record.removed);
    if (record.wasInAgainSet) _againCardIds.add(record.item.card.id);
    _currentIndex = min(record.index, _queue.length);
    _answeredCount = min(_answeredCount, _currentIndex);
    _isAnswerRevealed = false;
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(milliseconds: 1400),
      ),
    );
  }

  void _undoRating(ReviewHistoryRecord record) {
    final provider = context.read<AppProvider>();
    _history.remove(record);

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
    // And take back the review it counted, or rating the card again would
    // count it twice.
    final countedAt = record.countedAt;
    if (countedAt != null) {
      provider.undoCardReview(
        countedAt,
        record.ratingGiven,
        startedNewCard: record.oldStatus == SrsStatus.isNew,
        language: _languageOf(record.card),
      );
    }

    setState(() {
      _currentIndex = record.queueIndex;
      if (_answeredCount > _currentIndex) {
        _answeredCount = _currentIndex;
      }
      _isAnswerRevealed = true; // Show back of undone card ready to re-rate
    });

    _showSnack(
      'Undid rating (${record.ratingGiven.name.toUpperCase()}) for '
      '${_queue[_currentIndex].vocab.targetWord}',
    );
  }

  // Send to back, suspend and wrap up act on the card being answered, never
  // on one navigated back to: that card has history (undo, re-rate) tied to
  // its queue position.
  bool get _isOnUnansweredCard =>
      _currentIndex < _queue.length && !_isReviewingPast;

  bool get _canSendCurrentCardToBack =>
      _isOnUnansweredCard && _currentIndex < _queue.length - 1;

  void _sendCurrentCardToBack() {
    if (!_canSendCurrentCardToBack) return;
    context.read<AudioService>().stop();
    final record = sendCardToBack(_queue, _currentIndex);
    if (record == null) return;
    _undoStack.add(record);
    setState(() => _isAnswerRevealed = false);
    _triggerPreload(_currentIndex);
    _showSnack('Sent "${record.item.vocab.targetWord}" to the back.');
  }

  void _undoSendToBack(SendToBackRecord record) {
    setState(() {
      undoSendCardToBack(_queue, record);
      _currentIndex = record.fromIndex;
      _answeredCount = min(_answeredCount, _currentIndex);
      _isAnswerRevealed = false;
    });
    _showSnack('Put "${record.item.vocab.targetWord}" back where it was.');
  }

  String _directionLabel(StudyCardItem item) {
    final target = item.lesson.targetLanguage.toUpperCase();
    final native = item.lesson.nativeLanguage.toUpperCase();
    return item.isTargetToNative ? '$target ➔ $native' : '$native ➔ $target';
  }

  Future<void> _confirmSuspendCurrentCard() async {
    if (!_isOnUnansweredCard) return;
    final item = _queue[_currentIndex];
    final direction = _directionLabel(item);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Suspend this card for "${item.vocab.targetWord}"?'),
        content: Text(
          'The $direction card is left out of reviews, with its progress '
          'kept, until you unsuspend it from its chip in the lesson\'s '
          'vocabulary list. The other direction is not affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Suspend'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    // The card may have moved on while the dialog was open.
    if (!_isOnUnansweredCard || _queue[_currentIndex] != item) return;

    context.read<AudioService>().stop();
    final provider = context.read<AppProvider>();
    final saved = provider.setCardSuspended(item.card, true);
    setState(() {
      final skipped = _skipCurrentCard();
      _undoStack.add(
        SuspendRecord(
          item: item,
          index: skipped.index,
          removed: skipped.removed,
          wasInAgainSet: skipped.wasInAgainSet,
        ),
      );
    });
    _triggerPreload(_currentIndex);
    await saved;
    if (!mounted) return;
    _showSnack('Suspended "${item.vocab.targetWord}" ($direction).');
  }

  void _undoSuspend(SuspendRecord record) {
    context.read<AppProvider>().setCardSuspended(record.item.card, false);
    setState(() => _unskip(record));
    _showSnack('Unsuspended "${record.item.vocab.targetWord}".');
  }

  void _wrapUp() {
    if (_wrappedUp || _queue.isEmpty) return;
    context.read<AudioService>().stop();
    final provider = context.read<AppProvider>();
    final from = _answeredCount;
    final onScreen = _currentIndex < _queue.length
        ? _queue[_currentIndex]
        : null;
    setState(() {
      final lengthBefore = _queue.length;
      final removed = wrapUpQueue(
        queue: _queue,
        fromIndex: from,
        againCardIds: _againCardIds,
        makeDuplicate: (cardId) {
          final source = _queue.lastWhere((i) => i.card.id == cardId);
          return StudyCardItem(
            vocab: source.vocab,
            card: source.card,
            lesson: source.lesson,
            sentence: provider.getRandomSentenceForVocab(source.vocab),
          );
        },
      );
      final added = _queue.sublist(lengthBefore - removed.length);
      _wrapUpRecord = WrapUpRecord(
        fromIndex: from,
        removed: removed,
        added: added,
      );
      if (_currentIndex >= _queue.length || _queue[_currentIndex] != onScreen) {
        _isAnswerRevealed = false;
      }
    });
    _triggerPreload(_currentIndex);
    final mistakes = _againCardIds.length;
    final reviews = distinctCardCount(_queue.sublist(from)) - mistakes;
    final parts = [
      if (mistakes > 0) '$mistakes ${mistakes == 1 ? 'mistake' : 'mistakes'}',
      if (reviews > 0) '$reviews ${reviews == 1 ? 'review' : 'reviews'}',
    ];
    if (parts.isNotEmpty) {
      _showSnack('Wrapping up: ${parts.join(' and ')} left.');
    }
  }

  /// Wrap up is a toggle: on, it drops unseen cards; off, they come back.
  void _toggleWrapUp() => _wrappedUp ? _resumeSession() : _wrapUp();

  void _resumeSession() {
    final record = _wrapUpRecord;
    if (record == null) return;
    context.read<AudioService>().stop();
    final onScreen = _currentIndex < _queue.length
        ? _queue[_currentIndex]
        : null;
    setState(() {
      resumeWrappedUpQueue(_queue, record, answeredCount: _answeredCount);
      _wrapUpRecord = null;
      if (_currentIndex >= _queue.length || _queue[_currentIndex] != onScreen) {
        _isAnswerRevealed = false;
      }
    });
    _triggerPreload(_currentIndex);
    final back = distinctCardCount([for (final r in record.removed) r.item]);
    _showSnack(
      back == 0
          ? 'Wrap up cancelled.'
          : 'Wrap up cancelled: $back ${back == 1 ? 'card' : 'cards'} back.',
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
    // Typing a review note must not trigger flip/rate/audio shortcuts.
    if (isEditingText()) return;

    if (HardwareKeyboard.instance.isControlPressed &&
        (event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.numpadEnter)) {
      if (_isAnswerRevealed) {
        _rateCard(SrsRating.good);
      } else {
        _revealAnswer();
      }
      return;
    }

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

    // Send to back (B), suspend (P, asks first) and wrap up (W)
    if (event.logicalKey == LogicalKeyboardKey.keyB) {
      _sendCurrentCardToBack();
    } else if (event.logicalKey == LogicalKeyboardKey.keyP) {
      _confirmSuspendCurrentCard();
    } else if (event.logicalKey == LogicalKeyboardKey.keyW) {
      _toggleWrapUp();
    }

    // Audio replay shortcuts
    if (event.logicalKey == LogicalKeyboardKey.keyR &&
        _currentIndex < _queue.length) {
      final item = _queue[_currentIndex];
      final audioService = context.read<AudioService>();
      final vocabAudio = item.vocab.playableAudioUrl;
      if (vocabAudio != null) {
        audioService.playAudio(vocabAudio);
      } else {
        audioService.speak(
          item.vocab.speechText,
          language: item.lesson.targetLanguage,
        );
      }
    } else if (event.logicalKey == LogicalKeyboardKey.keyS &&
        _currentIndex < _queue.length) {
      final item = _queue[_currentIndex];
      if (item.sentence != null) {
        final audioService = context.read<AudioService>();
        final sentenceAudio = item.sentence!.playableAudioUrl;
        if (sentenceAudio != null) {
          audioService.playAudio(sentenceAudio);
        } else {
          audioService.speak(
            item.sentence!.speechText,
            language: item.lesson.targetLanguage,
          );
        }
      }
    } else if (event.logicalKey == LogicalKeyboardKey.keyE &&
        _currentIndex < _queue.length &&
        _isAnswerRevealed) {
      _openEditCurrentCard();
    }
  }

  void _openEditCurrentCard() {
    if (_currentIndex >= _queue.length) return;
    final item = _queue[_currentIndex];
    VocabEditDialog.show(context, item.vocab, lessonId: item.lesson.id).then((
      _,
    ) {
      if (!mounted) return;
      // The edit may have deselected the sentence on screen.
      final changed = refreshStaleSentences(
        provider: context.read<AppProvider>(),
        queue: _queue,
        fromIndex: _currentIndex,
        vocab: item.vocab,
      );
      setState(() {});
      if (changed) _triggerPreload(_currentIndex);
    });
  }

  // Only the card being answered can be reset: a card already rated this
  // position has history (undo, re-rate) that a reset would leave stale. A
  // card that is still New has nothing to reset.
  bool get _canResetCurrentCard =>
      _isAnswerRevealed &&
      _currentIndex < _queue.length &&
      !_isReviewingPast &&
      _queue[_currentIndex].card.status != SrsStatus.isNew;

  Future<void> _confirmResetCurrentCard() async {
    if (!_canResetCurrentCard) return;
    final item = _queue[_currentIndex];
    final direction = _directionLabel(item);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Reset this card for "${item.vocab.targetWord}"?'),
        content: Text(
          'This resets the $direction card\'s repetitions, interval, and '
          'review dates back to New, and leaves it out of the rest of this '
          'session, like a suspend. The other direction is not affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Reset to New'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    // The card may have moved on while the dialog was open.
    if (_currentIndex >= _queue.length || _queue[_currentIndex] != item) return;
    await _resetCurrentCard(item, direction);
  }

  /// Resets the card on screen to New and leaves it out of the rest of the
  /// session unrated, like a suspend: it keeps its place, as a rated card
  /// does, and the next card comes up. Undo restores its progress and puts
  /// it back on screen.
  Future<void> _resetCurrentCard(StudyCardItem item, String direction) async {
    context.read<AudioService>().stop();
    final provider = context.read<AppProvider>();
    final index = _currentIndex;
    final before = ReviewHistoryRecord.capture(
      queueIndex: index,
      card: item.card,
      rating: SrsRating.again,
    );
    final saved = provider.resetCardSrs(item.card);
    setState(() {
      final skipped = _skipCurrentCard();
      _undoStack.add(
        ResetRecord(
          item: item,
          index: skipped.index,
          removed: skipped.removed,
          wasInAgainSet: skipped.wasInAgainSet,
          before: before,
        ),
      );
    });
    _triggerPreload(_currentIndex);
    await saved;
    if (!mounted) return;
    _showSnack('Reset "${item.vocab.targetWord}" ($direction) to New.');
  }

  void _undoReset(ResetRecord record) {
    record.before.restore();
    context.read<AppProvider>().saveState();
    setState(() => _unskip(record));
    _showSnack('Undid reset of "${record.item.vocab.targetWord}".');
  }

  void _openAiDiscussion(StudyCardItem item) {
    final sentence = item.sentence;
    showDialog<void>(
      context: context,
      builder: (_) => AiDiscussionDialog(
        discussionId: AiDiscussionIds.forVocab(item.vocab.id),
        targetWord: item.vocab.targetWord,
        translation: item.vocab.translation,
        targetLanguage: item.lesson.targetLanguage,
        nativeLanguage: item.lesson.nativeLanguage,
        categories: item.vocab.categoryLabels,
        sentenceTarget: sentence == null
            ? null
            : item.vocab.targetTextFor(sentence),
        sentenceTranslation: sentence == null
            ? null
            : item.vocab.translationTextFor(sentence),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Stop audio the moment the review is left, not when the exit animation
    // ends and dispose() runs. This is tied to the route being popped, never
    // to layout, so rotating the device does not cut audio off.
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) unawaited(_audio.stop());
      },
      child: _buildScreen(context),
    );
  }

  Widget _buildScreen(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.watch<AppProvider>();

    if (_queue.isEmpty || _currentIndex >= _queue.length) {
      final isMistakesMode = widget.recentMistakesOnly;
      // A preview postpones nothing: its cards are still new.
      final hasPostponedCard = !_isPreview && _againCardIds.length == 1;

      return Scaffold(
        appBar: AppBar(
          title: Text(
            isMistakesMode
                ? 'Recent Mistakes Complete'
                : _isPreview
                ? 'Preview Complete'
                : 'Study Complete',
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
                    : (_queue.isEmpty && !_wrappedUp
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
                  if (_undoStack.isNotEmpty) ...[
                    FilledButton.tonalIcon(
                      icon: const Icon(Icons.undo),
                      label: Text(
                        _showKeyHints ? 'Undo Last Card (Z)' : 'Undo Last Card',
                      ),
                      onPressed: _undo,
                    ),
                    const SizedBox(width: 16),
                  ],
                  if (_wrapUpRecord?.removed.isNotEmpty ?? false) ...[
                    FilledButton.tonalIcon(
                      icon: const Icon(Icons.redo),
                      label: Text(
                        _showKeyHints ? 'Cancel Wrap Up (W)' : 'Cancel Wrap Up',
                      ),
                      onPressed: _resumeSession,
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
                        setState(() => _startSession(retryQueue));
                      },
                    ),
                  ] else if (_isPreview) ...[
                    FilledButton.icon(
                      icon: const Icon(Icons.preview_outlined),
                      label: const Text('Preview Again'),
                      onPressed: () => setState(
                        () => _startSession(
                          previewQueue(widget.previewCards!, Random()),
                        ),
                      ),
                    ),
                  ] else if (isMistakesMode) ...[
                    FilledButton.icon(
                      icon: const Icon(Icons.refresh),
                      label: const Text('Review Mistakes Again'),
                      onPressed: () {
                        final reloadQueue = provider.getStudyQueue(
                          lessonId: widget.lessonId,
                          dueOnly: false,
                          mistakesOnly: true,
                        );
                        setState(() => _startSession(reloadQueue));
                      },
                    ),
                  ] else
                    for (final (index, mode) in cramChoicesAfterSession(
                      lessonCram: widget.lessonId != null,
                      canLearnNew:
                          widget.lessonId != null &&
                          provider.learnableNewCardCount(widget.lessonId!) > 0,
                    ).indexed) ...[
                      if (index > 0) const SizedBox(width: 16),
                      FilledButton.icon(
                        icon: Icon(cramModeIcon(mode)),
                        label: Text(cramButtonLabel(mode)),
                        onPressed: () => _startCram(mode),
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
    final canUndo = _undoStack.isNotEmpty;

    const overflowWidthCutoff = 700;
    final isNarrow = MediaQuery.sizeOf(context).width < overflowWidthCutoff;

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
                    // Same progress text in Study and Mistakes review. Wide
                    // screens add a small line above (mistakes label or unit
                    // title); narrow screens have no room for it.
                    if (!isNarrow && widget.recentMistakesOnly)
                      Text(
                        'Recent Mistakes Review',
                        style: Theme.of(context).textTheme.labelSmall,
                      )
                    else if (!isNarrow && _isPreview)
                      Text(
                        widget.previewLabel == null
                            ? 'Preview: not added to reviews'
                            : 'Preview · ${widget.previewLabel}: '
                                  'not added to reviews',
                        style: Theme.of(context).textTheme.labelSmall,
                      )
                    else if (!isNarrow && _cramMode != null)
                      Text(
                        cramModeTitle(_cramMode!),
                        style: Theme.of(context).textTheme.labelSmall,
                      )
                    else if (!isNarrow &&
                        item.lesson.effectiveUnitTitle != null)
                      Text(
                        item.lesson.effectiveUnitTitle!,
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    if (isNarrow)
                      Text(
                        '$currentNumber / $total',
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.fade,
                      )
                    else
                      Text(
                        '${item.lesson.displayTitle} ($currentNumber/$total)',
                      ),
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
            if (MediaQuery.sizeOf(context).width >= overflowWidthCutoff) ...[
              IconButton(
                icon: const Icon(Icons.undo),
                tooltip: canUndo
                    ? (_showKeyHints ? 'Undo (Z / Ctrl+Z)' : 'Undo')
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
              IconButton(
                icon: const Icon(Icons.edit_outlined),
                tooltip: _showKeyHints ? 'Edit card (E)' : 'Edit card',
                onPressed: _isAnswerRevealed ? _openEditCurrentCard : null,
              ),
            ],
            PopupMenuButton<String>(
              tooltip: 'More',
              onSelected: (value) {
                switch (value) {
                  case 'undo':
                    _undo();
                  case 'autoplay':
                    provider.toggleAutoplay();
                  case 'edit':
                    _openEditCurrentCard();
                  case 'ai':
                    _openAiDiscussion(item);
                  case 'reset':
                    _confirmResetCurrentCard();
                  case 'back':
                    _sendCurrentCardToBack();
                  case 'suspend':
                    _confirmSuspendCurrentCard();
                  case 'wrapup':
                    _toggleWrapUp();
                }
              },
              itemBuilder: (context) => [
                if (MediaQuery.sizeOf(context).width < overflowWidthCutoff) ...[
                  moreItem(
                    'undo',
                    Icons.undo,
                    _showKeyHints ? 'Undo (Z / Ctrl+Z)' : 'Undo',
                    enabled: canUndo,
                  ),
                  // The icon shows the current state; the title says what
                  // tapping does.
                  moreItem(
                    'autoplay',
                    provider.autoplayAudio ? Icons.volume_up : Icons.volume_off,
                    provider.autoplayAudio
                        ? 'Turn autoplay off'
                        : 'Turn autoplay on',
                  ),
                  moreItem(
                    'edit',
                    Icons.edit_outlined,
                    _showKeyHints ? 'Edit card (E)' : 'Edit card',
                    enabled: _isAnswerRevealed,
                  ),
                ],
                if (provider.showAi)
                  moreItem(
                    'ai',
                    Icons.forum_outlined,
                    'Ask AI',
                    enabled: _isAnswerRevealed,
                  ),
                const PopupMenuDivider(),
                moreItem(
                  'back',
                  Icons.low_priority,
                  _showKeyHints ? 'Send to back (B)' : 'Send to back',
                  enabled: _canSendCurrentCardToBack,
                ),
                moreItem(
                  'suspend',
                  Icons.pause_circle_outline,
                  _showKeyHints ? 'Suspend (P)' : 'Suspend',
                  enabled: _isOnUnansweredCard,
                ),
                moreItem(
                  'reset',
                  Icons.restart_alt,
                  'Reset to New',
                  enabled: _canResetCurrentCard,
                ),
                // Unlike autoplay, the icon shows the action, like the
                // other items: finish up, or carry on with the full session.
                moreItem(
                  'wrapup',
                  _wrappedUp ? Icons.redo : Icons.sports_score,
                  switch ((_wrappedUp, _showKeyHints)) {
                    (true, true) => 'Cancel wrap up (W)',
                    (true, false) => 'Cancel wrap up',
                    (false, true) => 'Wrap up session (W)',
                    (false, false) => 'Wrap up session',
                  },
                ),
                if (item.lesson.targetLanguageCode == 'ko') ...[
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
                                    // Same colour as the New badge in the
                                    // lesson list; explains the two buttons.
                                    if (_unscheduledChip case (
                                      :final label,
                                      :final tooltip,
                                    ))
                                      Tooltip(
                                        message: tooltip,
                                        child: Chip(
                                          visualDensity: VisualDensity.compact,
                                          side: BorderSide.none,
                                          avatar: Icon(
                                            Icons.event_busy_outlined,
                                            size: 16,
                                            color: theme
                                                .colorScheme
                                                .onSecondaryContainer,
                                          ),
                                          label: Text(label),
                                          backgroundColor: theme
                                              .colorScheme
                                              .secondaryContainer,
                                          labelStyle: TextStyle(
                                            color: theme
                                                .colorScheme
                                                .onSecondaryContainer,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                    if (_isFreshCard)
                                      Chip(
                                        visualDensity: VisualDensity.compact,
                                        side: BorderSide.none,
                                        label: const Text('NEW'),
                                        backgroundColor:
                                            theme.colorScheme.tertiary,
                                        labelStyle: TextStyle(
                                          color: theme.colorScheme.onTertiary,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
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
                                            EmphasisText(
                                              item.vocab.targetTextFor(
                                                item.sentence!,
                                              ),
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
                                            EmphasisText(
                                              item.vocab.clozeFor(
                                                item.sentence!,
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

                                  const SizedBox(height: 12),
                                  AnswerWorkspace(
                                    key: ValueKey(
                                      'answer-$_currentIndex-${item.card.id}',
                                    ),
                                    onSubmit: _submitAnswerWorkspace,
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
                                              child: CharacterZoom.tappable(
                                                context: context,
                                                vocab: item.vocab,
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
                                            ),
                                            AudioButton(
                                              audioUrl:
                                                  item.vocab.playableAudioUrl,
                                              fallbackText:
                                                  item.vocab.speechText,
                                              language:
                                                  item.lesson.targetLanguage,
                                              compact: true,
                                            ),
                                          ],
                                        ),
                                        VocabForms(vocab: item.vocab),
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
                                                child: EmphasisText(
                                                  item.vocab.targetTextFor(
                                                    item.sentence!,
                                                  ),
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
                                                audioUrl: item
                                                    .sentence!
                                                    .playableAudioUrl,
                                                fallbackText:
                                                    item.sentence!.speechText,
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
                                            child: EmphasisText(
                                              item.vocab.translationTextFor(
                                                item.sentence!,
                                              ),
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
                                  AnswerWorkspace(
                                    key: ValueKey(
                                      'answer-$_currentIndex-${item.card.id}',
                                    ),
                                    onSubmit: _submitAnswerWorkspace,
                                  ),

                                  ReviewNotesEditor(
                                    key: ValueKey(
                                      'review-notes-$_currentIndex-${item.card.id}',
                                    ),
                                    card: item.card,
                                    onSave: (text) {
                                      item.card.backNotes = text;
                                      context.read<AppProvider>().saveState();
                                      setState(() {});
                                    },
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
                                if (!_isAnswerRevealed) ...[
                                  const SizedBox(height: 16),
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

              // What was done to a card gone back to, and an Undo button
              // when that is the newest action, so Undo takes back this card.
              if (_isReviewingPast)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Wrap(
                    alignment: WrapAlignment.center,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 12,
                    runSpacing: 4,
                    children: [
                      Text(
                        pastCardStatus(
                          rating: _recordAt(_currentIndex)?.ratingGiven,
                          skip: _skipAt(_currentIndex),
                        ),
                        style: theme.textTheme.labelLarge,
                      ),
                      if (_canUndoCardOnScreen)
                        FilledButton.tonalIcon(
                          onPressed: _undo,
                          icon: const Icon(Icons.undo),
                          label: Text(_showKeyHints ? 'Undo (Z)' : 'Undo'),
                        ),
                    ],
                  ),
                ),

              // Bottom SRS Rating Bar (Accessible when answer revealed). A
              // suspended or skipped card has no rating to change.
              if (_isAnswerRevealed && !_isOnSkippedCard)
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
                              if (!_offersOnlyAgainAndGood) ...[
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
                              if (!_offersOnlyAgainAndGood) ...[
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
                                  _offersOnlyAgainAndGood
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
