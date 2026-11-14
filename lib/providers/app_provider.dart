import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../models/ai_discussion_message.dart';
import '../models/lesson.dart';
import '../models/sentence.dart';
import '../models/shared_vocab.dart';
import '../models/srs_card.dart';
import '../models/typed_question.dart';
import '../models/vocab_item.dart';
import '../models/vocab_merge_record.dart';
import '../services/ai_discussion_search.dart';
import '../services/deepseek_service.dart';
import '../services/hangul_text.dart';
import '../services/language_activity.dart';
import '../services/lesson_ai_prompt.dart';
import '../services/lesson_file_update.dart';
import '../services/lesson_word_match.dart';
import '../services/new_card_quota.dart';
import '../services/srs_service.dart';
import '../services/storage_service.dart';
import '../services/study_queue_order.dart';
import '../services/sync_account_service.dart';
import '../services/sync_apply.dart';
import '../services/sync_client.dart';
import '../services/sync_engine.dart';
import '../services/sync_error_text.dart';
import '../services/sync_pairing.dart';
import '../services/sync_record_cipher.dart';
import '../services/sync_records.dart';
import '../services/typed_questions.dart';
import '../services/vocab_ai_service.dart';
import '../services/yaml_parser_service.dart';

class StudyCardItem {
  final VocabItem vocab;
  final SrsCard card;
  final Lesson lesson;
  final Sentence? Function()? _sentenceResolver;
  Sentence? _sentence;
  bool _sentenceResolved;

  StudyCardItem({
    required this.vocab,
    required this.card,
    required this.lesson,
    Sentence? sentence,
    Sentence? Function()? sentenceResolver,
  }) : _sentence = sentence, // ignore: prefer_initializing_formals
       _sentenceResolver = sentenceResolver,
       _sentenceResolved = sentenceResolver == null;

  /// Resolved lazily so building a large queue doesn't scan sentences per card.
  Sentence? get sentence {
    if (!_sentenceResolved) {
      _sentence = _sentenceResolver!();
      _sentenceResolved = true;
    }
    return _sentence;
  }

  set sentence(Sentence? value) {
    _sentence = value;
    _sentenceResolved = true;
  }

  bool get isTargetToNative => card.direction == CardDirection.targetToNative;
}

/// Where a pronunciation line can be shown. Each target has its own
/// romanization and IPA switches (sentences are usually left off).
enum PronunciationTarget {
  vocabulary('Vocabulary'),
  sentence('Sentence');

  const PronunciationTarget(this.label);
  final String label;
}

class AppProvider extends ChangeNotifier implements SyncRecordStore {
  List<Lesson> _lessons = [];
  List<Sentence> _sentences = [];
  bool _autoplayAudio = true;

  /// Whether AI features are shown. A device-only preference, not synced.
  bool _showAi = true;

  /// The language picked to be shown, as a [Lesson.languageKey]. See
  /// [activeLanguage] for the one in effect.
  String? _pickedLanguage;

  /// Enabled options as `<target>_romanization` / `<target>_ipa`.
  Set<String> _pronunciationOptions = {};
  String _deepSeekApiKey = '';
  SyncPairing? _syncPairing;
  bool _deepSeekKeyRejected = false;
  List<VocabMergeRecord> _mergeHistory = [];
  static const int _maxMergeHistory = 20;
  static const int _maxItemsPerRequest = 150;
  Map<String, List<AiDiscussionMessage>> _aiDiscussions = {};

  /// Questions typed in AI chats, by id, to offer again. See
  /// [TypedQuestions].
  Map<String, TypedQuestion> _typedQuestions = {};
  bool _isLoading = true;
  String? _selectedLessonId;
  Map<String, int> _lessonHierarchyOrder = {};
  Map<String, bool> _lessonFolderExpansion = {};

  /// Test hook: HTTP client used by the AI helpers when none is passed in.
  @visibleForTesting
  http.Client? aiClient;

  int _maxReviews24h = StorageService.defaultMaxReviews24h;
  int _maxNewCards24h = StorageService.defaultMaxNewCards24h;
  List<DateTime> _reviewTimestamps24h = [];
  Map<DateTime, int> _dailyReviewCounts = {};

  /// This device's reviews per day and rating. Only reviews made since
  /// ratings were counted are here, so a day's total in [_dailyReviewCounts]
  /// can be larger than the sum of its ratings.
  Map<DateTime, Map<SrsRating, int>> _dailyRatingCounts = {};

  /// This device's new cards started per day: reviews of a card that was
  /// still new. They are also in [_dailyReviewCounts].
  Map<DateTime, int> _dailyNewCardCounts = {};

  /// Other devices' activity records, pulled by sync. This device's own
  /// counts stay in [_dailyReviewCounts] and [_reviewTimestamps24h].
  Map<String, Map<String, dynamic>> _remoteActivity = {};

  /// This device's reviews by language, next to the totals above. Only
  /// reviews made since languages were recorded are in it.
  LanguageActivity _languageActivity = LanguageActivity();

  /// The language the reviews in no language's share belong to: those made
  /// before languages were recorded, here or on a device with an older app.
  /// Settled once, see [_settleActivityRestLanguage].
  String? _activityRestLanguage;

  List<Lesson> get lessons => _lessons;

  /// The languages being learned, as [Lesson.languageKey]s, in the order
  /// their first lessons were added.
  List<String> get languages {
    final seen = <String>{};
    return [
      for (final lesson in _lessons)
        if (seen.add(lesson.languageKey)) lesson.languageKey,
    ];
  }

  /// The language shown: lessons, pools, the study queue and Study activity
  /// are of one language at a time, so that Korean and Chinese do not mix.
  /// The one picked with [setActiveLanguage] while it still has lessons,
  /// else the first there is. Null while there are no lessons.
  String? get activeLanguage {
    final all = languages;
    if (all.isEmpty) return null;
    return all.contains(_pickedLanguage) ? _pickedLanguage : all.first;
  }

  /// The lessons of [activeLanguage]: all of them while only one language
  /// is being learned.
  List<Lesson> get activeLessons {
    final all = languages;
    if (all.length < 2) return _lessons;
    final active = all.contains(_pickedLanguage) ? _pickedLanguage : all.first;
    return [
      for (final lesson in _lessons)
        if (lesson.languageKey == active) lesson,
    ];
  }

  /// The Sentence Pool of [activeLanguage]. A pool is shared by the regions
  /// of a language, so Mainland and Taiwan Mandarin lessons have one pool,
  /// and every sentence is in exactly one: see [_sentenceLanguages].
  List<Sentence> get activeSentences {
    final active = activeLanguage;
    if (active == null || languages.length < 2) return _sentences;
    final code = Lesson.languageCodeOf(active);
    final codes = {
      for (final language in languages) Lesson.languageCodeOf(language),
    };
    if (codes.length < 2) return _sentences;
    final languageOf = _sentenceLanguages(codes);
    return [
      for (final sentence in _sentences)
        if (languageOf[sentence.id] == code) sentence,
    ];
  }

  /// The language of every sentence, as one of [codes] (language codes
  /// without a region):
  /// - that of the lessons whose words use it, the first of them if they
  ///   are of several languages;
  /// - else that of the lesson it came with;
  /// - else the language it was added to the pool in ([Sentence.language]);
  /// - else the language its script says ([_scriptLanguage]);
  /// - else that of the first lesson.
  Map<String, String> _sentenceLanguages(Set<String> codes) {
    final byUse = <String, String>{};
    final byLesson = <String, String>{};
    for (final lesson in _lessons) {
      final code = lesson.targetLanguageCode;
      byLesson[lesson.id] = code;
      for (final vocab in lesson.vocabularies) {
        for (final id in vocab.sentenceIds) {
          byUse.putIfAbsent(id, () => code);
        }
      }
    }
    final fallback = _lessons.first.targetLanguageCode;
    String? known(String? code) => codes.contains(code) ? code : null;
    return {
      for (final sentence in _sentences)
        sentence.id:
            byUse[sentence.id] ??
            byLesson[sentence.lessonId] ??
            known(sentence.language) ??
            known(_scriptLanguage(sentence.targetText)) ??
            fallback,
    };
  }

  static final _hangul = RegExp(r'[\u1100-\u11FF\u3130-\u318F\uAC00-\uD7A3]');
  static final _kana = RegExp(r'[\u3040-\u30FF]');
  static final _han = RegExp(r'[\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF]');

  /// The language [text] is written in, as far as its script tells: Korean
  /// for Hangul, Japanese for kana, Chinese for Han characters alone. Null
  /// for any other script.
  static String? _scriptLanguage(String text) => _hangul.hasMatch(text)
      ? 'ko'
      : _kana.hasMatch(text)
      ? 'ja'
      : _han.hasMatch(text)
      ? 'zh'
      : null;

  /// Shows [language], a [Lesson.languageKey], from now on. Kept on this
  /// device only.
  Future<void> setActiveLanguage(String language) async {
    if (_pickedLanguage == language) return;
    final shown = activeLanguage;
    _pickedLanguage = language;
    if (shown != activeLanguage) notifyListeners();
    await StorageService.saveActiveLanguage(language);
  }

  List<Sentence> get sentences => _sentences;
  bool get autoplayAudio => _autoplayAudio;

  /// False when the learner turned AI features off in Settings: the
  /// Discussions tab, Ask AI and the AI buttons are hidden.
  bool get showAi => _showAi;
  bool showRomanization(PronunciationTarget target) =>
      _pronunciationOptions.contains('${target.name}_romanization');
  bool showIpa(PronunciationTarget target) =>
      _pronunciationOptions.contains('${target.name}_ipa');
  String get deepSeekApiKey => _deepSeekApiKey;

  /// The sync account this device is signed in to, if any.
  SyncPairing? get syncPairing => _syncPairing;

  /// False without a key, after DeepSeek rejected it (until it changes), and
  /// while AI features are turned off.
  bool get canUseAi =>
      _showAi && _deepSeekApiKey.trim().isNotEmpty && !_deepSeekKeyRejected;
  List<VocabMergeRecord> get mergeHistory => List.unmodifiable(_mergeHistory);
  bool get isLoading => _isLoading;
  String? get selectedLessonId => _selectedLessonId;
  int get maxReviews24h => _maxReviews24h;
  int get maxNewCards24h => _maxNewCards24h;

  /// Whether [language] stands for every lesson: while one language is
  /// being learned nothing is told apart, and counts are the totals.
  bool _isEveryLanguage(String? language) =>
      language == null || languages.length < 2;

  /// The lessons of [language]: all of them when [_isEveryLanguage].
  Iterable<Lesson> _lessonsOf(String? language) => _isEveryLanguage(language)
      ? _lessons
      : _lessons.where((lesson) => lesson.languageKey == language);

  /// The language that takes the reviews recorded without one: the one
  /// settled on while it still has lessons, else the first there is.
  String? get _restLanguage {
    final all = languages;
    if (all.isEmpty) return null;
    return all.contains(_activityRestLanguage)
        ? _activityRestLanguage
        : all.first;
  }

  /// Settles which language the reviews recorded without one belong to, once
  /// there are lessons: the language reviewed the most so far. For someone
  /// who studied one language before adding another, that is the first one.
  Future<void> _settleActivityRestLanguage() async {
    if (_activityRestLanguage != null || _lessons.isEmpty) return;
    final reviews = <String, int>{};
    for (final lesson in _lessons) {
      var count = 0;
      for (final vocab in lesson.vocabularies) {
        count +=
            vocab.cardTargetToNative.repetitions +
            vocab.cardNativeToTarget.repetitions;
      }
      reviews[lesson.languageKey] = (reviews[lesson.languageKey] ?? 0) + count;
    }
    var most = languages.first;
    for (final language in languages) {
      if (reviews[language]! > reviews[most]!) most = language;
    }
    _activityRestLanguage = most;
    await StorageService.saveActivityRestLanguage(most);
  }

  /// Reviews per day of [language] on every device: this one's and those
  /// pulled by sync. Each day's reviews, ratings and new cards started.
  Map<DateTime, ActivityShare> _activityDays(String? language) {
    final every = _isEveryLanguage(language);
    final takesRest = language == _restLanguage;
    final days = <DateTime, ActivityShare>{};
    void add(
      DateTime day,
      ActivityShare total,
      Map<String, ActivityShare> Function() byLanguage,
    ) {
      final share = every
          ? total
          : ActivityShare.of(
              total,
              byLanguage(),
              language!,
              takesRest: takesRest,
            );
      if (share.isEmpty) return;
      days.putIfAbsent(day, ActivityShare.new).add(share);
    }

    for (final day in {
      ..._dailyReviewCounts.keys,
      ..._dailyRatingCounts.keys,
      ..._dailyNewCardCounts.keys,
    }) {
      add(
        day,
        ActivityShare(
          count: _dailyReviewCounts[day] ?? 0,
          ratings: {...?_dailyRatingCounts[day]},
          newCards: _dailyNewCardCounts[day] ?? 0,
        ),
        () => _languageActivity.sharesOn(day),
      );
    }
    for (final activity in _remoteActivity.values) {
      final day = DateTime.tryParse('${activity['day']}');
      if (day == null) continue;
      add(
        DateTime(day.year, day.month, day.day),
        ActivityShare.fromJson(activity),
        () => _remoteShares(activity),
      );
    }
    return days;
  }

  /// The shares by language in another device's activity record. A record
  /// from an older app has none.
  static Map<String, ActivityShare> _remoteShares(
    Map<String, dynamic> activity,
  ) {
    final byLanguage = activity['languages'];
    return {
      if (byLanguage is Map)
        for (final entry in byLanguage.entries)
          '${entry.key}': ActivityShare.fromJson(entry.value),
    };
  }

  /// Reviews per day of the language shown ([activeLanguage]), on every
  /// device.
  Map<DateTime, int> get dailyReviewCounts =>
      dailyReviewCountsOf(activeLanguage);

  /// Reviews per day of [language], a [Lesson.languageKey], on every device:
  /// this one's and those pulled by sync. Null for every language.
  Map<DateTime, int> dailyReviewCountsOf(String? language) => Map.unmodifiable({
    for (final entry in _activityDays(language).entries)
      if (entry.value.count > 0) entry.key: entry.value.count,
  });

  /// Reviews per day and rating of the language shown, on every device.
  /// Reviews counted before ratings were recorded, here or on a device with
  /// an older app, are only in [dailyReviewCounts], so a day's ratings can
  /// add up to less than its total.
  Map<DateTime, Map<SrsRating, int>> get dailyRatingCounts => Map.unmodifiable({
    for (final entry in _activityDays(activeLanguage).entries)
      if (entry.value.ratings.isNotEmpty)
        entry.key: Map<SrsRating, int>.unmodifiable(entry.value.ratings),
  });

  /// New cards started per day of the language shown, on every device. Days
  /// from before this was counted, here or on a device with an older app,
  /// have none.
  Map<DateTime, int> get dailyNewCardCounts => Map.unmodifiable({
    for (final entry in _activityDays(activeLanguage).entries)
      if (entry.value.newCards > 0) entry.key: entry.value.newCards,
  });

  Map<String, List<AiDiscussionMessage>> get aiDiscussions => Map.unmodifiable(
    _aiDiscussions.map<String, List<AiDiscussionMessage>>(
      (id, messages) =>
          MapEntry(id, List<AiDiscussionMessage>.unmodifiable(messages)),
    ),
  );
  Map<String, int> get lessonHierarchyOrder =>
      Map.unmodifiable(_lessonHierarchyOrder);
  Map<String, bool> get lessonFolderExpansion =>
      Map.unmodifiable(_lessonFolderExpansion);

  /// Reviews of the language shown on every device in the last 24 hours,
  /// so studying on two devices does not double the limit.
  int get reviewsInLast24Hours => reviewsInLast24HoursOf(activeLanguage);

  /// Reviews of [language] on every device in the last 24 hours. Each
  /// language has the 24-hour limits to itself.
  int reviewsInLast24HoursOf(String? language) {
    final now = DateTime.now();
    bool recent(DateTime time) => now.difference(time).inHours < 24;
    int recentIn(Object? reviews) {
      if (reviews is! List) return 0;
      var count = 0;
      for (final review in reviews) {
        final time = DateTime.tryParse('$review');
        if (time != null && recent(time)) count++;
      }
      return count;
    }

    _reviewTimestamps24h.removeWhere((time) => !recent(time));
    final every = _isEveryLanguage(language);
    final takesRest = language == _restLanguage;
    // What of [all] reviews is the language's, given each language's own.
    int share(int all, Map<String, int> byLanguage) {
      if (every) return all;
      var own = byLanguage[language] ?? 0;
      if (takesRest) {
        final recorded = byLanguage.values.fold(0, (sum, n) => sum + n);
        if (all > recorded) own += all - recorded;
      }
      return own;
    }

    var count = share(_reviewTimestamps24h.length, {
      for (final entry in _languageActivity.reviewTimes.entries)
        entry.key: entry.value.where(recent).length,
    });
    for (final activity in _remoteActivity.values) {
      final byLanguage = activity['languages'];
      count += share(recentIn(activity['reviews']), {
        if (byLanguage is Map)
          for (final entry in byLanguage.entries)
            if (entry.value is Map)
              '${entry.key}': recentIn((entry.value as Map)['reviews']),
      });
    }
    return count;
  }

  /// Cards of the language shown seen for the first time in the last 24
  /// hours.
  int get newCardsIntroducedLast24h =>
      newCardsIntroducedLast24hOf(activeLanguage);

  /// Cards of [language] seen for the first time in the last 24 hours.
  /// Derived from the cards, so undoing or re-rating a first review gives
  /// the quota back.
  int newCardsIntroducedLast24hOf(String? language) {
    final now = DateTime.now();
    final counted = <String>{};
    for (final lesson in _lessonsOf(language)) {
      for (final vocab in lesson.vocabularies) {
        for (final card in [
          vocab.cardTargetToNative,
          vocab.cardNativeToTarget,
        ]) {
          final introducedAt = card.introducedAt;
          if (introducedAt != null &&
              now.difference(introducedAt).inHours < 24) {
            counted.add(card.id);
          }
        }
      }
    }
    return counted.length;
  }

  /// Reviews of already-seen cards of the language shown. A card's first
  /// review counts against the new-card limit instead.
  int get reviewsOfSeenCardsInLast24Hours =>
      _reviewsOfSeenCardsInLast24HoursOf(activeLanguage);

  int _reviewsOfSeenCardsInLast24HoursOf(String? language) => max(
    0,
    reviewsInLast24HoursOf(language) - newCardsIntroducedLast24hOf(language),
  );

  /// Reviews the language shown has left in its 24-hour limit.
  int get remainingReviews24h => remainingReviews24hOf(activeLanguage);

  /// Reviews [language] has left in the 24-hour limit, which every language
  /// has to itself.
  int remainingReviews24hOf(String? language) {
    if (_maxReviews24h <= 0) return 999999;
    return max(
      0,
      _maxReviews24h - _reviewsOfSeenCardsInLast24HoursOf(language),
    );
  }

  /// New cards of the language shown that can be started now.
  int get remainingNewCards24h => remainingNewCards24hOf(activeLanguage);

  /// New cards of [language] that can be started now. The limit, which
  /// every language has to itself, refills 16 hours after a batch and stays
  /// at most the limit per 24 hours on average; see [NewCardQuota].
  int remainingNewCards24hOf(String? language) {
    if (_maxNewCards24h <= 0) return 999999;
    final starts = <String, DateTime>{};
    for (final lesson in _lessonsOf(language)) {
      for (final vocab in lesson.vocabularies) {
        for (final card in [
          vocab.cardTargetToNative,
          vocab.cardNativeToTarget,
        ]) {
          final introducedAt = card.introducedAt;
          if (introducedAt != null) starts[card.id] = introducedAt;
        }
      }
    }
    return NewCardQuota.remaining(
      _maxNewCards24h,
      starts.values,
      DateTime.now(),
    );
  }

  Future<void> setMaxReviews24h(int limit) async {
    _maxReviews24h = limit;
    await StorageService.saveMaxReviews24h(limit);
    notifyListeners();
  }

  Future<void> setMaxNewCards24h(int limit) async {
    _maxNewCards24h = limit;
    await StorageService.saveMaxNewCards24h(limit);
    notifyListeners();
  }

  Lesson? get currentLesson {
    if (_selectedLessonId == null) return null;
    try {
      return _lessons.firstWhere((l) => l.id == _selectedLessonId);
    } catch (_) {
      return null;
    }
  }

  AppProvider() {
    init();
  }

  Future<void> init() async {
    _isLoading = true;
    notifyListeners();

    // Let the first frame render before heavy storage work starts.
    await Future<void>.delayed(Duration.zero);

    final results = await (
      StorageService.loadAutoplay(),
      StorageService.loadDeepSeekApiKey(),
      StorageService.loadAiDiscussions(),
      StorageService.loadMaxReviews24h(),
      StorageService.loadReviewTimestamps(),
      StorageService.loadLessonHierarchyOrder(),
      StorageService.loadLessonFolderExpansion(),
      StorageService.loadPronunciationOptions(),
      StorageService.loadMaxNewCards24h(),
    ).wait;
    _autoplayAudio = results.$1;
    _deepSeekApiKey = results.$2;
    _syncPairing = await StorageService.loadSyncPairing();
    _lastSyncedAt = await StorageService.loadLastSyncedAt();
    _mergeHistory = await StorageService.loadMergeHistory();
    _aiDiscussions = results.$3;
    _maxReviews24h = results.$4;
    _reviewTimestamps24h = results.$5;
    _lessonHierarchyOrder = _composedKeys(results.$6);
    _lessonFolderExpansion = _composedKeys(results.$7);
    _pronunciationOptions = results.$8;
    _maxNewCards24h = results.$9;
    // Records only have `.wait` up to nine fields, so this loads on its own.
    _showAi = await StorageService.loadShowAi();
    _pickedLanguage = await StorageService.loadActiveLanguage();
    _typedQuestions = await StorageService.loadTypedQuestions();
    _dailyReviewCounts = await StorageService.loadDailyReviewCounts();
    _dailyRatingCounts = await StorageService.loadDailyRatingCounts();
    _dailyNewCardCounts = await StorageService.loadDailyNewCardCounts();
    _remoteActivity = await StorageService.loadSyncRemoteActivity();
    _languageActivity = await StorageService.loadLanguageActivity();
    _activityRestLanguage = await StorageService.loadActivityRestLanguage();
    await _settleActivityRestLanguage();
    _lessons = await StorageService.loadLessons();
    if (_dailyReviewCounts.isEmpty && _backfillDailyReviewCounts()) {
      await StorageService.saveDailyReviewCounts(_dailyReviewCounts);
    }
    // Loaded after lessons because a fresh debug install seeds sentences there.
    _sentences = await StorageService.loadSentences();
    // Before canonicalizing: duplicates merge into one sentence, and each word
    // must have taken its own `**` marking by then.
    final splitEmphasis = _splitSentenceEmphasis();
    final canonicalized = _canonicalizeSentencePool();
    final deduped = _dedupeSentenceLinks();
    final merged = _mergeSameVirtualPathLessons();
    if (splitEmphasis || canonicalized || deduped || merged.lessons) {
      await StorageService.saveSentences(_sentences);
      await StorageService.saveLessons(_lessons);
    }
    _linkSharedVocabProgress();
    if (_canonicalizeAiDiscussions() || merged.chats) {
      await StorageService.saveAiDiscussions(_aiDiscussions);
    }

    if (_lessons.isNotEmpty) {
      _selectedLessonId = _lessons.first.id;
    }

    _isLoading = false;
    notifyListeners();
  }

  /// Merges sentences with the same text into one, and points every word at
  /// it. Every device must keep the same copy, or two devices that imported
  /// the same sentence would each delete the other's and lose it when they
  /// sync (#90). So the copy kept does not depend on the order of the list:
  /// the one with a recording, then the smallest id. The others' notes, TTS
  /// text, recording and lesson fill in what it lacks, in that same order.
  /// Returns whether anything changed.
  bool _canonicalizeSentencePool() {
    final groups = <String, List<Sentence>>{};
    for (final sentence in _sentences) {
      groups.putIfAbsent(_sentenceSignature(sentence), () => []).add(sentence);
    }
    if (groups.values.every((group) => group.length == 1)) return false;

    bool hasAudio(Sentence sentence) =>
        sentence.audioUrl?.trim().isNotEmpty == true;
    bool hasText(String? text) => text?.trim().isNotEmpty == true;
    final kept = <Sentence>{};
    final redirectedIds = <String, String>{};
    for (final group in groups.values) {
      final ranked = [...group]
        ..sort((a, b) {
          final byAudio = (hasAudio(b) ? 1 : 0).compareTo(hasAudio(a) ? 1 : 0);
          return byAudio != 0 ? byAudio : a.id.compareTo(b.id);
        });
      final canonical = ranked.first;
      kept.add(canonical);
      for (final other in ranked.skip(1)) {
        if (!hasText(canonical.notes) && hasText(other.notes)) {
          canonical.notes = other.notes;
        }
        if (!hasText(canonical.ttsText) && hasText(other.ttsText)) {
          canonical.ttsText = other.ttsText;
        }
        if (!hasAudio(canonical) && hasAudio(other)) {
          canonical.audioUrl = other.audioUrl;
        }
        canonical.lessonId ??= other.lessonId;
        redirectedIds[other.id] = canonical.id;
      }
    }

    for (final vocab in _lessons.expand((lesson) => lesson.vocabularies)) {
      _redirectSentences(vocab, redirectedIds);
    }
    _sentences = [
      for (final sentence in _sentences)
        if (kept.contains(sentence)) sentence,
    ];
    return true;
  }

  /// Moves the `**` emphasis of sentences saved before each word had its own:
  /// every word linking such a sentence takes the marking as its own, and the
  /// pool keeps plain text. Returns whether anything changed.
  bool _splitSentenceEmphasis() {
    final byId = {for (final sentence in _sentences) sentence.id: sentence};
    var changed = false;
    for (final vocab in _lessons.expand((lesson) => lesson.vocabularies)) {
      for (final id in vocab.sentenceIds) {
        final sentence = byId[id];
        if (sentence == null || vocab.sentenceEmphasis.containsKey(id)) {
          continue;
        }
        if (!Sentence.hasEmphasis(sentence.targetText) &&
            !Sentence.hasEmphasis(sentence.translationText)) {
          continue;
        }
        vocab.sentenceEmphasis[id] = SentenceEmphasis(
          target: sentence.targetText,
          translation: sentence.translationText,
        );
        changed = true;
      }
    }
    for (final sentence in _sentences) {
      final target = Sentence.stripEmphasis(sentence.targetText);
      final translation = Sentence.stripEmphasis(sentence.translationText);
      if (target == sentence.targetText &&
          translation == sentence.translationText) {
        continue;
      }
      sentence
        ..targetText = target
        ..translationText = translation;
      changed = true;
    }
    return changed;
  }

  /// Drops an id a word lists twice. Returns whether anything changed.
  bool _dedupeSentenceLinks() {
    var changed = false;
    for (final vocab in _lessons.expand((lesson) => lesson.vocabularies)) {
      final unique = _unique(vocab.sentenceIds);
      if (unique.length == vocab.sentenceIds.length) continue;
      vocab.sentenceIds = unique;
      changed = true;
    }
    return changed;
  }

  /// Points [vocab] at the sentences [redirect] maps its ids to, and keeps its
  /// emphasis with them. When two ids become one, the emphasis already kept
  /// for the surviving id wins.
  static void _redirectSentences(
    VocabItem vocab,
    Map<String, String> redirect,
  ) {
    if (redirect.isEmpty) return;
    final emphasis = <String, SentenceEmphasis>{};
    for (final entry in vocab.sentenceEmphasis.entries) {
      if (!redirect.containsKey(entry.key)) emphasis[entry.key] = entry.value;
    }
    for (final entry in vocab.sentenceEmphasis.entries) {
      emphasis.putIfAbsent(redirect[entry.key] ?? entry.key, () => entry.value);
    }
    vocab.sentenceEmphasis = emphasis;
    vocab.sentenceIds = _unique(
      vocab.sentenceIds.map((id) => redirect[id] ?? id),
    );
  }

  /// After [sentence] was edited, fits every word's emphasis of it to the new
  /// text: what the edit did not touch stays emphasized, and a word whose
  /// emphasis was edited away gets a fresh suggestion from its own text.
  ///
  /// Returns whether any word's emphasis changed. Emphasis that already fits
  /// the text is left as it is.
  bool _carryEmphasisTo(Sentence sentence) {
    var changed = false;
    for (final vocab in _lessons.expand((lesson) => lesson.vocabularies)) {
      final emphasis = vocab.sentenceEmphasis[sentence.id];
      if (emphasis == null) continue;
      final carried = SentenceEmphasis(
        target:
            Sentence.carryEmphasis(emphasis.target, sentence.targetText) ??
            Sentence.suggestEmphasis(
              sentence.targetText,
              vocab.targetWord,
              korean: true,
            ),
        translation:
            Sentence.carryEmphasis(
              emphasis.translation,
              sentence.translationText,
            ) ??
            Sentence.suggestEmphasis(
              sentence.translationText,
              vocab.translation,
            ),
      );
      if (carried == emphasis) continue;
      vocab.sentenceEmphasis[sentence.id] = carried;
      changed = true;
    }
    return changed;
  }

  void selectLesson(String? lessonId) {
    _selectedLessonId = lessonId;
    notifyListeners();
  }

  Future<void> toggleAutoplay() async {
    _autoplayAudio = !_autoplayAudio;
    await StorageService.saveAutoplay(_autoplayAudio);
    notifyListeners();
  }

  Future<void> setShowAi(bool value) async {
    if (_showAi == value) return;
    _showAi = value;
    await StorageService.saveShowAi(value);
    notifyListeners();
  }

  Future<void> toggleRomanization(PronunciationTarget target) =>
      _togglePronunciation('${target.name}_romanization');

  Future<void> toggleIpa(PronunciationTarget target) =>
      _togglePronunciation('${target.name}_ipa');

  Future<void> _togglePronunciation(String option) async {
    if (!_pronunciationOptions.remove(option)) {
      _pronunciationOptions.add(option);
    }
    await StorageService.savePronunciationOptions(_pronunciationOptions);
    notifyListeners();
  }

  Future<void> setDeepSeekApiKey(String apiKey) async {
    final trimmedApiKey = apiKey.trim();
    await StorageService.saveDeepSeekApiKey(trimmedApiKey);
    _deepSeekApiKey = trimmedApiKey;
    _deepSeekKeyRejected = false;
    notifyListeners();
  }

  Future<void> setSyncPairing(SyncPairing? pairing) async {
    final previous = _syncPairing;
    await StorageService.saveSyncPairing(pairing);
    // Unlocked again for the new sign-in, so a key never outlives its account.
    try {
      await StorageService.saveSyncDataKey(null);
    } catch (error) {
      debugPrint('Could not remove the sync data key: $error');
    }
    _syncPairing = pairing;
    // Signing out, or into another account, starts the sync state again; a
    // new password for the same account keeps it.
    if (pairing == null ||
        previous == null ||
        previous.email != pairing.email ||
        previous.endpoint != pairing.endpoint) {
      await _queueSyncTracking(() async {
        final tracker = await StorageService.loadSyncChangeTracker();
        tracker.reset();
        await StorageService.saveSyncChangeTracker(tracker);
      });
      _lastSyncedAt = null;
      _syncProblem = null;
      await StorageService.saveLastSyncedAt(null);
    }
    notifyListeners();
  }

  bool _syncing = false;
  DateTime? _lastSyncedAt;
  String? _syncProblem;

  /// Test hooks: where a sync unlocks the data key and sends its requests.
  @visibleForTesting
  SyncAccountService? syncAccounts;
  @visibleForTesting
  http.Client Function()? syncHttpClient;

  /// A sync is running.
  bool get isSyncing => _syncing;

  /// When the last sync finished, on this device.
  DateTime? get lastSyncedAt => _lastSyncedAt;

  /// Why the last sync stopped or was incomplete, in words a person can act
  /// on; null when it went through.
  String? get syncProblem => _syncProblem;

  /// Whether the last sync failed in a way that is worth trying again on its
  /// own: the server could not be reached, or it failed on its side.
  bool get syncShouldRetry => _syncShouldRetry;
  bool _syncShouldRetry = false;

  /// Syncs with the server now: pulls, applies and pushes. Returns null when
  /// signed out or when a sync is already running. Never throws: a failure is
  /// kept in [syncProblem] and the local data stays as it is.
  Future<SyncResult?> syncNow() async {
    final pairing = _syncPairing;
    if (pairing == null || _syncing) return null;
    _syncing = true;
    notifyListeners();
    SyncResult? result;
    _syncShouldRetry = false;
    try {
      final synced = await _queueSyncTracking(() => _runSync(pairing));
      result = synced;
      _syncProblem = switch (synced.outcome) {
        SyncOutcome.signInRejected => describeSyncError(
          const SyncException('invalid_credentials', statusCode: 401),
          signedIn: true,
        ),
        SyncOutcome.accountChanged =>
          'This account was deleted and created again with the same email '
              'and password. Sync is paused so the two are not mixed. Your '
              'lessons and progress are still on this device. Sign out and '
              'sign in again to use the new account.',
        SyncOutcome.synced when synced.needsAppUpdate.isNotEmpty =>
          '${synced.needsAppUpdate.length} items were changed by a newer '
              'version of the app. Update the app to sync them.',
        SyncOutcome.synced when synced.unreadable > 0 =>
          '${synced.unreadable} items from the server could not be read.',
        SyncOutcome.synced => null,
      };
      if (synced.outcome == SyncOutcome.synced) {
        _lastSyncedAt = DateTime.now();
        await StorageService.saveLastSyncedAt(_lastSyncedAt);
      }
    } catch (error) {
      _syncProblem = describeSyncError(error, signedIn: true);
      _syncShouldRetry = isSyncRetryable(error);
    } finally {
      _syncing = false;
      notifyListeners();
    }
    return result;
  }

  Future<SyncResult> _runSync(SyncPairing pairing) async {
    var key = await StorageService.loadSyncDataKey();
    if (key == null || !key.belongsTo(pairing) || key.authKey == null) {
      key = await (syncAccounts ?? SyncAccountService()).unlockDataKey(pairing);
      await StorageService.saveSyncDataKey(key);
    }
    final tracker = await StorageService.loadSyncChangeTracker();
    final client = SyncClient(
      endpoint: pairing.endpoint,
      email: pairing.email,
      authKey: key.authKey!,
      client: syncHttpClient?.call(),
    );
    try {
      return await SyncEngine(
        client: client,
        cipher: await SyncRecordCipher.create(key.key),
        store: this,
        tracker: tracker,
        accountCreatedAt: key.createdAt,
        save: () => StorageService.saveSyncChangeTracker(tracker),
      ).sync();
    } finally {
      client.close();
    }
  }

  Future<void> _syncTracking = Future.value();

  /// Runs [task] after any earlier one, so two never load and save the sync
  /// state at once.
  Future<T> _queueSyncTracking<T>(Future<T> Function() task) {
    final result = _syncTracking.then((_) => task());
    _syncTracking = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  /// Notes which synced records changed since the last call, and returns
  /// them. Does nothing while signed out. See "Records" in `docs/sync.md`.
  Future<List<SyncRecordKey>> trackSyncChanges({DateTime? now}) {
    if (_syncPairing == null) return Future.value(const []);
    return _queueSyncTracking(() async {
      final tracker = await StorageService.loadSyncChangeTracker();
      final changed = tracker.track(
        syncSnapshot(tracker.deviceId),
        now: (now ?? DateTime.now()).millisecondsSinceEpoch,
        stampNew: SyncSnapshot.knownChangeTime,
      );
      await StorageService.saveSyncChangeTracker(tracker);
      return changed;
    });
  }

  @override
  Map<SyncRecordKey, Map<String, dynamic>> snapshot(String deviceId) =>
      syncSnapshot(deviceId);

  /// Applies records pulled by sync, saves what changed, and updates screens.
  @override
  Future<void> apply(
    String deviceId,
    Map<SyncRecordKey, Map<String, dynamic>?> changes, {
    bool firstSync = false,
  }) async {
    final data = SyncAppData(
      deviceId: deviceId,
      lessons: _lessons,
      sentences: _sentences,
      mergeHistory: _mergeHistory,
      aiDiscussions: _aiDiscussions,
      typedQuestions: _typedQuestions,
      lessonOrder: _lessonHierarchyOrder,
      maxReviews24h: _maxReviews24h,
      maxNewCards24h: _maxNewCards24h,
      autoplayAudio: _autoplayAudio,
      pronunciationOptions: _pronunciationOptions,
      remoteActivity: {..._remoteActivity},
    );
    final changed = {...SyncApplier.apply(data, changes, firstSync: firstSync)};

    _lessons = data.lessons;
    _sentences = data.sentences;
    _mergeHistory = data.mergeHistory;
    _aiDiscussions = data.aiDiscussions;
    _typedQuestions = data.typedQuestions;
    _lessonHierarchyOrder = _composedKeys(data.lessonOrder);
    _maxReviews24h = data.maxReviews24h;
    _maxNewCards24h = data.maxNewCards24h;
    _autoplayAudio = data.autoplayAudio;
    _pronunciationOptions = data.pronunciationOptions;
    _remoteActivity = data.remoteActivity;
    // A pulled sentence's text may have been edited on another device, while
    // its words' emphasis came in an older lesson record (one edited here won
    // the conflict). Fit the emphasis to the text, as an edit here would.
    final byId = {for (final sentence in _sentences) sentence.id: sentence};
    var carried = false;
    for (final entry in changes.entries) {
      if (entry.key.kind != SyncKinds.sentence || entry.value == null) continue;
      final sentence = byId[entry.key.localId];
      if (sentence != null && _carryEmphasisTo(sentence)) carried = true;
    }
    if (carried) changed.add(SyncAppPart.lessons);
    if (changed.contains(SyncAppPart.lessons)) {
      final merged = _mergeSameVirtualPathLessons();
      if (merged.lessons) {
        changed
          ..add(SyncAppPart.lessons)
          ..add(SyncAppPart.sentences);
      }
      if (merged.chats) changed.add(SyncAppPart.aiDiscussions);
    }
    // A pulled sentence can be one this device imported separately: merge
    // them now, the same way on every device, rather than at the next start.
    if (changed.contains(SyncAppPart.sentences) ||
        changed.contains(SyncAppPart.lessons)) {
      final merged = _canonicalizeSentencePool();
      final deduped = _dedupeSentenceLinks();
      if (merged || deduped) {
        changed
          ..add(SyncAppPart.sentences)
          ..add(SyncAppPart.lessons);
      }
    }
    if (_selectedLessonId != null &&
        !_lessons.any((lesson) => lesson.id == _selectedLessonId)) {
      _selectedLessonId = _lessons.isEmpty ? null : _lessons.first.id;
    }

    if (changed.contains(SyncAppPart.lessons)) {
      await StorageService.saveLessons(_lessons);
    }
    if (changed.contains(SyncAppPart.sentences)) {
      await StorageService.saveSentences(_sentences);
    }
    if (changed.contains(SyncAppPart.mergeHistory)) {
      await StorageService.saveMergeHistory(_mergeHistory);
    }
    if (changed.contains(SyncAppPart.aiDiscussions)) {
      await StorageService.saveAiDiscussions(_aiDiscussions);
    }
    if (changed.contains(SyncAppPart.typedQuestions)) {
      await StorageService.saveTypedQuestions(_typedQuestions);
    }
    if (changed.contains(SyncAppPart.lessonOrder)) {
      await StorageService.saveLessonHierarchyOrder(_lessonHierarchyOrder);
    }
    if (changed.contains(SyncAppPart.settings)) {
      await StorageService.saveMaxReviews24h(_maxReviews24h);
      await StorageService.saveMaxNewCards24h(_maxNewCards24h);
      await StorageService.saveAutoplay(_autoplayAudio);
      await StorageService.savePronunciationOptions(_pronunciationOptions);
    }
    if (changed.contains(SyncAppPart.remoteActivity)) {
      await StorageService.saveSyncRemoteActivity(_remoteActivity);
    }
    notifyListeners();
  }

  /// The contents of every synced record, with this device's activity under
  /// [deviceId].
  Map<SyncRecordKey, Map<String, dynamic>> syncSnapshot(String deviceId) =>
      SyncSnapshot.build(
        lessons: _lessons,
        sentences: _sentences,
        mergeHistory: _mergeHistory,
        aiDiscussions: _aiDiscussions,
        typedQuestions: _typedQuestions,
        lessonOrder: _syncLessonHierarchyOrder(),
        settings: SyncSettings(
          maxReviews24h: _maxReviews24h,
          maxNewCards24h: _maxNewCards24h,
          autoplayAudio: _autoplayAudio,
          pronunciationOptions: _pronunciationOptions,
        ),
        dailyReviewCounts: _dailyReviewCounts,
        dailyRatingCounts: _dailyRatingCounts,
        dailyNewCardCounts: _dailyNewCardCounts,
        reviewTimestamps: _reviewTimestamps24h,
        languageActivity: _languageActivity,
        deviceId: deviceId,
      );

  Map<String, int> _syncLessonHierarchyOrder() {
    final siblingsByParent = <String, List<String>>{};
    final seenByParent = <String, Set<String>>{};
    void addSibling(String parent, String key) {
      if (seenByParent.putIfAbsent(parent, () => {}).add(key)) {
        siblingsByParent.putIfAbsent(parent, () => []).add(key);
      }
    }

    for (final lesson in _orderedLessons()) {
      final path = <String>[];
      for (final folder in lesson.folderPath) {
        final parent = hierarchyFolderKey(path);
        path.add(folder);
        addSibling(parent, hierarchyFolderKey(path));
      }
      addSibling(hierarchyFolderKey(path), 'lesson:${lesson.id}');
    }
    return {
      for (final siblings in siblingsByParent.values)
        for (var index = 0; index < siblings.length; index++)
          siblings[index]: index,
    };
  }

  List<AiDiscussionMessage> getAiDiscussion(String discussionId) =>
      List.unmodifiable(_aiDiscussions[discussionId] ?? const []);

  Future<void> addAiDiscussionMessage(
    String discussionId,
    AiDiscussionMessage message,
  ) async {
    final savedMessage = message.createdAt == null
        ? AiDiscussionMessage(
            role: message.role,
            content: message.content,
            createdAt: DateTime.now(),
          )
        : message;
    final messages = List<AiDiscussionMessage>.from(
      _aiDiscussions[discussionId] ?? const [],
    )..add(savedMessage);
    _aiDiscussions[discussionId] = messages;
    await StorageService.saveAiDiscussions(_aiDiscussions);
    notifyListeners();
  }

  /// Questions typed in AI chats, by id. See [TypedQuestions].
  Map<String, TypedQuestion> get typedQuestions =>
      Map.unmodifiable(_typedQuestions);

  /// Notes that [question] was typed in an AI chat about [subject] (a word,
  /// or a lesson's title), or tapped after it was offered as one typed
  /// before, so it is offered again. Does nothing for a question that only
  /// fits that one word or lesson.
  Future<void> recordTypedQuestion({
    required String question,
    required String subject,
    required String language,
    required TypedQuestionScope scope,
    DateTime? now,
  }) async {
    final next = TypedQuestions.recordUse(
      _typedQuestions,
      question: question,
      subject: subject,
      language: language,
      scope: scope,
      now: now ?? DateTime.now(),
    );
    if (identical(next, _typedQuestions)) return;
    _typedQuestions = next;
    await StorageService.saveTypedQuestions(_typedQuestions);
    notifyListeners();
  }

  /// Stops offering the typed question with [id].
  Future<void> removeTypedQuestion(String id) async {
    if (!_typedQuestions.containsKey(id)) return;
    _typedQuestions = {..._typedQuestions}..remove(id);
    await StorageService.saveTypedQuestions(_typedQuestions);
    notifyListeners();
  }

  Future<void> deleteAiDiscussion(String discussionId) async {
    if (_aiDiscussions.remove(discussionId) == null) return;
    await StorageService.saveAiDiscussions(_aiDiscussions);
    notifyListeners();
  }

  /// Every saved discussion with the lesson, vocabulary and sentence it is
  /// about, for listing and searching.
  List<AiDiscussionSummary> get aiDiscussionSummaries => [
    for (final entry in _aiDiscussions.entries)
      AiDiscussionSummary.resolve(
        id: entry.key,
        messages: entry.value,
        lessons: _lessons,
        sentenceById: getSentenceById,
      ),
  ];

  /// [aiDiscussionSummaries] of [activeLanguage]: chats about its lessons
  /// and their words. A chat whose lesson or word is gone belongs to no
  /// language, and is listed in every one.
  List<AiDiscussionSummary> get activeAiDiscussionSummaries {
    final all = aiDiscussionSummaries;
    final shown = activeLessons;
    if (identical(shown, _lessons)) return all;
    final lessonIds = {for (final lesson in shown) lesson.id};
    final vocabIds = {
      for (final lesson in shown)
        for (final vocab in lesson.vocabularies) vocab.id,
    };
    return [
      for (final summary in all)
        if (summary.lesson != null
            ? lessonIds.contains(summary.lesson!.id)
            : summary.vocab == null || vocabIds.contains(summary.vocab!.id))
          summary,
    ];
  }

  /// Earlier discussions worth showing when [discussionId] is opened: other
  /// discussions of the same word first, then related words.
  List<AiDiscussionSuggestion> relatedAiDiscussions(
    String discussionId, {
    int limit = 6,
  }) => AiDiscussionSuggestions.forDiscussion(
    discussionId: discussionId,
    groups: vocabGroups,
    discussions: aiDiscussionSummaries,
    limit: limit,
  );

  /// The id of every vocabulary right now, to tell afterwards which words got
  /// a new one.
  Map<VocabItem, String> _currentVocabIds() =>
      HashMap<VocabItem, String>.identity()..addEntries(
        _lessons
            .expand((lesson) => lesson.vocabularies)
            .map((vocab) => MapEntry(vocab, vocab.id)),
      );

  /// Moves saved AI discussions along with words whose id changed since
  /// [before] (from [_currentVocabIds]). An id changes when the word is
  /// re-imported after an edit, when its id is edited, or when it adopts the id
  /// of the same word in another lesson. Discussions are saved under the id, so
  /// without this they would be orphaned.
  ///
  /// Only a word that moved to another id follows its chats. If anything else
  /// still has the old id the word was split off, and the old id keeps them. If
  /// one old id became several, or the new id is itself being renamed away,
  /// nothing is moved, because it is not clear which chats belong where.
  Future<void> _followVocabIdChanges(Map<VocabItem, String> before) async {
    final renamedTo = <String, Set<String>>{};
    final inUse = <String>{};
    for (final vocab in _lessons.expand((lesson) => lesson.vocabularies)) {
      inUse.add(vocab.id);
      final previous = before[vocab];
      if (previous != null && previous != vocab.id) {
        renamedTo.putIfAbsent(previous, () => <String>{}).add(vocab.id);
      }
    }
    var moved = false;
    for (final entry in renamedTo.entries) {
      final oldId = entry.key;
      if (inUse.contains(oldId) || entry.value.length != 1) continue;
      final newId = entry.value.single;
      if (renamedTo.containsKey(newId)) continue;
      if (_moveAiDiscussions({oldId}, newId)) moved = true;
    }
    if (moved) await StorageService.saveAiDiscussions(_aiDiscussions);
  }

  /// Moves the saved discussions of [absorbedIds] to [survivorId], because
  /// merged words share one id afterwards and the old ids would be orphaned.
  /// Both words' conversations are joined, oldest message first.
  bool _moveAiDiscussions(Set<String> absorbedIds, String survivorId) {
    var changed = false;
    for (final key in List<String>.of(_aiDiscussions.keys)) {
      final vocabId = AiDiscussionIds.vocabIdFrom(key);
      if (vocabId == null || !absorbedIds.contains(vocabId)) continue;
      _joinAiDiscussion(
        AiDiscussionIds.forVocab(survivorId),
        _aiDiscussions.remove(key)!,
      );
      changed = true;
    }
    return changed;
  }

  /// Appends [messages] to the conversation saved under [key].
  void _joinAiDiscussion(String key, List<AiDiscussionMessage> messages) {
    _aiDiscussions[key] = AiDiscussionMessages.join([
      _aiDiscussions[key] ?? const [],
      messages,
    ]);
  }

  /// Folds the per-sentence discussions of a word, saved before its sentences
  /// shared one, into the word's single discussion. Returns whether anything
  /// moved.
  bool _canonicalizeAiDiscussions() {
    var changed = false;
    for (final key in List<String>.of(_aiDiscussions.keys)) {
      final canonical = AiDiscussionIds.canonical(key);
      if (canonical == key) continue;
      _joinAiDiscussion(canonical, _aiDiscussions.remove(key)!);
      changed = true;
    }
    return changed;
  }

  // Sentence Pool lookup
  Sentence? getSentenceById(String id) {
    try {
      return _sentences.firstWhere((s) => s.id == id);
    } catch (_) {
      return null;
    }
  }

  List<Sentence> getSentencesForVocab(VocabItem vocab) {
    return vocab.sentenceIds
        .map((id) => getSentenceById(id))
        .whereType<Sentence>()
        .toList();
  }

  /// The pool sentence [sentence] would merge into when added, if any.
  Sentence? findDuplicateSentence(Sentence sentence) {
    final signature = _sentenceSignature(sentence);
    for (final existing in _sentences) {
      if (_sentenceSignature(existing) == signature) return existing;
    }
    return null;
  }

  Future<Sentence> addSentenceToPool(Sentence sentence) async {
    // Added by hand, it has no lesson to tell its language: it is in the
    // language shown.
    if (sentence.lessonId == null && sentence.language == null) {
      final active = activeLanguage;
      if (active != null) sentence.language = Lesson.languageCodeOf(active);
    }
    final canonical = _upsertSentence(sentence);
    await StorageService.saveSentences(_sentences);
    notifyListeners();
    return canonical;
  }

  Future<Sentence> updateSentenceInPool(Sentence sentence) async {
    final canonical = _upsertSentence(sentence);
    _carryEmphasisTo(canonical);
    await StorageService.saveSentences(_sentences);
    await StorageService.saveLessons(_lessons);
    notifyListeners();
    return canonical;
  }

  /// Removes [sentence] from the pool and from every word listing it as an
  /// example. Saved AI discussions are kept, as they are when a word is deleted.
  Future<void> deleteSentenceFromPool(Sentence sentence) async {
    final before = _sentences.length;
    _sentences.removeWhere((s) => s.id == sentence.id);
    if (_sentences.length == before) return;
    for (final vocab in _lessons.expand((lesson) => lesson.vocabularies)) {
      vocab.sentenceIds.removeWhere((id) => id == sentence.id);
    }
    await StorageService.saveSentences(_sentences);
    await StorageService.saveLessons(_lessons);
    notifyListeners();
  }

  // Identity set of [_sentences], only maintained during a batch import.
  Set<Sentence>? _importSentenceSet;

  Sentence _upsertSentence(
    Sentence incoming, {
    Map<String, List<Sentence>>? bySignature,
  }) {
    final signature = _sentenceSignature(incoming);
    // With an index, a missing signature means no duplicates; rescanning the
    // whole pool per sentence made large batch imports quadratic.
    final duplicates =
        (bySignature != null
                ? bySignature[signature] ?? const <Sentence>[]
                : _sentences.where(
                    (sentence) => _sentenceSignature(sentence) == signature,
                  ))
            .where((sentence) => !identical(sentence, incoming))
            .toList();
    final candidates = [incoming, ...duplicates];
    // Keep the copy _canonicalizeSentencePool keeps, which every device
    // agrees on: a recording first, then the smallest id. Keeping the incoming
    // copy instead made an import delete a copy pulled from another device,
    // which that device keeps, and push the deletion (#102).
    bool hasAudio(Sentence sentence) =>
        sentence.audioUrl?.trim().isNotEmpty == true;
    final canonical = candidates.reduce((best, sentence) {
      final byAudio = (hasAudio(sentence) ? 1 : 0).compareTo(
        hasAudio(best) ? 1 : 0,
      );
      if (byAudio != 0) return byAudio > 0 ? sentence : best;
      return sentence.id.compareTo(best.id) < 0 ? sentence : best;
    });
    final audioUrl = candidates
        .map((sentence) => sentence.audioUrl)
        .firstWhere(
          (audio) => audio?.trim().isNotEmpty == true,
          orElse: () => null,
        );
    final notes = candidates
        .map((sentence) => sentence.notes)
        .firstWhere((notes) => notes.trim().isNotEmpty, orElse: () => '');
    final ttsText = candidates
        .map((sentence) => sentence.ttsText)
        .firstWhere(
          (tts) => tts?.trim().isNotEmpty == true,
          orElse: () => null,
        );
    canonical
      // The pool is plain text: the `**` marking belongs to each word.
      ..targetText = Sentence.stripEmphasis(incoming.targetText)
      ..translationText = Sentence.stripEmphasis(incoming.translationText)
      ..audioUrl = audioUrl
      ..ttsText = ttsText
      ..notes = notes
      // An edit decides. An import always brings the default (on), so it must
      // not switch a recording back on that was switched off.
      ..useAudio = _importSentenceSet == null
          ? incoming.useAudio
          : candidates.every((sentence) => sentence.useAudio)
      ..lessonId ??= incoming.lessonId;
    final known = _importSentenceSet;
    if (known != null) {
      if (known.add(canonical)) _sentences.add(canonical);
    } else if (!_sentences.any((sentence) => identical(sentence, canonical))) {
      _sentences.add(canonical);
    }

    final removedIds = {
      ...duplicates.map((sentence) => sentence.id),
      if (!identical(canonical, incoming)) incoming.id,
    }..remove(canonical.id);
    if (removedIds.isNotEmpty) {
      final merges = _mergedInto;
      if (merges != null) {
        for (final id in removedIds) {
          merges[id] = canonical.id;
        }
      }
      final redirect = {for (final id in removedIds) id: canonical.id};
      for (final vocab in _lessons.expand((lesson) => lesson.vocabularies)) {
        _redirectSentences(vocab, redirect);
      }
      _sentences.removeWhere((sentence) {
        final remove =
            !identical(sentence, canonical) && removedIds.contains(sentence.id);
        if (remove) known?.remove(sentence);
        return remove;
      });
    }
    bySignature?[signature] = [canonical];
    return canonical;
  }

  static List<T> _unique<T>(Iterable<T> values) {
    final seen = <T>{};
    return values.where(seen.add).toList();
  }

  Future<void> linkSentenceToVocab(VocabItem vocab, String sentenceId) async {
    if (!vocab.sentenceIds.contains(sentenceId)) {
      vocab.sentenceIds.add(sentenceId);
      await saveState();
    }
  }

  /// Adds example sentences an AI suggested in a chat about [vocab] to the
  /// word. A new one joins the Sentence Pool with
  /// [LessonAiPrompt.aiSentenceNote] after its notes; one already in the pool
  /// is the learner's, and that sentence is linked as it is. Each is linked
  /// to the word with the AI's `**` marking, or, when the AI marked nothing,
  /// one suggested from the word as the word editor does. Sentences the word
  /// already has are left as they are. Returns the sentences newly linked.
  Future<List<Sentence>> addSuggestedExamples(
    VocabItem vocab,
    List<ExampleSentence> examples,
  ) async {
    String? lessonId;
    for (final lesson in _lessons) {
      if (lesson.vocabularies.any((other) => identical(other, vocab))) {
        lessonId = lesson.id;
        break;
      }
    }
    final added = <Sentence>[];
    for (final (:sentence, :emphasis) in examples) {
      final canonical =
          findDuplicateSentence(sentence) ??
          _upsertSentence(
            Sentence(
              targetText: sentence.targetText,
              translationText: sentence.translationText,
              audioUrl: sentence.audioUrl,
              ttsText: sentence.ttsText,
              notes: LessonAiPrompt.withNote(
                sentence.notes,
                LessonAiPrompt.aiSentenceNote,
              ),
              lessonId: lessonId,
            ),
          );
      if (vocab.sentenceIds.contains(canonical.id)) continue;
      vocab.sentenceIds.add(canonical.id);
      final target = Sentence.hasEmphasis(emphasis.target)
          ? emphasis.target
          : Sentence.suggestEmphasis(
              canonical.targetText,
              vocab.targetWord,
              korean: true,
            );
      if (Sentence.hasEmphasis(target)) {
        vocab.sentenceEmphasis[canonical.id] = SentenceEmphasis(
          target: target,
          translation: Sentence.hasEmphasis(emphasis.target)
              ? emphasis.translation
              : Sentence.suggestEmphasis(
                  canonical.translationText,
                  vocab.translation,
                ),
        );
      }
      added.add(canonical);
    }
    await saveState();
    return added;
  }

  Future<void> unlinkSentenceFromVocab(
    VocabItem vocab,
    String sentenceId,
  ) async {
    if (vocab.sentenceIds.remove(sentenceId)) {
      await saveState();
    }
  }

  // Import YAML
  Future<Lesson> importYaml(
    String yamlText, {
    String? defaultTitle,
    String? defaultUnitTitle,
  }) async {
    final parsed = YamlParserService.parseLessonYaml(
      yamlText,
      defaultTitle: defaultTitle,
      defaultUnitTitle: defaultUnitTitle,
    );
    final before = _currentVocabIds();
    final lesson = _applyParsedLesson(
      parsed,
      existing: _importTarget(parsed.lesson).$1,
    );
    _linkSharedVocabProgress();
    await _followVocabIdChanges(before);
    await _saveImportedLessons();
    notifyListeners();
    return lesson;
  }

  /// Imports [parsedLessons] in order. A lesson at the same virtual path as
  /// one in its folder updates it. One that only shares its name (or, for a
  /// lesson saved without a file name, the older `Lesson N` match) is a
  /// [LessonNameClash]: [onClash] picks which lesson is kept, and without
  /// it the imported lesson overwrites the saved one.
  Future<List<Lesson>> importParsedLessons(
    List<YamlParseResult> parsedLessons, {
    void Function(int current, int total)? onProgress,
    Future<LessonClashChoice> Function(LessonNameClash clash)? onClash,
  }) async {
    final importedLessons = <Lesson>[];
    final sentenceIndex = <String, List<Sentence>>{};
    for (final sentence in _sentences) {
      sentenceIndex
          .putIfAbsent(_sentenceSignature(sentence), () => [])
          .add(sentence);
    }
    final vocabIndex = _newVocabProgressIndex();
    final idsBefore = _currentVocabIds();
    _importSentenceSet = HashSet<Sentence>.identity()..addAll(_sentences);
    try {
      for (var index = 0; index < parsedLessons.length; index++) {
        final parsed = parsedLessons[index];
        var (target, ask) = _importTarget(parsed.lesson);
        if (target != null && ask) {
          final clash = LessonNameClash(
            existing: target,
            incoming: parsed.lesson,
            // Keep both renames it only when the names are the same, not
            // for a clash by the older `Lesson <number>` rule.
            renamedTitle: _sameName(target, parsed.lesson)
                ? _unusedName(parsed.lesson, parsed.lesson.folderPath)
                : parsed.lesson.displayTitle,
          );
          final choice = onClash == null
              ? LessonClashChoice.keepIncoming
              : await onClash(clash);
          if (choice == LessonClashChoice.keepExisting) {
            // A lesson saved before file names were kept takes the file's,
            // so importing that file again finds it without asking.
            if (target.fileName == null) {
              target.fileName = parsed.lesson.fileName;
              target.fileFolder = parsed.lesson.fileFolder;
            }
            importedLessons.add(target);
            onProgress?.call(index + 1, parsedLessons.length);
            continue;
          }
          if (choice == LessonClashChoice.keepBoth) {
            if (_sameName(target, parsed.lesson)) {
              _rename(parsed.lesson, clash.renamedTitle);
            }
            target = null;
          }
        }
        importedLessons.add(
          _applyParsedLesson(
            parsed,
            existing: target,
            sentenceIndex: sentenceIndex,
            vocabIndex: vocabIndex,
          ),
        );
        onProgress?.call(index + 1, parsedLessons.length);
        await Future<void>.delayed(Duration.zero);
      }
    } finally {
      _importSentenceSet = null;
    }
    if (parsedLessons.isNotEmpty) {
      _linkSharedVocabProgress();
      await _followVocabIdChanges(idsBefore);
      await _saveImportedLessons();
      notifyListeners();
    }
    return importedLessons;
  }

  // Where the sentences merged away during one lesson import went. Two words
  // of the same file can share a sentence, and the second one's upsert replaces
  // the first's, so ids handed out earlier have to be followed.
  Map<String, String>? _mergedInto;

  String _followMerges(String id) {
    final merges = _mergedInto;
    if (merges == null) return id;
    var current = id;
    for (var hops = 0; merges.containsKey(current); hops++) {
      if (hops > merges.length) break;
      current = merges[current]!;
    }
    return current;
  }

  Lesson _applyParsedLesson(
    YamlParseResult parsed, {
    required Lesson? existing,
    Map<String, List<Sentence>>? sentenceIndex,
    Map<String, VocabItem>? vocabIndex,
  }) {
    _mergedInto = {};
    final shownBefore = activeLanguage;
    try {
      final lesson = _applyParsedLessonTracked(
        parsed,
        existing: existing,
        sentenceIndex: sentenceIndex,
        vocabIndex: vocabIndex,
      );
      // A new lesson in a language that is not the one shown would be
      // imported out of sight: show its language.
      final language = lesson.languageKey;
      if (existing == null && shownBefore != null && language != shownBefore) {
        _pickedLanguage = language;
        unawaited(StorageService.saveActiveLanguage(language));
      }
      return lesson;
    } finally {
      _mergedInto = null;
    }
  }

  Lesson _applyParsedLessonTracked(
    YamlParseResult parsed, {
    required Lesson? existing,
    Map<String, List<Sentence>>? sentenceIndex,
    Map<String, VocabItem>? vocabIndex,
  }) {
    final existingLesson = existing;
    if (existingLesson != null) {
      // Only the file a lesson came from can have had its entries edited:
      // another file that takes the lesson's name brings other words.
      final sameFile =
          _sameVirtualPath(existingLesson, parsed.lesson) ||
          _sameSourcePath(existingLesson, parsed.lesson);
      final sameFolder = isSameHierarchyPath(
        existingLesson.folderPath,
        parsed.lesson.folderPath,
      );
      // Keep a name given to tell it from another lesson in its folder.
      final nameTaken = _lessons.any(
        (other) =>
            !identical(other, existingLesson) &&
            isSameHierarchyPath(other.folderPath, parsed.lesson.folderPath) &&
            _sameName(other, parsed.lesson),
      );
      if (!nameTaken) {
        existingLesson.title = sameFolder
            ? parsed.lesson.title
            : parsed.lesson.displayTitle;
      }
      if (sameFolder) {
        existingLesson.unitTitle =
            parsed.lesson.unitTitle ?? existingLesson.unitTitle;
      }
      existingLesson.targetLanguage = parsed.lesson.targetLanguage;
      existingLesson.nativeLanguage = parsed.lesson.nativeLanguage;
      if (parsed.lesson.markdownContent.isNotEmpty) {
        existingLesson.markdownContent = parsed.lesson.markdownContent;
      }
      if (parsed.lesson.fileName != null) {
        existingLesson.fileName = parsed.lesson.fileName;
        existingLesson.fileFolder = parsed.lesson.fileFolder;
      }
      _mergeImportedLesson(
        existingLesson,
        parsed,
        sentenceIndex,
        edits: sameFile,
      );
    } else {
      if (vocabIndex == null) {
        _reuseExistingVocabProgress(
          parsed.lesson.vocabularies,
          parsed.lesson.id,
        );
      } else {
        _reuseVocabProgressFromIndex(
          parsed.lesson.vocabularies,
          vocabIndex,
          parsed.lesson.id,
        );
      }
      final sentenceIds = <String, String>{};
      for (final sentence in parsed.sentences) {
        sentenceIds[sentence.id] = _upsertSentence(
          sentence,
          bySignature: sentenceIndex,
        ).id;
      }
      sentenceIds.updateAll((_, id) => _followMerges(id));
      for (final vocab in parsed.lesson.vocabularies) {
        _redirectSentences(vocab, sentenceIds);
        vocab.shared.stampUnowned(parsed.lesson.id);
      }
      _lessons.add(parsed.lesson);
      _selectedLessonId = parsed.lesson.id;
    }
    return existingLesson ?? parsed.lesson;
  }

  Future<void> _saveImportedLessons() async {
    await StorageService.saveSentences(_sentences);
    await StorageService.saveLessons(_lessons);
  }

  /// The saved lesson [incoming] would update, and whether that has to be
  /// asked (see [importParsedLessons]).
  (Lesson?, bool) _importTarget(Lesson incoming) {
    final sourceMatches = _lessons
        .where((lesson) => _sameSourcePath(lesson, incoming))
        .toList();
    if (sourceMatches.length == 1) return (sourceMatches.single, false);

    final inFolder = _lessons
        .where(
          (lesson) =>
              isSameHierarchyPath(lesson.folderPath, incoming.folderPath),
        )
        .toList();
    for (final lesson in inFolder) {
      if (_sameVirtualPath(lesson, incoming)) return (lesson, false);
    }
    for (final lesson in inFolder) {
      if (_sameName(lesson, incoming) ||
          (lesson.fileName == null &&
              _lessonIdentity(lesson) == _lessonIdentity(incoming))) {
        return (lesson, true);
      }
    }
    return (null, false);
  }

  /// [map] with Korean syllables in its keys composed, as lesson names are
  /// ([Lesson]), so the order and expansion saved for a folder whose name a
  /// Mac stored as separate jamo still find it.
  static Map<String, V> _composedKeys<V>(Map<String, V> map) => {
    for (final entry in map.entries) composeHangul(entry.key): entry.value,
  };

  static bool _sameName(Lesson a, Lesson b) =>
      a.displayTitle.trim().toLowerCase() ==
      b.displayTitle.trim().toLowerCase();

  static bool _sameVirtualPath(Lesson a, Lesson b) =>
      isSameHierarchyPath(a.folderPath, b.folderPath) &&
      a.virtualFileName.toLowerCase() == b.virtualFileName.toLowerCase();

  static bool _sameSourcePath(Lesson a, Lesson b) =>
      a.fileName != null &&
      b.fileName != null &&
      a.fileName!.toLowerCase() == b.fileName!.toLowerCase() &&
      (a.fileFolder ?? '').toLowerCase() == (b.fileFolder ?? '').toLowerCase();

  /// [lesson]'s name with the first ` (2)`, ` (3)`, … suffix no other lesson
  /// in [folder] has.
  String _unusedName(Lesson lesson, List<String> folder) {
    final taken = {
      for (final other in _lessons)
        if (!identical(other, lesson) &&
            isSameHierarchyPath(other.folderPath, folder))
          other.displayTitle.trim().toLowerCase(),
    };
    final base = lesson.displayTitle.trim();
    for (var n = 2; ; n++) {
      final name = '$base ($n)';
      if (!taken.contains(name.toLowerCase())) return name;
    }
  }

  static void _rename(Lesson lesson, String name) {
    final parts = splitHierarchyPath(lesson.title);
    lesson.title = parts.length <= 1
        ? name
        : joinHierarchyPath([...parts.take(parts.length - 1), name]);
  }

  /// Whether a saved lesson is the one [file] would update when imported
  /// (a lesson file without its vocabulary, from
  /// [YamlParserService.lessonFileInfo]). A file whose lesson was deleted
  /// has none, and is to be imported again even if it has not changed.
  bool hasLessonForFile(Lesson file) => _importTarget(file).$1 != null;

  /// What [markdown], the text of a lesson file, needs for its vocabulary
  /// to say what the app does, or null when it needs nothing or no saved
  /// lesson is at the file's virtual path. [file] is the file without its
  /// vocabulary ([YamlParserService.lessonFileInfo]).
  ///
  /// Throws a [FormatException] when the file cannot be updated safely.
  LessonFileUpdate? planFileUpdate(String markdown, Lesson file) {
    final (lesson, ask) = _importTarget(file);
    if (lesson == null || ask) return null;
    return LessonFileUpdate.plan(markdown, lesson, {
      for (final sentence in _sentences) sentence.id: sentence,
    });
  }

  /// Records that the files of [written] now say what the app does, so the
  /// next import of them takes only what is edited in them from then on.
  Future<void> adoptFileUpdates(Iterable<LessonFileUpdate> written) async {
    var changed = false;
    for (final update in written) {
      for (final entry in update.sources.entries) {
        entry.key.source = entry.value;
        changed = true;
      }
    }
    if (changed) await StorageService.saveLessons(_lessons);
  }

  /// Gives saved lessons the real file paths of [files] (lessons without
  /// vocabulary, from [YamlParserService.lessonFileInfo]): files a folder or
  /// ZIP import skipped because they had not changed, so a lesson imported
  /// before file paths were kept still follows its file. A lesson in the
  /// same app folder with the same file name takes the file's folder names;
  /// one with no file name takes both, when it is the only lesson in that
  /// folder that the file matches the way an import would (by name, or the
  /// older `Lesson <number>` rule). Returns how many lessons changed.
  Future<int> adoptFilePaths(List<Lesson> files) async {
    var changed = 0;
    for (final file in files) {
      final name = file.fileName?.toLowerCase();
      if (name == null) continue;
      final inFolder = _lessons
          .where(
            (lesson) => isSameHierarchyPath(lesson.folderPath, file.folderPath),
          )
          .toList();
      final same = inFolder
          .where((lesson) => lesson.fileName?.toLowerCase() == name)
          .toList();
      if (same.length == 1) {
        if (same.single.fileFolder != file.fileFolder) {
          same.single.fileFolder = file.fileFolder;
          changed++;
        }
        continue;
      }
      if (same.isNotEmpty) continue;
      final matches = inFolder
          .where(
            (lesson) =>
                lesson.fileName == null &&
                (_sameName(lesson, file) ||
                    _lessonIdentity(lesson) == _lessonIdentity(file)),
          )
          .toList();
      if (matches.length != 1) continue;
      matches.single
        ..fileName = file.fileName
        ..fileFolder = file.fileFolder;
      changed++;
    }
    if (changed > 0) await saveState();
    return changed;
  }

  /// Saved lessons that share a name with an earlier lesson in their folder
  /// (each against the first one), for the person to sort out. Lessons at
  /// the same virtual path are merged without asking when loaded or synced.
  List<LessonNameClash> get lessonNameClashes {
    final byName = <String, Lesson>{};
    final byPath = <String, Lesson>{};
    final clashes = <LessonNameClash>[];
    for (final lesson in _lessons) {
      final nameKey =
          '${hierarchyFolderKey(lesson.folderPath)}'
          '\n${lesson.displayTitle.trim().toLowerCase()}';
      final pathKey = _pathKey(lesson);
      final earlier = byName[nameKey] ?? byPath[pathKey];
      if (earlier == null) {
        byName[nameKey] = lesson;
        byPath[pathKey] = lesson;
        continue;
      }
      final sameName = _sameName(earlier, lesson);
      clashes.add(
        LessonNameClash(
          existing: earlier,
          incoming: lesson,
          renamedTitle: sameName
              ? _unusedName(lesson, lesson.folderPath)
              : lesson.displayTitle,
          sameFile: _pathKey(earlier) == pathKey,
        ),
      );
    }
    return clashes;
  }

  /// The app folders and file name of [lesson], ignoring case: two lessons
  /// with the same one come from the same file ([_sameVirtualPath]).
  static String _pathKey(Lesson lesson) => [
    for (final part in [...lesson.folderPath, lesson.virtualFileName])
      part.toLowerCase(),
  ].join('/');

  /// Whether merging [a] and [b] keeps all their text: the same text, or
  /// one of them has none.
  static bool _textFits(Lesson a, Lesson b) {
    final textA = a.markdownContent.trim();
    final textB = b.markdownContent.trim();
    return textA.isEmpty || textB.isEmpty || textA == textB;
  }

  /// Settles a clash from [lessonNameClashes]: the lesson [choice] keeps
  /// overwrites the other (which goes, after giving the kept one any words
  /// it lacks, so no study progress is lost), or both stay: the later one
  /// is renamed if the names match, and lets go of the file if they share
  /// one.
  Future<void> resolveLessonNameClash(
    LessonNameClash clash,
    LessonClashChoice choice,
  ) async {
    var chatsMoved = false;
    switch (choice) {
      case LessonClashChoice.keepExisting:
        chatsMoved = _absorbLesson(clash.existing, clash.incoming);
      case LessonClashChoice.keepIncoming:
        chatsMoved = _absorbLesson(clash.incoming, clash.existing);
      case LessonClashChoice.keepBoth:
        // Two lessons from one file: the first keeps it, so the next import
        // of the file updates that one, and the second goes back to a
        // virtual path from its title.
        if (clash.sameFile) {
          clash.incoming
            ..fileName = null
            ..fileFolder = null;
        }
        if (_sameName(clash.existing, clash.incoming)) {
          _rename(
            clash.incoming,
            _unusedName(clash.incoming, clash.incoming.folderPath),
          );
        }
    }
    if (chatsMoved) await StorageService.saveAiDiscussions(_aiDiscussions);
    await saveState();
  }

  /// Moves [other]'s words that [primary] lacks into [primary], joins
  /// [other]'s AI chat into [primary]'s (oldest message first), then removes
  /// [other]. Returns whether a chat moved.
  bool _absorbLesson(Lesson primary, Lesson other) {
    if (identical(primary, other)) return false;
    final ids = {for (final vocab in primary.vocabularies) vocab.id};
    for (final vocab in other.vocabularies) {
      if (ids.add(vocab.id)) primary.vocabularies.add(vocab);
    }
    for (final sentence in _sentences) {
      if (sentence.lessonId == other.id) sentence.lessonId = primary.id;
    }
    if (primary.markdownContent.trim().isEmpty) {
      primary.markdownContent = other.markdownContent;
    }
    if (primary.fileName == null) {
      primary.fileName = other.fileName;
      primary.fileFolder = other.fileFolder;
    }
    _lessons.removeWhere((lesson) => identical(lesson, other));
    if (_selectedLessonId == other.id) _selectedLessonId = primary.id;
    if (primary.id == other.id) return false;
    final chat = _aiDiscussions.remove(LessonAiPrompt.discussionId(other.id));
    if (chat == null) return false;
    _joinAiDiscussion(LessonAiPrompt.discussionId(primary.id), chat);
    return true;
  }

  /// Merges saved lessons at the same virtual path (say, one file imported
  /// on two devices before they synced) into the first of them, with their
  /// AI chats, when that keeps all their text: the same text, or one has
  /// none. Pairs whose texts differ are left for [lessonNameClashes]. Returns whether any lessons were merged, and whether any
  /// chats moved.
  ({bool lessons, bool chats}) _mergeSameVirtualPathLessons() {
    final first = <String, Lesson>{};
    final merges = <(Lesson, Lesson)>[];
    for (final lesson in _lessons) {
      // As [_sameVirtualPath]: the app folders and the file name, so a
      // lesson saved before original folder names were kept compares the
      // same as one imported since.
      final key = _pathKey(lesson);
      final earlier = first[key];
      if (earlier == null) {
        first[key] = lesson;
      } else if (_textFits(earlier, lesson)) {
        merges.add((earlier, lesson));
      }
      // Otherwise merging would drop one lesson's text: the pair is left
      // for the person to sort out ([lessonNameClashes]), where the
      // warning says so.
    }
    var chats = false;
    for (final (primary, other) in merges) {
      if (_absorbLesson(primary, other)) chats = true;
    }
    return (lessons: merges.isNotEmpty, chats: chats);
  }

  static String _lessonIdentity(Lesson lesson) {
    final lessonNumber = RegExp(
      r'^(Lesson\s+\d+)',
      caseSensitive: false,
    ).firstMatch(lesson.displayTitle.trim());
    return lessonNumber?.group(1)?.toLowerCase() ??
        lesson.displayTitle.trim().toLowerCase();
  }

  void _mergeImportedLesson(
    Lesson lesson,
    YamlParseResult parsed,
    Map<String, List<Sentence>>? sentenceIndex, {
    required bool edits,
  }) {
    final lessonSentenceIds = lesson.vocabularies
        .expand((vocab) => vocab.sentenceIds)
        .toSet();
    final oldSentences = _sentences
        .where(
          (sentence) =>
              sentence.lessonId == lesson.id ||
              lessonSentenceIds.contains(sentence.id),
        )
        .toList();
    final sentencesByContent = <String, List<Sentence>>{};
    for (final sentence in oldSentences) {
      sentencesByContent
          .putIfAbsent(_sentenceSignature(sentence), () => [])
          .add(sentence);
    }

    final importedSentenceIds = <String, String>{};
    final importedSentenceBySignature = <String, String>{};
    // Sentences this import put in the pool, to take out again if no word
    // ends up listing them (see [_mergeFileWord]).
    final addedSentences = <Sentence>[];
    for (final sentence in parsed.sentences) {
      final signature = _sentenceSignature(sentence);
      final previousImport = importedSentenceBySignature[signature];
      if (previousImport != null) {
        final canonical = _upsertSentence(sentence, bySignature: sentenceIndex);
        importedSentenceIds[sentence.id] = canonical.id;
        continue;
      }
      final matches = sentencesByContent[signature];
      final existingSentence = matches == null || matches.isEmpty
          ? null
          : matches.removeAt(0);
      if (existingSentence == null) {
        sentence.lessonId = lesson.id;
        final canonical = _upsertSentence(sentence, bySignature: sentenceIndex);
        importedSentenceIds[sentence.id] = canonical.id;
        if (identical(canonical, sentence)) addedSentences.add(sentence);
      } else {
        existingSentence
          ..targetText = sentence.targetText
          ..translationText = sentence.translationText
          ..audioUrl = existingSentence.audioUrl?.trim().isNotEmpty == true
              ? existingSentence.audioUrl
              : sentence.audioUrl
          ..ttsText = sentence.ttsText?.trim().isNotEmpty == true
              ? sentence.ttsText
              : existingSentence.ttsText
          ..notes = sentence.notes.trim().isNotEmpty
              ? sentence.notes
              : existingSentence.notes
          ..lessonId = lesson.id;
        importedSentenceIds[sentence.id] = _upsertSentence(
          existingSentence,
          bySignature: sentenceIndex,
        ).id;
      }
      importedSentenceBySignature[signature] =
          importedSentenceIds[sentence.id]!;
    }
    importedSentenceIds.updateAll((_, id) => _followMerges(id));

    final vocabById = <String, List<VocabItem>>{};
    final vocabByMeaning = <String, List<VocabItem>>{};
    for (final vocab in lesson.vocabularies) {
      _addVocabToIndexes(vocab, vocabById, vocabByMeaning);
    }
    for (final vocab
        in _lessons
            .where((candidate) => candidate.id != lesson.id)
            .expand((candidate) => candidate.vocabularies)) {
      _addVocabToIndexes(vocab, vocabById, vocabByMeaning);
    }
    // The saved word each entry is when its id and its meaning no longer
    // say so: a word edited in the app, or an entry corrected in the file.
    final fileMatches = LessonWordMatch.match(
      parsed.lesson.vocabularies,
      lesson.vocabularies,
      edits: edits,
    );
    final sentenceById = {
      for (final sentence in _sentences) sentence.id: sentence,
    };
    final matchedLessonVocabularies = <VocabItem>{};
    final newVocabularies = <VocabItem>[];
    for (final importedVocab in parsed.lesson.vocabularies) {
      _redirectSentences(importedVocab, importedSentenceIds);

      var previousVocab = _findExistingVocabInIndexes(
        importedVocab,
        vocabById,
        vocabByMeaning,
        matchedLessonVocabularies,
      );
      var lessonMatch =
          previousVocab != null && lesson.vocabularies.contains(previousVocab)
          ? previousVocab
          : null;
      var editedInFile = false;
      final fileMatch = fileMatches[importedVocab];
      if (lessonMatch == null &&
          fileMatch != null &&
          (fileMatch.kind == WordMatchKind.source ||
              fileMatch.kind == WordMatchKind.edited) &&
          !matchedLessonVocabularies.contains(fileMatch.word)) {
        lessonMatch = previousVocab = fileMatch.word;
        editedInFile = fileMatch.kind == WordMatchKind.edited;
      }
      if (lessonMatch == null) {
        if (previousVocab != null) {
          _reuseProgress(importedVocab, previousVocab, lessonId: lesson.id);
        }
        newVocabularies.add(importedVocab);
        _addVocabToIndexes(importedVocab, vocabById, vocabByMeaning);
        continue;
      }

      matchedLessonVocabularies.add(lessonMatch);
      _removeVocabFromIndexes(lessonMatch, vocabById, vocabByMeaning);
      // An id made from the word and its translation that is still the
      // saved word's says the entry reads as it did when it was imported,
      // even if sharing progress with another lesson marked it explicit.
      final unchangedInFile =
          !editedInFile &&
          !importedVocab.idIsExplicit &&
          importedVocab.id == lessonMatch.id;
      lessonMatch
        ..id = lessonMatch.idIsExplicit ? lessonMatch.id : importedVocab.id
        ..idIsExplicit = lessonMatch.idIsExplicit || importedVocab.idIsExplicit;
      _mergeFileWord(
        lessonMatch,
        importedVocab,
        sentenceById,
        unchangedInFile: unchangedInFile,
      );
      lessonMatch.shared
        ..mergeImport(
          SharedVocab.audioField,
          importedVocab.audioUrl,
          lessonId: lesson.id,
        )
        ..mergeImport(
          SharedVocab.notesField,
          importedVocab.notes,
          lessonId: lesson.id,
        )
        ..mergeImport(
          SharedVocab.disambiguationField,
          importedVocab.disambiguation,
          lessonId: lesson.id,
        )
        ..mergeImport(
          SharedVocab.ttsField,
          importedVocab.ttsText,
          lessonId: lesson.id,
        );
      _addVocabToIndexes(lessonMatch, vocabById, vocabByMeaning);
      if (previousVocab != null && !identical(previousVocab, lessonMatch)) {
        _reuseProgress(lessonMatch, previousVocab, lessonId: lesson.id);
      }
    }
    lesson.vocabularies = [...lesson.vocabularies, ...newVocabularies];
    _dropUnusedSentences(addedSentences, lesson, sentenceIndex);
  }

  /// Brings [word], a saved word, up to date with [file], the entry of its
  /// lesson file, taking from the file only what changed there since the
  /// file was last imported ([VocabItem.source]). What was edited in the
  /// app stays, and so does the app's edit when both changed.
  ///
  /// A word saved before the file's values were kept has nothing to compare
  /// with. Its word and translation stay when [unchangedInFile] says the
  /// entry still reads as it did; otherwise they follow the file, as they
  /// used to. Its examples are kept, and the file's are added to them.
  void _mergeFileWord(
    VocabItem word,
    VocabItem file,
    Map<String, Sentence> sentenceById, {
    required bool unchangedInFile,
  }) {
    final base = word.source;
    String merged(String? was, String theirs, String ours) {
      if (was == null) return unchangedInFile ? ours : theirs;
      if (theirs == was) return ours;
      return ours == was ? theirs : ours;
    }

    word
      ..targetWord = merged(base?.targetWord, file.targetWord, word.targetWord)
      ..translation = merged(
        base?.translation,
        file.translation,
        word.translation,
      );
    // A reading or form has no "as edited" to fall back on: a word saved
    // before these were kept had none, so what the file says now is new.
    String form(String was, String theirs, String ours) =>
        theirs == was || ours != was ? ours : theirs;
    word
      ..reading = form(base?.reading ?? '', file.reading, word.reading)
      ..simplified = form(
        base?.simplified ?? '',
        file.simplified,
        word.simplified,
      )
      ..traditional = form(
        base?.traditional ?? '',
        file.traditional,
        word.traditional,
      )
      ..hanja = form(base?.hanja ?? '', file.hanja, word.hanja);
    if (base == null || !_sameNames(base.sectionPath, file.sectionPath)) {
      word
        ..pos = file.pos
        ..sectionPath = file.sectionPath;
    }

    String? keyOf(VocabItem owner, String id) {
      final sentence = sentenceById[id];
      return sentence == null ? null : owner.exampleKey(sentence);
    }

    final fileKeys = {for (final id in file.sentenceIds) id: keyOf(file, id)};
    final was = base?.examples.toSet();
    final now = fileKeys.values.whereType<String>().toSet();
    if (was == null || !(was.length == now.length && was.containsAll(now))) {
      final ids = [...word.sentenceIds];
      final emphasis = {...word.sentenceEmphasis};
      if (was != null) {
        // Gone from the file, and still as the file had it here.
        ids.removeWhere((id) {
          final key = keyOf(word, id);
          final gone =
              key != null &&
              was.contains(key) &&
              !now.contains(key) &&
              !file.sentenceIds.contains(id);
          if (gone) emphasis.remove(id);
          return gone;
        });
      }
      for (final id in file.sentenceIds) {
        final key = fileKeys[id];
        final isNew = was == null || key == null || !was.contains(key);
        if (!isNew) continue;
        final mark = file.sentenceEmphasis[id];
        if (!ids.contains(id)) {
          ids.add(id);
          if (mark != null) emphasis[id] = mark;
        } else if (was != null &&
            mark != null &&
            was.contains(keyOf(word, id))) {
          // The same sentence, marked another way in the file.
          emphasis[id] = mark;
        }
      }
      word
        ..sentenceIds = ids
        ..sentenceEmphasis = emphasis;
    }
    // Vocabulary added to a lesson by hand is not what its file says.
    if (file.source != null) word.source = file.source;
  }

  static bool _sameNames(List<String> first, List<String> second) {
    if (first.length != second.length) return false;
    for (var index = 0; index < first.length; index++) {
      if (first[index] != second[index]) return false;
    }
    return true;
  }

  /// Takes [added] sentences out of the pool again when no word lists them:
  /// examples the file still has of a word whose examples were edited in the
  /// app, which would otherwise pile up in the pool at every import.
  void _dropUnusedSentences(
    List<Sentence> added,
    Lesson lesson,
    Map<String, List<Sentence>>? sentenceIndex,
  ) {
    if (added.isEmpty) return;
    final listed = {
      for (final vocab in lesson.vocabularies) ...vocab.sentenceIds,
    };
    final unused = added
        .where((sentence) => !listed.contains(_followMerges(sentence.id)))
        .toList();
    if (unused.isEmpty) return;
    final listedAnywhere = {
      for (final vocab in _lessons.expand((lesson) => lesson.vocabularies))
        ...vocab.sentenceIds,
    };
    for (final sentence in unused) {
      if (listedAnywhere.contains(sentence.id)) continue;
      // Merged into another sentence since: that one is not this import's.
      if (!_sentences.any((other) => identical(other, sentence))) continue;
      _sentences.removeWhere((other) => identical(other, sentence));
      _importSentenceSet?.remove(sentence);
      final sameText = sentenceIndex?[_sentenceSignature(sentence)];
      sameText?.removeWhere((other) => identical(other, sentence));
      if (sameText != null && sameText.isEmpty) {
        sentenceIndex!.remove(_sentenceSignature(sentence));
      }
    }
  }

  static VocabItem? _findExistingVocabInIndexes(
    VocabItem imported,
    Map<String, List<VocabItem>> byId,
    Map<String, List<VocabItem>> byMeaning,
    Set<VocabItem> matchedLessonVocabularies,
  ) {
    List<VocabItem> unmatched(List<VocabItem>? values) =>
        values
            ?.where((vocab) => !matchedLessonVocabularies.contains(vocab))
            .toList() ??
        const [];

    final matchingId = unmatched(byId[imported.id]);
    if (matchingId.length == 1) return matchingId.single;
    if (matchingId.isNotEmpty) {
      for (final vocab in matchingId) {
        if (_sameSectionPath(vocab, imported)) return vocab;
      }
      return matchingId.first;
    }
    if (imported.idIsExplicit) return null;

    final exactMeaning = unmatched(byMeaning[_vocabMeaningIdentity(imported)]);
    if (exactMeaning.isNotEmpty) return exactMeaning.first;

    return null;
  }

  static void _addVocabToIndexes(
    VocabItem vocab,
    Map<String, List<VocabItem>> byId,
    Map<String, List<VocabItem>> byMeaning,
  ) {
    byId.putIfAbsent(vocab.id, () => []).add(vocab);
    byMeaning.putIfAbsent(_vocabMeaningIdentity(vocab), () => []).add(vocab);
  }

  static void _removeVocabFromIndexes(
    VocabItem vocab,
    Map<String, List<VocabItem>> byId,
    Map<String, List<VocabItem>> byMeaning,
  ) {
    final idMatches = byId[vocab.id]!;
    idMatches.removeWhere((candidate) => identical(candidate, vocab));
    if (idMatches.isEmpty) byId.remove(vocab.id);

    final meaningIdentity = _vocabMeaningIdentity(vocab);
    final meaningMatches = byMeaning[meaningIdentity]!;
    meaningMatches.removeWhere((candidate) => identical(candidate, vocab));
    if (meaningMatches.isEmpty) byMeaning.remove(meaningIdentity);
  }

  VocabItem? _findExistingVocab(
    VocabItem imported,
    Iterable<VocabItem> candidates,
  ) {
    final vocabularies = candidates.toList();
    final matchingId = vocabularies
        .where((vocab) => vocab.id == imported.id)
        .toList();
    if (matchingId.length == 1) return matchingId.single;
    if (matchingId.isNotEmpty) {
      for (final vocab in matchingId) {
        if (_sameSectionPath(vocab, imported)) return vocab;
      }
      return matchingId.first;
    }
    if (imported.idIsExplicit) return null;

    for (final vocab in vocabularies) {
      if (_sameVocabMeaning(vocab, imported)) return vocab;
    }
    return null;
  }

  static bool _sameSectionPath(VocabItem first, VocabItem second) {
    final firstPath = first.effectiveSectionPath;
    final secondPath = second.effectiveSectionPath;
    if (firstPath.length != secondPath.length) return false;
    for (var index = 0; index < firstPath.length; index++) {
      if (firstPath[index].toLowerCase() != secondPath[index].toLowerCase()) {
        return false;
      }
    }
    return true;
  }

  static bool _sameVocabMeaning(VocabItem first, VocabItem second) =>
      _vocabMeaningIdentity(first) == _vocabMeaningIdentity(second);

  static String _vocabMeaningIdentity(VocabItem vocab) =>
      '${_normalizeVocabWord(vocab.targetWord)}\u0000'
      '${_normalizeVocabWord(vocab.translation)}';

  static String _normalizeVocabWord(String word) =>
      word.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  void _reuseExistingVocabProgress(List<VocabItem> imported, String lessonId) {
    _reuseVocabProgressFromIndex(imported, _newVocabProgressIndex(), lessonId);
  }

  Map<String, VocabItem> _newVocabProgressIndex() {
    final index = <String, VocabItem>{};
    for (final vocab in _lessons.expand((lesson) => lesson.vocabularies)) {
      index.putIfAbsent(_progressIdentity(vocab), () => vocab);
      index.putIfAbsent('text:${_vocabMeaningIdentity(vocab)}', () => vocab);
    }
    return index;
  }

  void _reuseVocabProgressFromIndex(
    List<VocabItem> imported,
    Map<String, VocabItem> index,
    String lessonId,
  ) {
    for (final vocab in imported) {
      final previous =
          index[_progressIdentity(vocab)] ??
          (vocab.idIsExplicit
              ? null
              : index['text:${_vocabMeaningIdentity(vocab)}']);
      if (previous != null) _reuseProgress(vocab, previous, lessonId: lessonId);
      index.putIfAbsent(_progressIdentity(vocab), () => vocab);
      index.putIfAbsent('text:${_vocabMeaningIdentity(vocab)}', () => vocab);
    }
  }

  void _linkSharedVocabProgress() {
    final canonical = <String, VocabItem>{};
    for (final vocab in _lessons.expand((lesson) => lesson.vocabularies)) {
      final shared = canonical[vocab.id];
      if (shared == null) {
        canonical[vocab.id] = vocab;
      } else if (!identical(shared, vocab)) {
        _reuseProgress(vocab, shared);
      }
    }
  }

  static String _progressIdentity(VocabItem vocab) => vocab.idIsExplicit
      ? 'id:${vocab.id}'
      : '${_normalizeVocabWord(vocab.targetWord)}\u0000'
            '${_normalizeVocabWord(vocab.translation)}';

  static void _reuseProgress(
    VocabItem target,
    VocabItem source, {
    String? lessonId,
  }) {
    if (!identical(target.shared, source.shared)) {
      for (final field in SharedVocab.detailFields) {
        source.shared.mergeImport(
          field,
          target.shared.valueOf(field),
          lessonId: lessonId,
        );
      }
    }
    target
      ..id =
          target.idIsExplicit ||
              (target.id.startsWith('auto-') && !source.idIsExplicit)
          ? target.id
          : source.id
      ..idIsExplicit = target.idIsExplicit || source.idIsExplicit
      ..shared = source.shared;
  }

  /// Whether the Sentence Pool has a sentence that importing [sentence]
  /// would merge with: the same text and translation, apart from emphasis,
  /// case and spacing.
  bool hasSentenceLike(Sentence sentence) {
    final signature = _sentenceSignature(sentence);
    return _sentences.any((s) => _sentenceSignature(s) == signature);
  }

  static String _sentenceSignature(Sentence sentence) => sentence.signature;

  List<VocabItem> getDuplicateFrontVocabularies(
    VocabItem vocab,
    CardDirection direction,
  ) {
    final prompt = direction == CardDirection.targetToNative
        ? vocab.targetWord
        : vocab.translation;
    final normalizedPrompt = _normalizeVocabWord(prompt);
    if (normalizedPrompt.isEmpty) return [];

    return _lessons.expand((lesson) => lesson.vocabularies).where((candidate) {
      if (identical(candidate, vocab) ||
          candidate.id == vocab.id ||
          _normalizeVocabWord(
                direction == CardDirection.targetToNative
                    ? candidate.targetWord
                    : candidate.translation,
              ) !=
              normalizedPrompt) {
        return false;
      }
      return direction == CardDirection.targetToNative
          ? candidate.cardTargetToNative.isActive
          : candidate.cardNativeToTarget.isActive;
    }).toList();
  }

  /// Suspends [card], taking it out of reviews with its progress kept, or
  /// unsuspends it.
  Future<void> setCardSuspended(SrsCard card, bool suspended) async {
    if (card.isSuspended == suspended) return;
    card.isSuspended = suspended;
    notifyListeners(); // Screens update before the save finishes.
    await saveState();
  }

  // Toggle card directions
  Future<void> toggleCardDirection(
    VocabItem vocab,
    CardDirection direction,
  ) async {
    if (direction == CardDirection.targetToNative) {
      vocab.cardTargetToNative.isEnabled = !vocab.cardTargetToNative.isEnabled;
    } else {
      vocab.cardNativeToTarget.isEnabled = !vocab.cardNativeToTarget.isEnabled;
    }
    await saveState();
  }

  /// Re-points [vocab] after its id was edited. Call BEFORE writing detail or
  /// card edits, so they land on the right SharedVocab.
  void rebindVocabId(VocabItem vocab, String? previousId) {
    if (previousId == null || previousId == vocab.id) return;
    VocabItem? sibling;
    for (final c in _lessons.expand((l) => l.vocabularies)) {
      if (c.id == vocab.id && !identical(c, vocab)) {
        sibling = c;
        break;
      }
    }
    vocab.shared = sibling?.shared ?? vocab.shared.detachedCopy();
  }

  // Update vocabulary fields
  Future<void> updateVocab(VocabItem vocab, {String? previousId}) async {
    final idsBefore = _currentVocabIds();
    if (previousId != null) idsBefore[vocab] = previousId;
    final existing = _findExistingVocab(
      vocab,
      _lessons
          .expand((lesson) => lesson.vocabularies)
          .where((candidate) => !identical(candidate, vocab)),
    );
    if (existing != null) {
      String? lessonId;
      for (final l in _lessons) {
        if (l.vocabularies.contains(vocab)) {
          lessonId = l.id;
          break;
        }
      }
      _reuseProgress(vocab, existing, lessonId: lessonId);
    } else {
      _linkSharedVocabProgress();
    }
    await _followVocabIdChanges(idsBefore);
    await saveState();
  }

  // Add vocabulary to a lesson
  Future<void> addVocabToLesson(String lessonId, VocabItem vocab) async {
    final lesson = _lessons.firstWhere((l) => l.id == lessonId);
    final existing = _findExistingVocab(
      vocab,
      _lessons.expand((candidate) => candidate.vocabularies),
    );
    if (existing != null) _reuseProgress(vocab, existing, lessonId: lessonId);
    lesson.vocabularies.add(vocab);
    await saveState();
  }

  // ---------------------------------------------------------------- merging

  /// Every distinct word, with the lessons it is in. Only the words of
  /// [activeLanguage]: the same characters can be another word in another
  /// language, so words are never listed, compared or merged across
  /// languages.
  List<VocabGroup> get vocabGroups {
    final byId = <String, VocabGroup>{};
    for (final lesson in activeLessons) {
      for (final vocab in lesson.vocabularies) {
        final group = byId.putIfAbsent(
          vocab.id,
          () => VocabGroup(
            id: vocab.id,
            entry: vocab,
            reviews:
                vocab.cardTargetToNative.repetitions +
                vocab.cardNativeToTarget.repetitions,
          ),
        );
        if (!group.lessonTitles.contains(lesson.displayTitle)) {
          group.lessonTitles.add(lesson.displayTitle);
        }
      }
    }
    return byId.values.toList();
  }

  /// Makes every vocab in [absorbedIds] part of [survivorId]. Returns null when
  /// there was nothing to merge.
  Future<VocabMergeRecord?> mergeVocab({
    required String survivorId,
    required Iterable<String> absorbedIds,
    String source = 'manual',
    String reason = '',
  }) async {
    final absorbed = absorbedIds.where((id) => id != survivorId).toSet();
    if (absorbed.isEmpty) return null;
    final entries = [
      for (final lesson in _lessons)
        for (final vocab in lesson.vocabularies) MapEntry(lesson, vocab),
    ];
    final survivor = entries
        .map((e) => e.value)
        .where((v) => v.id == survivorId)
        .firstOrNull;
    if (survivor == null) {
      throw ArgumentError.value(
        survivorId,
        'survivorId',
        'Unknown vocabulary.',
      );
    }

    final snapshots = [
      for (final e in entries)
        if (absorbed.contains(e.value.id))
          MergedEntrySnapshot(
            lessonId: e.key.id,
            targetWord: e.value.targetWord,
            translation: e.value.translation,
            sectionPath: List.of(e.value.effectiveSectionPath),
            previousId: e.value.id,
            previousIdIsExplicit: e.value.idIsExplicit,
            previousShared: e.value.shared.toJson(),
          ),
    ];
    if (snapshots.isEmpty) return null;

    final shared = survivor.shared;
    final survivorBefore = shared.toJson();
    final folded = <SharedVocab>{};
    final labels = <String>{};
    for (final e in entries) {
      final entry = e.value;
      if (!absorbed.contains(entry.id)) continue;
      labels.add('${entry.targetWord} — ${entry.translation}');
      if (folded.add(entry.shared)) {
        for (final field in SharedVocab.detailFields) {
          shared.mergeImport(field, entry.shared.valueOf(field));
        }
      }
      entry
        ..id = survivor.id
        ..idIsExplicit = true
        ..shared = shared;
    }

    if (_moveAiDiscussions(absorbed, survivor.id)) {
      await StorageService.saveAiDiscussions(_aiDiscussions);
    }

    final record = VocabMergeRecord(
      id: const Uuid().v4(),
      createdAt: DateTime.now(),
      survivorId: survivor.id,
      label:
          '${labels.join('; ')} → ${survivor.targetWord} — ${survivor.translation}',
      source: source,
      reason: reason,
      survivorBefore: survivorBefore,
      survivorAfter: shared.toJson(),
      entries: snapshots,
    );
    _mergeHistory = [record, ..._mergeHistory].take(_maxMergeHistory).toList();
    await StorageService.saveMergeHistory(_mergeHistory);
    await saveState();
    return record;
  }

  /// Undo is last-in-first-out: only the newest record can be undone.
  Future<VocabMergeUndoResult> undoMerge(String recordId) async {
    final index = _mergeHistory.indexWhere((r) => r.id == recordId);
    if (index < 0) return const VocabMergeUndoResult(restored: 0, missing: 0);
    if (index != 0) throw StateError('Undo the newer merges first.');
    final record = _mergeHistory[index];

    final restoredShared = <String, SharedVocab>{};
    final unmatched = [...record.entries];
    var restored = 0;
    for (final lesson in _lessons) {
      for (final entry in lesson.vocabularies) {
        if (entry.id != record.survivorId) continue;
        final i = unmatched.indexWhere((s) => s.matches(lesson.id, entry));
        if (i < 0) continue;
        final snapshot = unmatched.removeAt(i);
        entry
          ..id = snapshot.previousId
          ..idIsExplicit = snapshot.previousIdIsExplicit
          ..shared = restoredShared.putIfAbsent(
            snapshot.previousId,
            () => SharedVocab.fromJson(snapshot.previousShared),
          );
        restored++;
      }
    }

    // Put the survivor's details back, but only fields nobody edited since.
    final survivor = _lessons
        .expand((l) => l.vocabularies)
        .where((v) => v.id == record.survivorId)
        .firstOrNull;
    if (survivor != null) {
      final before = SharedVocab.fromJson(record.survivorBefore);
      final after = SharedVocab.fromJson(record.survivorAfter);
      for (final field in SharedVocab.detailFields) {
        if (survivor.shared.valueOf(field) == after.valueOf(field)) {
          survivor.shared.restoreField(field, before);
        }
      }
    }

    _mergeHistory = [..._mergeHistory]..removeAt(index);
    await StorageService.saveMergeHistory(_mergeHistory);
    await saveState();
    return VocabMergeUndoResult(restored: restored, missing: unmatched.length);
  }

  // ------------------------------------------------------------- AI helpers

  Future<T> _withAi<T>(Future<T> Function() call) async {
    if (!canUseAi) {
      throw StateError('Add a DeepSeek API key in settings first.');
    }
    try {
      return await call();
    } on DeepSeekException catch (error) {
      if (error.isAuthError && !_deepSeekKeyRejected) {
        _deepSeekKeyRejected = true;
        notifyListeners();
      }
      rethrow;
    }
  }

  Future<List<VocabMergeSuggestion>> suggestVocabMerges({http.Client? client}) {
    return _withAi(() async {
      final groups = vocabGroups;
      final reviewsById = {for (final g in groups) g.id: g.reviews};
      final suggestions = <VocabMergeSuggestion>[];
      for (final batch in _mergeBatches(
        VocabSimilarity.findCandidateGroups(groups),
      )) {
        suggestions.addAll(await _suggestMergesFor(batch, client));
      }
      return [for (final s in suggestions) s.withSurvivor(reviewsById)];
    });
  }

  /// Packs groups into requests of at most [_maxItemsPerRequest] entries.
  static List<List<VocabMergeGroup>> _mergeBatches(
    List<VocabMergeGroup> groups,
  ) {
    final batches = <List<VocabMergeGroup>>[];
    var current = <VocabMergeGroup>[];
    var items = 0;
    for (final group in groups) {
      if (current.isNotEmpty &&
          items + group.items.length > _maxItemsPerRequest) {
        batches.add(current);
        current = [];
        items = 0;
      }
      current.add(group);
      items += group.items.length;
    }
    if (current.isNotEmpty) batches.add(current);
    return batches;
  }

  /// One request. If the answer is cut off or unreadable, retry in halves.
  Future<List<VocabMergeSuggestion>> _suggestMergesFor(
    List<VocabMergeGroup> batch,
    http.Client? client,
  ) async {
    try {
      final reply = await DeepSeekService.completeJson(
        apiKey: _deepSeekApiKey,
        messages: VocabAiPrompts.mergeMessages(batch),
        client: client ?? aiClient,
      );
      return VocabAiPrompts.parseMergeSuggestions(reply, batch);
    } on DeepSeekTruncatedException {
      return _retrySmaller(batch, client);
    } on FormatException {
      return _retrySmaller(batch, client);
    }
  }

  /// A single group that still fails is skipped, so one bad group cannot throw
  /// away the suggestions for all the others.
  Future<List<VocabMergeSuggestion>> _retrySmaller(
    List<VocabMergeGroup> batch,
    http.Client? client,
  ) async {
    if (batch.length < 2) return const [];
    final middle = batch.length ~/ 2;
    return [
      ...await _suggestMergesFor(batch.sublist(0, middle), client),
      ...await _suggestMergesFor(batch.sublist(middle), client),
    ];
  }

  /// Merge suggestions for one vocabulary. Only words spelled like it are sent,
  /// and only suggestions that involve it are returned.
  Future<List<VocabMergeSuggestion>> suggestMergesForVocab(
    VocabItem vocab, {
    http.Client? client,
  }) {
    return _withAi(() async {
      final groups = vocabGroups;
      final self = groups.where((g) => g.id == vocab.id).firstOrNull;
      final others = VocabSimilarity.sameFormPool(vocab, groups);
      if (self == null || others.isEmpty) return const <VocabMergeSuggestion>[];
      final reviewsById = {for (final g in groups) g.id: g.reviews};
      final group = VocabMergeGroup(
        1,
        VocabSimilarity.normalizeTarget(vocab.targetWord),
        [self, ...others],
      );
      final suggestions = await _suggestMergesFor([group], client);
      return [
        for (final s in suggestions)
          if (s.keepId == vocab.id || s.mergeIds.contains(vocab.id))
            s.withSurvivor(reviewsById),
      ];
    });
  }

  /// KO ➔ EN: only words with the same Korean spelling matter. No request is
  /// made when there are none.
  Future<SimilarMeaningResult> suggestKoEnHint(
    VocabItem vocab, {
    http.Client? client,
  }) {
    return _withAi(() async {
      final sameForm = VocabSimilarity.sameFormPool(vocab, vocabGroups);
      if (sameForm.isEmpty) {
        return const SimilarMeaningResult(hint: '', similar: []);
      }
      final prompt = VocabAiPrompts.koEnPrompt(vocab, sameForm);
      final reply = await DeepSeekService.completeJson(
        apiKey: _deepSeekApiKey,
        messages: prompt.messages,
        client: client ?? aiClient,
      );
      return VocabAiPrompts.parseSimilarResult(reply, prompt.ids);
    });
  }

  /// EN ➔ KO: near-synonyms with different Korean forms, from all same-POS vocab.
  Future<SimilarMeaningResult> suggestEnKoHint(
    VocabItem vocab, {
    http.Client? client,
  }) {
    return _withAi(() async {
      final sameFront = getDuplicateFrontVocabularies(
        vocab,
        CardDirection.nativeToTarget,
      );
      final pool = VocabSimilarity.shortlist(
        vocab,
        VocabSimilarity.similarPool(vocab, vocabGroups),
      );
      final prompt = VocabAiPrompts.enKoPrompt(vocab, sameFront, pool);
      final reply = await DeepSeekService.completeJson(
        apiKey: _deepSeekApiKey,
        messages: prompt.messages,
        client: client ?? aiClient,
      );
      return VocabAiPrompts.parseSimilarResult(reply, prompt.ids);
    });
  }

  /// Sets [direction]'s front hint on vocab that have none. Returns the count.
  Future<int> applyFrontHints(
    Map<String, String> hintsByVocabId,
    CardDirection direction,
  ) async {
    var changed = 0;
    final seen = <String>{};
    for (final vocab in _lessons.expand((l) => l.vocabularies)) {
      final hint = hintsByVocabId[vocab.id];
      if (hint == null || !seen.add(vocab.id)) continue;
      final card = direction == CardDirection.targetToNative
          ? vocab.cardTargetToNative
          : vocab.cardNativeToTarget;
      if (!SharedVocab.isBlank(card.frontHint)) continue;
      card.frontHint = hint; // cards are shared, so every lesson sees it
      changed++;
    }
    if (changed > 0) await saveState();
    return changed;
  }

  // Delete vocabulary
  Future<void> deleteVocab(String lessonId, VocabItem vocab) async {
    final lesson = _lessons.firstWhere((l) => l.id == lessonId);
    if (!lesson.vocabularies.contains(vocab)) return;
    // Another copy of the word, in this lesson or another, keeps the
    // progress they share.
    lesson.vocabularies.remove(vocab);
    await saveState();
  }

  /// Removes [vocab] from every lesson that has it. Returns how many lessons
  /// it was removed from.
  Future<int> deleteVocabEverywhere(VocabItem vocab) async {
    var removed = 0;
    for (final lesson in _lessons) {
      final before = lesson.vocabularies.length;
      lesson.vocabularies.removeWhere((item) => item.id == vocab.id);
      if (lesson.vocabularies.length != before) removed++;
    }
    if (removed > 0) await saveState();
    return removed;
  }

  Future<void> deleteSection(String lessonId, List<String> sectionPath) async {
    final lesson = _lessons.firstWhere((l) => l.id == lessonId);
    bool isInSection(VocabItem vocab) {
      final path = vocab.effectiveSectionPath;
      if (path.length < sectionPath.length) return false;
      for (var index = 0; index < sectionPath.length; index++) {
        if (path[index].toLowerCase() != sectionPath[index].toLowerCase()) {
          return false;
        }
      }
      return true;
    }

    // As in [deleteVocab], words that stay keep their progress.
    lesson.vocabularies.removeWhere(isInSection);
    await saveState();
  }

  void _resetSharedProgress(Iterable<VocabItem> vocabularies) {
    final ids = vocabularies.map((vocab) => vocab.id).toSet();
    for (final vocab in _lessons.expand((lesson) => lesson.vocabularies)) {
      if (!ids.contains(vocab.id)) continue;
      vocab.cardTargetToNative.resetProgress();
      vocab.cardNativeToTarget.resetProgress();
    }
  }

  // Delete lesson
  Future<void> deleteLesson(String lessonId) async {
    _lessons.removeWhere((l) => l.id == lessonId);
    if (_selectedLessonId == lessonId) {
      _selectedLessonId = _lessons.isNotEmpty ? _lessons.first.id : null;
    }
    await saveState();
  }

  Future<void> deleteLessonGroup(List<String> folderPath) async {
    // Only what the list shows: a folder can also hold lessons of another
    // language, which stay.
    final deletedIds = activeLessons
        .where((lesson) => isHierarchyPathWithin(lesson.folderPath, folderPath))
        .map((lesson) => lesson.id)
        .toSet();
    if (deletedIds.isEmpty) return;

    _lessons.removeWhere((lesson) => deletedIds.contains(lesson.id));
    if (_selectedLessonId != null && deletedIds.contains(_selectedLessonId)) {
      _selectedLessonId = _lessons.isNotEmpty ? _lessons.first.id : null;
    }
    await saveState();
  }

  Future<void> moveLessonToFolder(
    String lessonId,
    List<String> folderPath,
  ) async {
    final lesson = _lessons.firstWhere(
      (candidate) => candidate.id == lessonId,
      orElse: () => throw StateError('Cannot move missing lesson $lessonId.'),
    );
    if (isSameHierarchyPath(lesson.folderPath, folderPath)) return;

    lesson.moveToFolder(folderPath);
    await saveState();
  }

  Future<void> renameLesson(String lessonId, String name) async {
    final trimmedName = composeHangul(name.trim());
    if (trimmedName.isEmpty) {
      throw ArgumentError.value(name, 'name', 'Must not be empty.');
    }
    if (trimmedName.contains(hierarchySeparator)) {
      throw ArgumentError.value(
        name,
        'name',
        'Must not contain "$hierarchySeparator".',
      );
    }
    final lesson = _lessons.firstWhere(
      (candidate) => candidate.id == lessonId,
      orElse: () => throw StateError('Cannot rename missing lesson $lessonId.'),
    );
    if (lesson.displayTitle == trimmedName) return;
    if (activeLessons.any(
      (other) =>
          !identical(other, lesson) &&
          isSameHierarchyPath(other.folderPath, lesson.folderPath) &&
          other.displayTitle.trim().toLowerCase() == trimmedName.toLowerCase(),
    )) {
      throw StateError(
        'A lesson named "$trimmedName" already exists in this folder.',
      );
    }

    _rename(lesson, trimmedName);
    await saveState();
  }

  Future<void> renameLessonGroup(List<String> folderPath, String name) async {
    if (folderPath.isEmpty) {
      throw ArgumentError.value(folderPath, 'folderPath', 'Must not be empty.');
    }
    final trimmedName = composeHangul(name.trim());
    if (trimmedName.isEmpty) {
      throw ArgumentError.value(name, 'name', 'Must not be empty.');
    }
    if (trimmedName.contains(hierarchySeparator)) {
      throw ArgumentError.value(
        name,
        'name',
        'Must not contain "$hierarchySeparator".',
      );
    }
    if (folderPath.last == trimmedName) return;

    final renamedPath = [
      ...folderPath.take(folderPath.length - 1),
      trimmedName,
    ];
    final affectedLessons = activeLessons
        .where((lesson) => isHierarchyPathWithin(lesson.folderPath, folderPath))
        .toList();
    if (affectedLessons.isEmpty) {
      throw StateError(
        'Cannot rename missing lesson folder "${formatHierarchyPath(folderPath)}".',
      );
    }
    if (activeLessons.any(
      (lesson) =>
          !affectedLessons.contains(lesson) &&
          isHierarchyPathWithin(lesson.folderPath, renamedPath),
    )) {
      throw StateError(
        'A folder already exists at "${formatHierarchyPath(renamedPath)}".',
      );
    }

    for (final lesson in affectedLessons) {
      final suffix = lesson.folderPath.skip(folderPath.length);
      lesson.moveToFolder([...renamedPath, ...suffix]);
    }

    final oldKeyPrefix = hierarchyFolderKey(folderPath);
    final newKeyPrefix = hierarchyFolderKey(renamedPath);
    _lessonHierarchyOrder = _replaceFolderKeyPrefix(
      _lessonHierarchyOrder,
      oldKeyPrefix,
      newKeyPrefix,
    );
    _lessonFolderExpansion = _replaceFolderKeyPrefix(
      _lessonFolderExpansion,
      oldKeyPrefix,
      newKeyPrefix,
    );

    await StorageService.saveLessons(_lessons);
    await StorageService.saveLessonHierarchyOrder(_lessonHierarchyOrder);
    await StorageService.saveLessonFolderExpansion(_lessonFolderExpansion);
    notifyListeners();
  }

  Future<void> moveLessonGroup(
    List<String> folderPath,
    List<String> destinationParentPath,
  ) async {
    if (folderPath.isEmpty) {
      throw ArgumentError.value(folderPath, 'folderPath', 'Must not be empty.');
    }
    if (isHierarchyPathWithin(destinationParentPath, folderPath)) {
      throw ArgumentError(
        'A folder cannot be moved into itself or one of its descendants.',
      );
    }

    final affectedLessons = activeLessons
        .where((lesson) => isHierarchyPathWithin(lesson.folderPath, folderPath))
        .toList();
    if (affectedLessons.isEmpty) {
      throw StateError(
        'Cannot move missing lesson folder "${formatHierarchyPath(folderPath)}".',
      );
    }

    final newFolderPath = [...destinationParentPath, folderPath.last];
    if (isSameHierarchyPath(newFolderPath, folderPath)) return;

    final movesIntoExistingFolder = _lessons.any(
      (lesson) =>
          !affectedLessons.contains(lesson) &&
          isHierarchyPathWithin(lesson.folderPath, newFolderPath),
    );
    if (movesIntoExistingFolder) {
      throw StateError(
        'A folder already exists at "${formatHierarchyPath(newFolderPath)}".',
      );
    }

    for (final lesson in affectedLessons) {
      final suffix = lesson.folderPath.skip(folderPath.length);
      lesson.moveToFolder([...newFolderPath, ...suffix]);
    }

    final oldKeyPrefix = hierarchyFolderKey(folderPath);
    final newKeyPrefix = hierarchyFolderKey(newFolderPath);
    _lessonHierarchyOrder = _replaceFolderKeyPrefix(
      _lessonHierarchyOrder,
      oldKeyPrefix,
      newKeyPrefix,
      omitExact: true,
    );
    _lessonFolderExpansion = _replaceFolderKeyPrefix(
      _lessonFolderExpansion,
      oldKeyPrefix,
      newKeyPrefix,
    );

    await StorageService.saveLessons(_lessons);
    await StorageService.saveLessonHierarchyOrder(_lessonHierarchyOrder);
    await StorageService.saveLessonFolderExpansion(_lessonFolderExpansion);
    notifyListeners();
  }

  static Map<String, T> _replaceFolderKeyPrefix<T>(
    Map<String, T> values,
    String oldPrefix,
    String newPrefix, {
    bool omitExact = false,
  }) {
    final updated = <String, T>{};
    for (final entry in values.entries) {
      if (entry.key == oldPrefix) {
        if (!omitExact) updated[newPrefix] = entry.value;
      } else if (entry.key.startsWith('$oldPrefix$hierarchySeparator')) {
        updated['$newPrefix${entry.key.substring(oldPrefix.length)}'] =
            entry.value;
      } else {
        updated[entry.key] = entry.value;
      }
    }
    return updated;
  }

  // Reset SRS learning state for an individual vocabulary item
  Future<void> resetVocabSrs(VocabItem vocab) async {
    vocab.cardTargetToNative.resetProgress();
    vocab.cardNativeToTarget.resetProgress();
    _resetSharedProgress([vocab]);
    await saveState();
  }

  // Reset SRS learning state for a single card (one direction of a vocabulary
  // item); the other direction keeps its progress.
  Future<void> resetCardSrs(SrsCard card) async {
    card.resetProgress();
    await saveState();
  }

  // Reset SRS learning state for all vocabulary items in a lesson
  Future<void> resetLessonSrs(String lessonId) async {
    final lesson = _lessons.firstWhere((l) => l.id == lessonId);
    _resetLessonSrsProgress(lesson);
    await saveState();
  }

  Future<void> resetLessonGroupSrs(List<String> folderPath) async {
    final lessons = activeLessons.where(
      (lesson) => isHierarchyPathWithin(lesson.folderPath, folderPath),
    );
    for (final lesson in lessons) {
      _resetLessonSrsProgress(lesson);
    }
    await saveState();
  }

  void _resetLessonSrsProgress(Lesson lesson) {
    for (final vocab in lesson.vocabularies) {
      vocab.cardTargetToNative.resetProgress();
      vocab.cardNativeToTarget.resetProgress();
    }
  }

  /// Sentences a review of [vocab] may show: the ones linked to it, or else any
  /// pool sentence containing the word.
  List<Sentence> _sentenceCandidatesForVocab(VocabItem vocab) {
    final linked = getSentencesForVocab(vocab);
    if (linked.isNotEmpty) return linked;
    // Fallback: look in global sentence pool for any sentence matching targetWord
    if (vocab.targetWord.isEmpty) return const [];
    return _sentences
        .where((s) => s.targetText.contains(vocab.targetWord))
        .toList();
  }

  /// Picks one random sentence linked to the vocab, or falls back to any pool sentence containing the word.
  Sentence? getRandomSentenceForVocab(VocabItem vocab) {
    final candidates = _sentenceCandidatesForVocab(vocab);
    if (candidates.isEmpty) return null;
    return candidates[Random().nextInt(candidates.length)];
  }

  /// The sentence a review card for [vocab] should show after the vocab was
  /// edited: [current] while it is still one of the vocab's sentences, else a
  /// new random pick, so deselecting the sentence on screen swaps it out.
  Sentence? refreshSentenceForVocab(VocabItem vocab, Sentence? current) {
    if (current != null &&
        _sentenceCandidatesForVocab(vocab).any((s) => s.id == current.id)) {
      return current;
    }
    return getRandomSentenceForVocab(vocab);
  }

  /// Reviews of already-seen cards of the language shown today, on every
  /// device: today's reviews less the new cards started today.
  int get seenCardReviewsToday => _seenCardReviewsTodayOf(activeLanguage);

  int _seenCardReviewsTodayOf(String? language) {
    final now = DateTime.now();
    final today = _activityDays(
      language,
    )[DateTime(now.year, now.month, now.day)];
    return today == null ? 0 : max(0, today.count - today.newCards);
  }

  /// The part of speech [item] is grouped by when a queue is interleaved.
  static String posKeyOf(StudyCardItem item) {
    final pos = item.vocab.pos.trim().toLowerCase();
    return pos.isEmpty ? 'general' : pos;
  }

  // Generate study queue for a lesson (or all)
  List<StudyCardItem> getStudyQueue({
    String? lessonId,
    bool dueOnly = true,
    bool mistakesOnly = false,
  }) {
    // Without a lesson: every lesson of the language shown.
    final List<Lesson> targetLessons = lessonId == null
        ? activeLessons
        : _lessons.where((l) => l.id == lessonId).toList();
    // The limits are the language's own: the one shown, or the lesson's.
    final language = lessonId == null
        ? activeLanguage
        : targetLessons.firstOrNull?.languageKey;

    final List<StudyCardItem> queue = [];
    final seenCardIds = <String>{};
    final rand = Random();

    for (final lesson in targetLessons) {
      final lessonItems = <StudyCardItem>[];
      for (final vocab in lesson.vocabularies) {
        for (final card in [
          vocab.cardTargetToNative,
          vocab.cardNativeToTarget,
        ]) {
          if (!card.isActive) continue;
          final isEligible = mistakesOnly
              ? card.hasRecentMistake
              : (!dueOnly || card.isAvailable);
          if (isEligible && seenCardIds.add(card.id)) {
            lessonItems.add(
              StudyCardItem(
                vocab: vocab,
                card: card,
                lesson: lesson,
                sentenceResolver: () => getRandomSentenceForVocab(vocab),
              ),
            );
          }
        }
      }
      // Shuffle within each lesson, interleaved across parts of speech.
      queue.addAll(interleaveByGroup(lessonItems, posKeyOf, rand));
    }

    if (dueOnly && !mistakesOnly) {
      // Each kind has its own limit (new cards: see NewCardQuota). Reviews
      // are shuffled across lessons; new cards follow hierarchy order and
      // favor lessons already in progress, and are mixed in after the day's
      // first few reviews.
      final due = <StudyCardItem>[];
      final newCards = <StudyCardItem>[];
      for (final item in queue) {
        (item.card.isNewCard ? newCards : due).add(item);
      }
      final newCardsInPriorityOrder = <StudyCardItem>[];
      final otherNewCards = <StudyCardItem>[];
      final newCardsByLesson = <String, List<StudyCardItem>>{};
      for (final item in newCards) {
        newCardsByLesson.putIfAbsent(item.lesson.id, () => []).add(item);
      }
      for (final lesson in _orderedLessons()) {
        final lessonCards = newCardsByLesson.remove(lesson.id);
        if (lessonCards == null) continue;
        final hasStarted = lesson.vocabularies.any(
          (vocab) =>
              vocab.cardTargetToNative.introducedAt != null ||
              vocab.cardNativeToTarget.introducedAt != null,
        );
        (hasStarted ? newCardsInPriorityOrder : otherNewCards).addAll(
          lessonCards,
        );
      }
      // Sub-24h intervals (1 h / 12 h) ignore the review limit and do not use
      // up any of its quota.
      var reviewBudget = remainingReviews24hOf(language);
      final reviews = <StudyCardItem>[];
      for (final item in interleaveByGroup(due, posKeyOf, rand)) {
        if (item.card.isShortInterval) {
          reviews.add(item);
        } else if (reviewBudget > 0) {
          reviews.add(item);
          reviewBudget--;
        }
      }
      final prioritizedNewCards = [
        ...newCardsInPriorityOrder,
        ...otherNewCards,
      ].take(remainingNewCards24hOf(language)).toList();
      return mixNewCardsIntoReviews(
        reviews: reviews,
        newCards: prioritizedNewCards,
        leadIn: newCardLeadIn(_seenCardReviewsTodayOf(language)),
      );
    }

    return queue;
  }

  /// Cram queue: every enabled card that is not new, due or not, lesson by
  /// lesson, ignoring the review limit. Crammed from one lesson
  /// ([lessonId]), the lesson's new cards come first; practice does not
  /// start them.
  List<StudyCardItem> getCramQueue({String? lessonId}) {
    final all = getStudyQueue(lessonId: lessonId, dueOnly: false);
    final seen = [
      for (final item in all)
        if (!item.card.isNewCard) item,
    ];
    if (lessonId == null) return seen;
    return [
      for (final item in all)
        if (item.card.isNewCard) item,
      ...seen,
    ];
  }

  /// New cards one Learn New Words session of [lessonId] starts: a batch the
  /// size of the daily new-card limit (all of them while it is unlimited),
  /// whatever is left of the limit. Learn New Words is how to learn more
  /// than the limit, one lesson at a time; the cards it starts still count
  /// toward the limit (see [NewCardQuota]), so normal study brings in fewer.
  int learnableNewCardCount(String lessonId) {
    final lesson = _lessons.where((l) => l.id == lessonId).firstOrNull;
    if (lesson == null) return 0;
    final count = lesson.newCardsCount;
    return _maxNewCards24h > 0 ? min(count, _maxNewCards24h) : count;
  }

  /// Learn New Words queue for [lessonId]: a batch of its new cards (see
  /// [learnableNewCardCount]), spread evenly among up to
  /// [oldCardsPerNewCard] of the lesson's seen cards each, a new card first.
  /// The seen cards are only there to mix with; the session does not
  /// reschedule them.
  List<StudyCardItem> getLearnNewQueue(
    String lessonId, {
    int oldCardsPerNewCard = 2,
  }) {
    final all = getStudyQueue(lessonId: lessonId, dueOnly: false);
    final newCards = all
        .where((item) => item.card.isNewCard)
        .take(learnableNewCardCount(lessonId))
        .toList();
    if (newCards.isEmpty) return const [];
    final seen = [
      for (final item in all)
        if (!item.card.isNewCard) item,
    ]..shuffle();
    return mixNewCardsIntoReviews(
      reviews: seen.take(newCards.length * oldCardsPerNewCard).toList(),
      newCards: newCards,
      leadIn: 0,
    );
  }

  List<Lesson> _orderedLessons() {
    final lastSavedRank = _lessonHierarchyOrder.values.fold<int>(
      -1,
      (maximum, rank) => rank > maximum ? rank : maximum,
    );
    final folderOrigins = <String, int>{};
    for (var index = 0; index < _lessons.length; index++) {
      final path = <String>[];
      for (final folder in _lessons[index].folderPath) {
        path.add(folder);
        folderOrigins.putIfAbsent(hierarchyFolderKey(path), () => index);
      }
    }

    final ranksByLesson = <String, List<int>>{};
    for (var index = 0; index < _lessons.length; index++) {
      final lesson = _lessons[index];
      final ranks = <int>[];
      final path = <String>[];
      for (final folder in lesson.folderPath) {
        path.add(folder);
        final key = hierarchyFolderKey(path);
        ranks.add(
          _lessonHierarchyOrder[key] ?? lastSavedRank + folderOrigins[key]! + 1,
        );
      }
      final key = 'lesson:${lesson.id}';
      ranks.add(_lessonHierarchyOrder[key] ?? lastSavedRank + index + 1);
      ranksByLesson[lesson.id] = ranks;
    }

    final originalIndexes = {
      for (var index = 0; index < _lessons.length; index++)
        _lessons[index].id: index,
    };
    final ordered = [..._lessons];
    ordered.sort((first, second) {
      final firstRanks = ranksByLesson[first.id]!;
      final secondRanks = ranksByLesson[second.id]!;
      for (
        var index = 0;
        index < min(firstRanks.length, secondRanks.length);
        index++
      ) {
        final comparison = firstRanks[index].compareTo(secondRanks[index]);
        if (comparison != 0) return comparison;
      }
      final lengthComparison = firstRanks.length.compareTo(secondRanks.length);
      if (lengthComparison != 0) return lengthComparison;
      return originalIndexes[first.id]!.compareTo(originalIndexes[second.id]!);
    });
    return ordered;
  }

  List<StudyCardItem> getRecentMistakesQueue({String? lessonId}) =>
      getStudyQueue(lessonId: lessonId, mistakesOnly: true);

  int getRecentMistakesCount({String? lessonId}) =>
      getRecentMistakesQueue(lessonId: lessonId).length;

  int get totalRecentMistakes => getRecentMistakesCount();

  // Reviews made before daily counts were tracked: credit each card's last
  // review to its day so the activity calendar is not empty.
  bool _backfillDailyReviewCounts() {
    final seen = <String>{};
    for (final vocab in _lessons.expand((lesson) => lesson.vocabularies)) {
      for (final card in [vocab.cardTargetToNative, vocab.cardNativeToTarget]) {
        final reviewed = card.lastReviewed;
        if (reviewed == null || !seen.add(card.id)) continue;
        final date = DateTime(reviewed.year, reviewed.month, reviewed.day);
        _dailyReviewCounts[date] = (_dailyReviewCounts[date] ?? 0) + 1;
      }
    }
    return _dailyReviewCounts.isNotEmpty;
  }

  /// Answers an SRS review and counts it: one review on the day of [at]
  /// (default: now), under its [rating] too, as a new card started if the
  /// card was new, and, unless the card was on a sub-24h interval, a review
  /// toward the 24-hour limit. Pass the same [at]
  /// to [undoCardReview] to take the count back, or to [recountCardReview]
  /// when the rating changes.
  ///
  /// The review is also counted for its language: [language], a
  /// [Lesson.languageKey], or else that of a lesson [card] is in.
  Future<void> recordCardReview(
    SrsCard card,
    SrsRating rating, {
    DateTime? at,
    String? language,
  }) async {
    // Decide before processReview reschedules the card: reviewing a card that
    // was on a sub-24h interval does not count toward the 24 h review limit.
    final countsTowardLimit = !card.isShortInterval;
    final startsNewCard = card.status == SrsStatus.isNew;
    SrsService.processReview(card, rating);
    final now = at ?? DateTime.now();
    final date = DateTime(now.year, now.month, now.day);
    _dailyReviewCounts[date] = (_dailyReviewCounts[date] ?? 0) + 1;
    _addRatingCount(date, rating, 1);
    if (startsNewCard) {
      _dailyNewCardCounts[date] = (_dailyNewCardCounts[date] ?? 0) + 1;
    }
    final reviewed = language ?? _languageOfCard(card);
    if (reviewed != null) {
      _languageActivity
        ..prune(now)
        ..record(
          reviewed,
          now,
          rating,
          newCard: startsNewCard,
          timed: countsTowardLimit,
        );
      await StorageService.saveLanguageActivity(_languageActivity);
      await _settleActivityRestLanguage();
    }
    await StorageService.saveDailyReviewCounts(_dailyReviewCounts);
    await StorageService.saveDailyRatingCounts(_dailyRatingCounts);
    if (startsNewCard) {
      await StorageService.saveDailyNewCardCounts(_dailyNewCardCounts);
    }
    if (countsTowardLimit) {
      _reviewTimestamps24h.removeWhere((t) => now.difference(t).inHours >= 24);
      _reviewTimestamps24h.add(now);
      await StorageService.saveReviewTimestamps(_reviewTimestamps24h);
    }
    await saveState();
  }

  /// Takes back what [recordCardReview] counted for the review made [at] and
  /// rated [rating], when its rating is undone: one review on that day and
  /// under that rating, the new card started if [startedNewCard], and its
  /// entry toward the 24-hour limit if it had one. The card itself is
  /// restored by the caller.
  Future<void> undoCardReview(
    DateTime at,
    SrsRating rating, {
    bool startedNewCard = false,
    String? language,
  }) async {
    final date = DateTime(at.year, at.month, at.day);
    if (language != null) {
      _languageActivity.undo(language, at, rating, newCard: startedNewCard);
      await StorageService.saveLanguageActivity(_languageActivity);
    }
    _decrementDayCount(_dailyReviewCounts, date);
    _addRatingCount(date, rating, -1);
    if (startedNewCard) _decrementDayCount(_dailyNewCardCounts, date);
    final hadTimestamp = _reviewTimestamps24h.remove(at);
    notifyListeners();
    await StorageService.saveDailyReviewCounts(_dailyReviewCounts);
    await StorageService.saveDailyRatingCounts(_dailyRatingCounts);
    if (startedNewCard) {
      await StorageService.saveDailyNewCardCounts(_dailyNewCardCounts);
    }
    if (hadTimestamp) {
      await StorageService.saveReviewTimestamps(_reviewTimestamps24h);
    }
  }

  /// Moves the review made [at] from rating [from] to [to], when an answered
  /// card is re-rated. It is still one review, so no total changes.
  Future<void> recountCardReview(
    DateTime at,
    SrsRating from,
    SrsRating to, {
    String? language,
  }) async {
    if (from == to) return;
    final date = DateTime(at.year, at.month, at.day);
    if (language != null) {
      _languageActivity.recount(language, at, from, to);
      await StorageService.saveLanguageActivity(_languageActivity);
    }
    _addRatingCount(date, from, -1);
    _addRatingCount(date, to, 1);
    notifyListeners();
    await StorageService.saveDailyRatingCounts(_dailyRatingCounts);
  }

  /// The language of a lesson [card] is in, or null when no lesson has it.
  String? _languageOfCard(SrsCard card) {
    for (final lesson in _lessons) {
      for (final vocab in lesson.vocabularies) {
        if (vocab.cardTargetToNative.id == card.id ||
            vocab.cardNativeToTarget.id == card.id) {
          return lesson.languageKey;
        }
      }
    }
    return null;
  }

  /// Takes one off [date] in [counts], dropping the day when it reaches zero.
  static void _decrementDayCount(Map<DateTime, int> counts, DateTime date) {
    final count = counts[date] ?? 0;
    if (count <= 1) {
      counts.remove(date);
    } else {
      counts[date] = count - 1;
    }
  }

  /// Adds [delta] to [rating]'s count on [date], dropping counts and days that
  /// reach zero.
  void _addRatingCount(DateTime date, SrsRating rating, int delta) {
    final day = _dailyRatingCounts.putIfAbsent(date, () => {});
    final count = (day[rating] ?? 0) + delta;
    if (count > 0) {
      day[rating] = count;
    } else {
      day.remove(rating);
    }
    if (day.isEmpty) _dailyRatingCounts.remove(date);
  }

  Future<void> saveState() async {
    await StorageService.saveLessons(_lessons);
    await StorageService.saveSentences(_sentences);
    notifyListeners();
  }

  Future<void> updateLessonMarkdown(String lessonId, String markdown) async {
    final index = _lessons.indexWhere((lesson) => lesson.id == lessonId);
    if (index == -1) {
      throw StateError('Cannot update Markdown for missing lesson $lessonId.');
    }
    _lessons[index].markdownContent = markdown;
    await StorageService.saveLessons(_lessons);
    notifyListeners();
  }

  Future<void> saveLessonHierarchyOrder(List<String> siblingKeys) async {
    final updatedOrder = Map<String, int>.from(_lessonHierarchyOrder);
    for (var index = 0; index < siblingKeys.length; index++) {
      updatedOrder[siblingKeys[index]] = index;
    }
    _lessonHierarchyOrder = updatedOrder;
    await StorageService.saveLessonHierarchyOrder(updatedOrder);
    notifyListeners();
  }

  Future<void> setLessonFolderExpanded(String folderKey, bool expanded) async {
    final updatedExpansion = Map<String, bool>.from(_lessonFolderExpansion)
      ..[folderKey] = expanded;
    _lessonFolderExpansion = updatedExpansion;
    notifyListeners();
    await StorageService.saveLessonFolderExpansion(updatedExpansion);
  }
}

/// Which lesson stays when two in one folder share a name.
enum LessonClashChoice {
  /// [LessonNameClash.existing] stays; the other is overwritten by it (an
  /// imported file is skipped). Either way, the lesson kept takes the other's
  /// file name if it has none, so it keeps a virtual path from a file.
  keepExisting,

  /// [LessonNameClash.incoming] stays and overwrites the other.
  keepIncoming,

  /// Both stay; the incoming one gets [LessonNameClash.renamedTitle].
  keepBoth,
}

/// Two lessons in one folder with the same name: a saved one and an
/// imported or later one.
class LessonNameClash {
  final Lesson existing;
  final Lesson incoming;

  /// The name [LessonClashChoice.keepBoth] gives [incoming]: its own when
  /// the two only share a file.
  final String renamedTitle;

  /// The two come from the same file (the same app folder and file name),
  /// such as one file imported on two devices before they synced, with
  /// different text.
  final bool sameFile;

  const LessonNameClash({
    required this.existing,
    required this.incoming,
    required this.renamedTitle,
    this.sameFile = false,
  });
}
