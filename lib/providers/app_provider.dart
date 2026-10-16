import 'dart:math';

import 'package:flutter/foundation.dart';

import '../models/ai_discussion_message.dart';
import '../models/lesson.dart';
import '../models/vocab_item.dart';
import '../models/sentence.dart';
import '../models/srs_card.dart';
import '../services/storage_service.dart';
import '../services/srs_service.dart';
import '../services/yaml_parser_service.dart';

class StudyCardItem {
  final VocabItem vocab;
  final SrsCard card;
  final Lesson lesson;
  Sentence? sentence;

  StudyCardItem({
    required this.vocab,
    required this.card,
    required this.lesson,
    this.sentence,
  });

  bool get isTargetToNative => card.direction == CardDirection.targetToNative;
}

class AppProvider extends ChangeNotifier {
  List<Lesson> _lessons = [];
  List<Sentence> _sentences = [];
  bool _autoplayAudio = true;
  String _deepSeekApiKey = '';
  Map<String, List<AiDiscussionMessage>> _aiDiscussions = {};
  bool _isLoading = true;
  String? _selectedLessonId;
  Map<String, int> _lessonHierarchyOrder = {};
  Map<String, bool> _lessonFolderExpansion = {};

  int _maxReviews24h = 100;
  List<DateTime> _reviewTimestamps24h = [];

  List<Lesson> get lessons => _lessons;
  List<Sentence> get sentences => _sentences;
  bool get autoplayAudio => _autoplayAudio;
  String get deepSeekApiKey => _deepSeekApiKey;
  bool get isLoading => _isLoading;
  String? get selectedLessonId => _selectedLessonId;
  int get maxReviews24h => _maxReviews24h;
  Map<String, int> get lessonHierarchyOrder =>
      Map.unmodifiable(_lessonHierarchyOrder);
  Map<String, bool> get lessonFolderExpansion =>
      Map.unmodifiable(_lessonFolderExpansion);

  int get reviewsInLast24Hours {
    final now = DateTime.now();
    _reviewTimestamps24h.removeWhere((t) => now.difference(t).inHours >= 24);
    return _reviewTimestamps24h.length;
  }

  int get remainingReviews24h {
    if (_maxReviews24h <= 0) return 999999;
    return max(0, _maxReviews24h - reviewsInLast24Hours);
  }

  Future<void> setMaxReviews24h(int limit) async {
    _maxReviews24h = limit;
    await StorageService.saveMaxReviews24h(limit);
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

    _autoplayAudio = await StorageService.loadAutoplay();
    _deepSeekApiKey = await StorageService.loadDeepSeekApiKey();
    _aiDiscussions = await StorageService.loadAiDiscussions();
    _maxReviews24h = await StorageService.loadMaxReviews24h();
    _reviewTimestamps24h = await StorageService.loadReviewTimestamps();
    _lessonHierarchyOrder = await StorageService.loadLessonHierarchyOrder();
    _lessonFolderExpansion = await StorageService.loadLessonFolderExpansion();
    _sentences = await StorageService.loadSentences();
    _lessons = await StorageService.loadLessons();
    if (_canonicalizeSentencePool()) {
      await StorageService.saveSentences(_sentences);
      await StorageService.saveLessons(_lessons);
    }
    _linkSharedVocabProgress();

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

  Future<void> setDeepSeekApiKey(String apiKey) async {
    final trimmedApiKey = apiKey.trim();
    await StorageService.saveDeepSeekApiKey(trimmedApiKey);
    _deepSeekApiKey = trimmedApiKey;
    notifyListeners();
  }

  List<AiDiscussionMessage> getAiDiscussion(String discussionId) =>
      List.unmodifiable(_aiDiscussions[discussionId] ?? const []);

  Future<void> addAiDiscussionMessage(
    String discussionId,
    AiDiscussionMessage message,
  ) async {
    final messages = List<AiDiscussionMessage>.from(
      _aiDiscussions[discussionId] ?? const [],
    )..add(message);
    _aiDiscussions[discussionId] = messages;
    await StorageService.saveAiDiscussions(_aiDiscussions);
    notifyListeners();
  }

  Future<void> deleteAiDiscussion(String discussionId) async {
    if (_aiDiscussions.remove(discussionId) == null) return;
    await StorageService.saveAiDiscussions(_aiDiscussions);
    notifyListeners();
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

  Sentence _upsertSentence(
    Sentence incoming, {
    Map<String, List<Sentence>>? bySignature,
  }) {
    final signature = _sentenceSignature(incoming);
    final duplicates =
        (bySignature?[signature] ??
                _sentences.where(
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
    canonical
      ..targetText = incoming.targetText
      ..translationText = incoming.translationText
      ..audioUrl = audioUrl
      ..notes = notes
      ..lessonId ??= incoming.lessonId;
    if (!_sentences.any((sentence) => identical(sentence, canonical))) {
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
      _sentences.removeWhere(
        (sentence) =>
            !identical(sentence, canonical) && removedIds.contains(sentence.id),
      );
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
    final lesson = _applyParsedLesson(parsed);
    _linkSharedVocabProgress();
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
    if (parsedLessons.isNotEmpty) {
      _linkSharedVocabProgress();
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
          _normalizeLessonPart(lesson.effectiveUnitTitle) ==
              _normalizeLessonPart(parsed.lesson.effectiveUnitTitle) &&
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
        _reuseExistingVocabProgress(parsed.lesson.vocabularies);
      } else {
        _reuseVocabProgressFromIndex(parsed.lesson.vocabularies, vocabIndex);
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

  static String _normalizeLessonPart(String? value) =>
      value?.trim().toLowerCase() ?? '';

  static String _normalizeHierarchyPath(String? value) =>
      value
          ?.split(' / ')
          .map((part) => part.trim().toLowerCase())
          .where((part) => part.isNotEmpty)
          .join(' / ') ??
      '';

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
          _reuseProgress(importedVocab, previousVocab);
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
        ..audioUrl = importedVocab.audioUrl
        ..notes = importedVocab.notes
        ..disambiguation = importedVocab.disambiguation
        ..sentenceIds = importedVocab.sentenceIds;
      _addVocabToIndexes(lessonMatch, vocabById, vocabByMeaning);
      if (previousVocab != null && !identical(previousVocab, lessonMatch)) {
        _reuseProgress(lessonMatch, previousVocab);
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

  void _reuseExistingVocabProgress(List<VocabItem> imported) {
    _reuseVocabProgressFromIndex(imported, _newVocabProgressIndex());
  }

  Map<String, VocabItem> _newVocabProgressIndex() {
    final index = <String, VocabItem>{};
    for (final vocab in _lessons.expand((lesson) => lesson.vocabularies)) {
      index.putIfAbsent(_progressIdentity(vocab), () => vocab);
    }
    return index;
  }

  void _reuseVocabProgressFromIndex(
    List<VocabItem> imported,
    Map<String, VocabItem> index,
  ) {
    for (final vocab in imported) {
      final previous = index[_progressIdentity(vocab)];
      if (previous != null) _reuseProgress(vocab, previous);
      index.putIfAbsent(_progressIdentity(vocab), () => vocab);
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

  static void _reuseProgress(VocabItem target, VocabItem source) {
    target
      ..id =
          target.idIsExplicit ||
              (target.id.startsWith('auto-') && !source.idIsExplicit)
          ? target.id
          : source.id
      ..idIsExplicit = target.idIsExplicit || source.idIsExplicit
      ..cardTargetToNative = source.cardTargetToNative
      ..cardNativeToTarget = source.cardNativeToTarget;
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

  // Update vocabulary fields
  Future<void> updateVocab(VocabItem vocab, {String? previousId}) async {
    final sameIdCandidates = _lessons
        .expand((lesson) => lesson.vocabularies)
        .where(
          (candidate) =>
              candidate.id == vocab.id && !identical(candidate, vocab),
        )
        .toList();
    final hasSameId = sameIdCandidates.isNotEmpty;
    if (previousId != null && previousId != vocab.id && !hasSameId) {
      vocab
        ..cardTargetToNative = SrsCard(
          direction: CardDirection.targetToNative,
          isEnabled: vocab.cardTargetToNative.isEnabled,
        )
        ..cardNativeToTarget = SrsCard(
          direction: CardDirection.nativeToTarget,
          isEnabled: vocab.cardNativeToTarget.isEnabled,
        );
    }
    final existing = _findExistingVocab(
      vocab,
      _lessons
          .expand((lesson) => lesson.vocabularies)
          .where((candidate) => !identical(candidate, vocab)),
    );
    if (existing != null) {
      _reuseProgress(vocab, existing);
    } else {
      _linkSharedVocabProgress();
    }
    await saveState();
  }

  // Add vocabulary to a lesson
  Future<void> addVocabToLesson(String lessonId, VocabItem vocab) async {
    final lesson = _lessons.firstWhere((l) => l.id == lessonId);
    final existing = _findExistingVocab(
      vocab,
      _lessons.expand((candidate) => candidate.vocabularies),
    );
    if (existing != null) _reuseProgress(vocab, existing);
    lesson.vocabularies.add(vocab);
    await saveState();
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

  Future<void> deleteLessonGroup(String unitTitle) async {
    final normalizedTitle = _normalizeHierarchyPath(unitTitle);
    final deletedIds = _lessons
        .where((lesson) {
          final path = _normalizeHierarchyPath(lesson.effectiveUnitTitle);
          return path == normalizedTitle ||
              path.startsWith('$normalizedTitle/');
        })
        .map((lesson) => lesson.id)
        .toSet();
    if (deletedIds.isEmpty) return;

    _lessons.removeWhere((lesson) => deletedIds.contains(lesson.id));
    if (_selectedLessonId != null && deletedIds.contains(_selectedLessonId)) {
      _selectedLessonId = _lessons.isNotEmpty ? _lessons.first.id : null;
    }
    await saveState();
  }

  Future<void> moveLessonToFolder(String lessonId, String? folderPath) async {
    final lesson = _lessons.firstWhere(
      (candidate) => candidate.id == lessonId,
      orElse: () => throw StateError('Cannot move missing lesson $lessonId.'),
    );
    final destinationPath = _hierarchyPathParts(folderPath).join(' / ');
    final destination = _normalizeHierarchyPath(destinationPath);
    if (_normalizeHierarchyPath(lesson.effectiveUnitTitle) == destination) {
      return;
    }

    lesson
      ..unitTitle = destinationPath.isEmpty ? null : destinationPath
      ..title = lesson.displayTitle;
    await saveState();
  }

  Future<void> moveLessonGroup(
    String folderPath,
    String? destinationParentPath,
  ) async {
    final source = _normalizeHierarchyPath(folderPath);
    if (source.isEmpty) {
      throw ArgumentError.value(folderPath, 'folderPath', 'Must not be empty.');
    }
    final destinationParent = _normalizeHierarchyPath(destinationParentPath);
    if (destinationParent == source ||
        destinationParent.startsWith('$source/')) {
      throw ArgumentError(
        'A folder cannot be moved into itself or one of its descendants.',
      );
    }

    final affectedLessons = _lessons.where((lesson) {
      final path = _normalizeHierarchyPath(lesson.effectiveUnitTitle);
      return path == source || path.startsWith('$source/');
    }).toList();
    if (affectedLessons.isEmpty) {
      throw StateError('Cannot move missing lesson folder "$folderPath".');
    }

    final sourceParts = _hierarchyPathParts(folderPath);
    final destinationParts = _hierarchyPathParts(destinationParentPath);
    final newFolderParts = [...destinationParts, sourceParts.last];
    final newFolderPath = newFolderParts.join('/');
    final normalizedNewFolderPath = _normalizeHierarchyPath(newFolderPath);
    if (normalizedNewFolderPath == source) return;

    final movesIntoExistingFolder = _lessons.any((lesson) {
      if (affectedLessons.contains(lesson)) return false;
      final path = _normalizeHierarchyPath(lesson.effectiveUnitTitle);
      return path == normalizedNewFolderPath ||
          path.startsWith('$normalizedNewFolderPath/');
    });
    if (movesIntoExistingFolder) {
      throw StateError('A folder already exists at "$newFolderPath".');
    }

    for (final lesson in affectedLessons) {
      final oldParts = _hierarchyPathParts(lesson.effectiveUnitTitle);
      final suffix = oldParts.skip(sourceParts.length);
      lesson
        ..unitTitle = [...newFolderParts, ...suffix].join('/')
        ..title = lesson.displayTitle;
    }

    final oldKeyPrefix = 'folder:$source';
    final newKeyPrefix = 'folder:$normalizedNewFolderPath';
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

  static List<String> _hierarchyPathParts(String? path) =>
      path
          ?.split(' / ')
          .map((part) => part.trim())
          .where((part) => part.isNotEmpty)
          .toList() ??
      [];

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
      } else if (entry.key.startsWith('$oldPrefix/')) {
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

  // Reset SRS learning state for all vocabulary items in a lesson
  Future<void> resetLessonSrs(String lessonId) async {
    final lesson = _lessons.firstWhere((l) => l.id == lessonId);
    for (final vocab in lesson.vocabularies) {
      vocab.cardTargetToNative.resetProgress();
      vocab.cardNativeToTarget.resetProgress();
    }
    await saveState();
  }

  /// Picks one random sentence linked to the vocab, or falls back to any pool sentence containing the word.
  Sentence? getRandomSentenceForVocab(VocabItem vocab) {
    final sentences = getSentencesForVocab(vocab);
    if (sentences.isNotEmpty) {
      final rand = Random();
      return sentences[rand.nextInt(sentences.length)];
    }
    // Fallback: look in global sentence pool for any sentence matching targetWord
    if (vocab.targetWord.isNotEmpty) {
      final matches = _sentences
          .where((s) => s.targetText.contains(vocab.targetWord))
          .toList();
      if (matches.isNotEmpty) {
        final rand = Random();
        return matches[rand.nextInt(matches.length)];
      }
    }
    return null;
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
              : (!dueOnly || card.isDue);
          if (isEligible && seenCardIds.add(card.id)) {
            posGroups
                .putIfAbsent(posKey, () => [])
                .add(
                  StudyCardItem(
                    vocab: vocab,
                    card: card,
                    lesson: lesson,
                    sentence: getRandomSentenceForVocab(vocab),
                  ),
                );
          }
        }

        // EN -> KO Card
        if (vocab.cardNativeToTarget.isEnabled) {
          final card = vocab.cardNativeToTarget;
          final isEligible = mistakesOnly
              ? card.hasRecentMistake
              : (!dueOnly || card.isDue);
          if (isEligible && seenCardIds.add(card.id)) {
            posGroups
                .putIfAbsent(posKey, () => [])
                .add(
                  StudyCardItem(
                    vocab: vocab,
                    card: card,
                    lesson: lesson,
                    sentence: getRandomSentenceForVocab(vocab),
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

    if (dueOnly && !mistakesOnly && _maxReviews24h > 0) {
      final limit = remainingReviews24h;
      if (queue.length > limit) {
        return queue.sublist(0, limit);
      }
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
    SrsService.processReview(card, rating);
    final now = DateTime.now();
    _reviewTimestamps24h.removeWhere((t) => now.difference(t).inHours >= 24);
    _reviewTimestamps24h.add(now);
    await StorageService.saveReviewTimestamps(_reviewTimestamps24h);
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
