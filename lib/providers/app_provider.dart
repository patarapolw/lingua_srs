import 'dart:math';

import 'package:flutter/foundation.dart';

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
  bool _isLoading = true;
  String? _selectedLessonId;

  List<Lesson> get lessons => _lessons;
  List<Sentence> get sentences => _sentences;
  bool get autoplayAudio => _autoplayAudio;
  bool get isLoading => _isLoading;
  String? get selectedLessonId => _selectedLessonId;

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
    _sentences = await StorageService.loadSentences();
    _lessons = await StorageService.loadLessons();
    _linkSharedVocabProgress();

    if (_lessons.isNotEmpty) {
      _selectedLessonId = _lessons.first.id;
    }

    _isLoading = false;
    notifyListeners();
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

  Future<void> addSentenceToPool(Sentence sentence) async {
    _sentences.add(sentence);
    await StorageService.saveSentences(_sentences);
    notifyListeners();
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
    List<YamlParseResult> parsedLessons,
  ) async {
    final importedLessons = <Lesson>[];
    for (final parsed in parsedLessons) {
      importedLessons.add(_applyParsedLesson(parsed));
    }
    if (parsedLessons.isNotEmpty) {
      _linkSharedVocabProgress();
      await _saveImportedLessons();
      notifyListeners();
    }
    return importedLessons;
  }

  Lesson _applyParsedLesson(YamlParseResult parsed) {
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
      _mergeImportedLesson(existingLesson, parsed);
    } else {
      _reuseExistingVocabProgress(parsed.lesson.vocabularies);
      _lessons.add(parsed.lesson);
      _sentences.addAll(parsed.sentences);
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

  static String _lessonIdentity(Lesson lesson) {
    final lessonNumber = RegExp(
      r'^(Lesson\s+\d+)',
      caseSensitive: false,
    ).firstMatch(lesson.displayTitle.trim());
    return lessonNumber?.group(1)?.toLowerCase() ??
        lesson.displayTitle.trim().toLowerCase();
  }

  void _mergeImportedLesson(Lesson lesson, YamlParseResult parsed) {
    final oldSentences = _sentences
        .where(
          (sentence) =>
              sentence.lessonId == lesson.id ||
              lesson.vocabularies.any(
                (vocab) => vocab.sentenceIds.contains(sentence.id),
              ),
        )
        .toList();
    final sentencesByContent = <String, List<Sentence>>{};
    for (final sentence in oldSentences) {
      sentencesByContent
          .putIfAbsent(_sentenceSignature(sentence), () => [])
          .add(sentence);
    }

    final importedSentenceIds = <String, String>{};
    for (final sentence in parsed.sentences) {
      final matches = sentencesByContent[_sentenceSignature(sentence)];
      final existingSentence = matches == null || matches.isEmpty
          ? null
          : matches.removeAt(0);
      if (existingSentence == null) {
        sentence.lessonId = lesson.id;
        _sentences.add(sentence);
        importedSentenceIds[sentence.id] = sentence.id;
      } else {
        existingSentence
          ..targetText = sentence.targetText
          ..translationText = sentence.translationText
          ..audioUrl = sentence.audioUrl
          ..lessonId = lesson.id;
        importedSentenceIds[sentence.id] = existingSentence.id;
      }
    }

    final existingVocabularies = _lessons
        .where((candidate) => candidate.id != lesson.id)
        .expand((candidate) => candidate.vocabularies)
        .toList();
    final matchedLessonVocabularies = <VocabItem>{};
    final newVocabularies = <VocabItem>[];
    for (final importedVocab in parsed.lesson.vocabularies) {
      importedVocab.sentenceIds = importedVocab.sentenceIds
          .map((id) => importedSentenceIds[id] ?? id)
          .toList();

      final previousVocab = _findExistingVocab(importedVocab, [
        ...lesson.vocabularies.where(
          (vocab) => !matchedLessonVocabularies.contains(vocab),
        ),
        ...existingVocabularies,
        ...newVocabularies,
      ]);
      final lessonMatch =
          previousVocab != null && lesson.vocabularies.contains(previousVocab)
          ? previousVocab
          : null;
      if (lessonMatch == null) {
        if (previousVocab != null) {
          _reuseProgress(importedVocab, previousVocab);
        }
        newVocabularies.add(importedVocab);
        continue;
      }

      matchedLessonVocabularies.add(lessonMatch);
      lessonMatch
        ..id = lessonMatch.idIsExplicit ? lessonMatch.id : importedVocab.id
        ..idIsExplicit = lessonMatch.idIsExplicit || importedVocab.idIsExplicit
        ..targetWord = importedVocab.targetWord
        ..translation = importedVocab.translation
        ..pos = importedVocab.pos
        ..sectionPath = importedVocab.sectionPath
        ..audioUrl = importedVocab.audioUrl
        ..notes = importedVocab.notes
        ..sentenceIds = importedVocab.sentenceIds;
      if (previousVocab != null && !identical(previousVocab, lessonMatch)) {
        _reuseProgress(lessonMatch, previousVocab);
      }
    }
    lesson.vocabularies = [...lesson.vocabularies, ...newVocabularies];
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

    final exactMeaning = vocabularies.where(
      (vocab) => _sameVocabMeaning(vocab, imported),
    );
    if (exactMeaning.isNotEmpty) return exactMeaning.first;

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
      _normalizeVocabWord(first.targetWord) ==
          _normalizeVocabWord(second.targetWord) &&
      _normalizeVocabWord(first.translation) ==
          _normalizeVocabWord(second.translation);

  static String _normalizeVocabWord(String word) =>
      word.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  void _reuseExistingVocabProgress(List<VocabItem> imported) {
    final existing = _lessons.expand((lesson) => lesson.vocabularies).toList();
    final newByIdentity = <String, VocabItem>{};
    for (final vocab in imported) {
      final previous = _findExistingVocab(vocab, [
        ...existing,
        ...newByIdentity.values,
      ]);
      if (previous != null) _reuseProgress(vocab, previous);
      newByIdentity.putIfAbsent(_progressIdentity(vocab), () => vocab);
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

  static String _sentenceSignature(Sentence sentence) =>
      '${sentence.targetText.trim()}\u0000${sentence.translationText.trim()}';

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
    final normalizedTitle = _normalizeLessonPart(unitTitle);
    final deletedIds = _lessons
        .where(
          (lesson) =>
              _normalizeLessonPart(lesson.effectiveUnitTitle) ==
              normalizedTitle,
        )
        .map((lesson) => lesson.id)
        .toSet();
    if (deletedIds.isEmpty) return;

    _lessons.removeWhere((lesson) => deletedIds.contains(lesson.id));
    if (_selectedLessonId != null && deletedIds.contains(_selectedLessonId)) {
      _selectedLessonId = _lessons.isNotEmpty ? _lessons.first.id : null;
    }
    await saveState();
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
  List<StudyCardItem> getStudyQueue({String? lessonId, bool dueOnly = true}) {
    final List<Lesson> targetLessons = lessonId == null
        ? _lessons
        : _lessons.where((l) => l.id == lessonId).toList();

    final List<StudyCardItem> queue = [];
    final seenCardIds = <String>{};

    for (final lesson in targetLessons) {
      for (final vocab in lesson.vocabularies) {
        // KO -> EN Card
        if (vocab.cardTargetToNative.isEnabled) {
          if (!dueOnly || vocab.cardTargetToNative.isDue) {
            if (seenCardIds.add(vocab.cardTargetToNative.id)) {
              queue.add(
                StudyCardItem(
                  vocab: vocab,
                  card: vocab.cardTargetToNative,
                  lesson: lesson,
                  sentence: getRandomSentenceForVocab(vocab),
                ),
              );
            }
          }
        }

        // EN -> KO Card
        if (vocab.cardNativeToTarget.isEnabled) {
          if (!dueOnly || vocab.cardNativeToTarget.isDue) {
            if (seenCardIds.add(vocab.cardNativeToTarget.id)) {
              queue.add(
                StudyCardItem(
                  vocab: vocab,
                  card: vocab.cardNativeToTarget,
                  lesson: lesson,
                  sentence: getRandomSentenceForVocab(vocab),
                ),
              );
            }
          }
        }
      }
    }

    return queue;
  }

  // Answer SRS review
  Future<void> recordCardReview(SrsCard card, SrsRating rating) async {
    SrsService.processReview(card, rating);
    await saveState();
  }

  Future<void> saveState() async {
    await StorageService.saveLessons(_lessons);
    await StorageService.saveSentences(_sentences);
    notifyListeners();
  }
}
