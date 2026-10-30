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
import '../models/vocab_item.dart';
import '../models/vocab_merge_record.dart';
import '../services/ai_discussion_search.dart';
import '../services/deepseek_service.dart';
import '../services/srs_service.dart';
import '../services/storage_service.dart';
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

class AppProvider extends ChangeNotifier {
  List<Lesson> _lessons = [];
  List<Sentence> _sentences = [];
  bool _autoplayAudio = true;

  /// Enabled options as `<target>_romanization` / `<target>_ipa`.
  Set<String> _pronunciationOptions = {};
  String _deepSeekApiKey = '';
  bool _deepSeekKeyRejected = false;
  List<VocabMergeRecord> _mergeHistory = [];
  static const int _maxMergeHistory = 20;
  static const int _maxItemsPerRequest = 150;
  Map<String, List<AiDiscussionMessage>> _aiDiscussions = {};
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

  List<Lesson> get lessons => _lessons;
  List<Sentence> get sentences => _sentences;
  bool get autoplayAudio => _autoplayAudio;
  bool showRomanization(PronunciationTarget target) =>
      _pronunciationOptions.contains('${target.name}_romanization');
  bool showIpa(PronunciationTarget target) =>
      _pronunciationOptions.contains('${target.name}_ipa');
  String get deepSeekApiKey => _deepSeekApiKey;

  /// False without a key, and after DeepSeek rejected it (until it changes).
  bool get canUseAi =>
      _deepSeekApiKey.trim().isNotEmpty && !_deepSeekKeyRejected;
  List<VocabMergeRecord> get mergeHistory => List.unmodifiable(_mergeHistory);
  bool get isLoading => _isLoading;
  String? get selectedLessonId => _selectedLessonId;
  int get maxReviews24h => _maxReviews24h;
  int get maxNewCards24h => _maxNewCards24h;
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

  int get reviewsInLast24Hours {
    final now = DateTime.now();
    _reviewTimestamps24h.removeWhere((t) => now.difference(t).inHours >= 24);
    return _reviewTimestamps24h.length;
  }

  /// Cards seen for the first time in the last 24 hours. Derived from the
  /// cards, so undoing or re-rating a first review gives the quota back.
  int get newCardsIntroducedLast24h {
    final now = DateTime.now();
    final counted = <String>{};
    for (final lesson in _lessons) {
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

  /// Reviews of already-seen cards. A card's first review counts against the
  /// new-card limit instead.
  int get reviewsOfSeenCardsInLast24Hours =>
      max(0, reviewsInLast24Hours - newCardsIntroducedLast24h);

  int get remainingReviews24h {
    if (_maxReviews24h <= 0) return 999999;
    return max(0, _maxReviews24h - reviewsOfSeenCardsInLast24Hours);
  }

  int get remainingNewCards24h {
    if (_maxNewCards24h <= 0) return 999999;
    return max(0, _maxNewCards24h - newCardsIntroducedLast24h);
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
    _mergeHistory = await StorageService.loadMergeHistory();
    _aiDiscussions = results.$3;
    _maxReviews24h = results.$4;
    _reviewTimestamps24h = results.$5;
    _lessonHierarchyOrder = results.$6;
    _lessonFolderExpansion = results.$7;
    _pronunciationOptions = results.$8;
    _maxNewCards24h = results.$9;
    _lessons = await StorageService.loadLessons();
    // Loaded after lessons because a fresh debug install seeds sentences there.
    _sentences = await StorageService.loadSentences();
    if (_canonicalizeSentencePool()) {
      await StorageService.saveSentences(_sentences);
      await StorageService.saveLessons(_lessons);
    }
    _linkSharedVocabProgress();
    if (_canonicalizeAiDiscussions()) {
      await StorageService.saveAiDiscussions(_aiDiscussions);
    }

    if (_lessons.isNotEmpty) {
      _selectedLessonId = _lessons.first.id;
    }

    _isLoading = false;
    notifyListeners();
  }

  bool _canonicalizeSentencePool() {
    final canonicalBySignature = <String, Sentence>{};
    final canonicalIndexes = <String, int>{};
    final canonicalSentences = <Sentence>[];
    final redirectedIds = <String, String>{};

    for (final sentence in _sentences) {
      final signature = _sentenceSignature(sentence);
      final canonical = canonicalBySignature[signature];
      if (canonical == null) {
        canonicalBySignature[signature] = sentence;
        canonicalIndexes[signature] = canonicalSentences.length;
        canonicalSentences.add(sentence);
        continue;
      }

      final canonicalHasAudio = canonical.audioUrl?.trim().isNotEmpty == true;
      final sentenceHasAudio = sentence.audioUrl?.trim().isNotEmpty == true;
      if (canonical.notes.trim().isEmpty && sentence.notes.trim().isNotEmpty) {
        canonical.notes = sentence.notes;
      }
      final mergedTts = canonical.ttsText?.trim().isNotEmpty == true
          ? canonical.ttsText
          : sentence.ttsText;
      canonical.ttsText = mergedTts;
      sentence.ttsText = mergedTts;
      if (!canonicalHasAudio && sentenceHasAudio) {
        sentence.lessonId ??= canonical.lessonId;
        sentence.notes = canonical.notes;
        canonicalSentences[canonicalIndexes[signature]!] = sentence;
        canonicalBySignature[signature] = sentence;
        redirectedIds[canonical.id] = sentence.id;
      } else {
        canonical.audioUrl ??= sentence.audioUrl;
        canonical.lessonId ??= sentence.lessonId;
        redirectedIds[sentence.id] = canonical.id;
      }
    }

    if (redirectedIds.isEmpty) return false;

    for (final vocab in _lessons.expand((lesson) => lesson.vocabularies)) {
      vocab.sentenceIds = _unique(
        vocab.sentenceIds.map((id) => redirectedIds[id] ?? id),
      );
    }
    _sentences = canonicalSentences;
    return true;
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
    final canonical = _upsertSentence(sentence);
    await StorageService.saveSentences(_sentences);
    notifyListeners();
    return canonical;
  }

  Future<Sentence> updateSentenceInPool(Sentence sentence) async {
    final canonical = _upsertSentence(sentence);
    await StorageService.saveSentences(_sentences);
    await StorageService.saveLessons(_lessons);
    notifyListeners();
    return canonical;
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
    final canonical = candidates.firstWhere(
      (sentence) => sentence.audioUrl?.trim().isNotEmpty == true,
      orElse: () => incoming,
    );
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
      ..targetText = incoming.targetText
      ..translationText = incoming.translationText
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
      for (final vocab in _lessons.expand((lesson) => lesson.vocabularies)) {
        vocab.sentenceIds = _unique(
          vocab.sentenceIds.map(
            (id) => removedIds.contains(id) ? canonical.id : id,
          ),
        );
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
    final lesson = _applyParsedLesson(parsed);
    _linkSharedVocabProgress();
    await _followVocabIdChanges(before);
    await _saveImportedLessons();
    notifyListeners();
    return lesson;
  }

  Future<List<Lesson>> importParsedLessons(
    List<YamlParseResult> parsedLessons, {
    void Function(int current, int total)? onProgress,
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
        importedLessons.add(
          _applyParsedLesson(
            parsedLessons[index],
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

  Lesson _applyParsedLesson(
    YamlParseResult parsed, {
    Map<String, List<Sentence>>? sentenceIndex,
    Map<String, VocabItem>? vocabIndex,
  }) {
    final existingIndex = _lessons.indexWhere(
      (lesson) =>
          isSameHierarchyPath(lesson.folderPath, parsed.lesson.folderPath) &&
          _lessonIdentity(lesson) == _lessonIdentity(parsed.lesson),
    );
    final existingLesson = existingIndex == -1 ? null : _lessons[existingIndex];
    if (existingLesson != null) {
      existingLesson.title = parsed.lesson.title;
      existingLesson.unitTitle =
          parsed.lesson.unitTitle ?? existingLesson.unitTitle;
      existingLesson.targetLanguage = parsed.lesson.targetLanguage;
      existingLesson.nativeLanguage = parsed.lesson.nativeLanguage;
      if (parsed.lesson.markdownContent.isNotEmpty) {
        existingLesson.markdownContent = parsed.lesson.markdownContent;
      }
      _mergeImportedLesson(existingLesson, parsed, sentenceIndex);
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
      for (final vocab in parsed.lesson.vocabularies) {
        vocab.sentenceIds = _unique(
          vocab.sentenceIds.map((id) => sentenceIds[id] ?? id),
        );
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
    Map<String, List<Sentence>>? sentenceIndex,
  ) {
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
    final matchedLessonVocabularies = <VocabItem>{};
    final newVocabularies = <VocabItem>[];
    for (final importedVocab in parsed.lesson.vocabularies) {
      importedVocab.sentenceIds = importedVocab.sentenceIds
          .map((id) => importedSentenceIds[id] ?? id)
          .toList();

      final previousVocab = _findExistingVocabInIndexes(
        importedVocab,
        vocabById,
        vocabByMeaning,
        matchedLessonVocabularies,
      );
      final lessonMatch =
          previousVocab != null && lesson.vocabularies.contains(previousVocab)
          ? previousVocab
          : null;
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
      lessonMatch
        ..id = lessonMatch.idIsExplicit ? lessonMatch.id : importedVocab.id
        ..idIsExplicit = lessonMatch.idIsExplicit || importedVocab.idIsExplicit
        ..targetWord = importedVocab.targetWord
        ..translation = importedVocab.translation
        ..pos = importedVocab.pos
        ..sectionPath = importedVocab.sectionPath
        ..sentenceIds = importedVocab.sentenceIds;
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

  static String _sentenceSignature(Sentence sentence) {
    String normalize(String text) =>
        Sentence.withoutEmphasis(text)
            .trim()
            .toLowerCase()
            .replaceAll(RegExp(r'\s+'), ' ');
    return '${normalize(sentence.targetText)}\u0000'
        '${normalize(sentence.translationText)}';
  }

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
          ? candidate.cardTargetToNative.isEnabled
          : candidate.cardNativeToTarget.isEnabled;
    }).toList();
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

  List<VocabGroup> get vocabGroups {
    final byId = <String, VocabGroup>{};
    for (final lesson in _lessons) {
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
    _resetSharedProgress([vocab]);
    lesson.vocabularies.remove(vocab);
    await saveState();
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

    final deleted = lesson.vocabularies.where(isInSection).toList();
    _resetSharedProgress(deleted);
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
    final deletedIds = _lessons
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

    final affectedLessons = _lessons
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
    final lessons = _lessons.where(
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

  // Generate study queue for a lesson (or all)
  List<StudyCardItem> getStudyQueue({
    String? lessonId,
    bool dueOnly = true,
    bool mistakesOnly = false,
  }) {
    final List<Lesson> targetLessons = lessonId == null
        ? _lessons
        : _lessons.where((l) => l.id == lessonId).toList();

    final List<StudyCardItem> queue = [];
    final seenCardIds = <String>{};
    final rand = Random();

    for (final lesson in targetLessons) {
      final Map<String, List<StudyCardItem>> posGroups = {};

      for (final vocab in lesson.vocabularies) {
        final posKey = vocab.pos.trim().toLowerCase().isEmpty
            ? 'general'
            : vocab.pos.trim().toLowerCase();

        // KO -> EN Card
        if (vocab.cardTargetToNative.isEnabled) {
          final card = vocab.cardTargetToNative;
          final isEligible = mistakesOnly
              ? card.hasRecentMistake
              : (!dueOnly || card.isAvailable);
          if (isEligible && seenCardIds.add(card.id)) {
            posGroups
                .putIfAbsent(posKey, () => [])
                .add(
                  StudyCardItem(
                    vocab: vocab,
                    card: card,
                    lesson: lesson,
                    sentenceResolver: () => getRandomSentenceForVocab(vocab),
                  ),
                );
          }
        }

        // EN -> KO Card
        if (vocab.cardNativeToTarget.isEnabled) {
          final card = vocab.cardNativeToTarget;
          final isEligible = mistakesOnly
              ? card.hasRecentMistake
              : (!dueOnly || card.isAvailable);
          if (isEligible && seenCardIds.add(card.id)) {
            posGroups
                .putIfAbsent(posKey, () => [])
                .add(
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

      if (posGroups.isEmpty) continue;

      // Shuffle cards within each POS bucket
      final activeBuckets = <List<StudyCardItem>>[];
      final sortedPosKeys = posGroups.keys.toList()..shuffle(rand);
      for (final key in sortedPosKeys) {
        final items = posGroups[key]!;
        items.shuffle(rand);
        activeBuckets.add(items);
      }

      // Interleave across POS categories
      while (activeBuckets.isNotEmpty) {
        activeBuckets.shuffle(rand);
        for (var i = activeBuckets.length - 1; i >= 0; i--) {
          final bucket = activeBuckets[i];
          if (bucket.isNotEmpty) {
            queue.add(bucket.removeLast());
          }
          if (bucket.isEmpty) {
            activeBuckets.removeAt(i);
          }
        }
      }
    }

    if (dueOnly && !mistakesOnly) {
      // Reviews first, then new cards; each has its own rolling 24h limit.
      // Lesson order is kept within both groups.
      final due = <StudyCardItem>[];
      final newCards = <StudyCardItem>[];
      for (final item in queue) {
        (item.card.isNewCard ? newCards : due).add(item);
      }
      // Sub-24h intervals (1 h / 12 h) ignore the review limit and do not use
      // up any of its quota.
      var reviewBudget = remainingReviews24h;
      final reviews = <StudyCardItem>[];
      for (final item in due) {
        if (item.card.isShortInterval) {
          reviews.add(item);
        } else if (reviewBudget > 0) {
          reviews.add(item);
          reviewBudget--;
        }
      }
      return [...reviews, ...newCards.take(remainingNewCards24h)];
    }

    return queue;
  }

  List<StudyCardItem> getRecentMistakesQueue({String? lessonId}) =>
      getStudyQueue(lessonId: lessonId, mistakesOnly: true);

  int getRecentMistakesCount({String? lessonId}) =>
      getRecentMistakesQueue(lessonId: lessonId).length;

  int get totalRecentMistakes => getRecentMistakesCount();

  // Answer SRS review
  Future<void> recordCardReview(SrsCard card, SrsRating rating) async {
    // Decide before processReview reschedules the card: reviewing a card that
    // was on a sub-24h interval does not count toward the 24 h review limit.
    final countsTowardLimit = !card.isShortInterval;
    SrsService.processReview(card, rating);
    if (countsTowardLimit) {
      final now = DateTime.now();
      _reviewTimestamps24h.removeWhere((t) => now.difference(t).inHours >= 24);
      _reviewTimestamps24h.add(now);
      await StorageService.saveReviewTimestamps(_reviewTimestamps24h);
    }
    await saveState();
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
