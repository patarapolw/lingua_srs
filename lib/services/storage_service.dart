import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/lesson.dart';
import '../models/sentence.dart';
import '../models/srs_card.dart';
import '../models/vocab_item.dart';
import 'yaml_parser_service.dart';

class StorageService {
  static const String _keyLessons = 'lingua_srs_lessons';
  static const String _keyLessonMarkdownIds = 'lingua_srs_lesson_markdown_ids';
  static const String _keySentences = 'lingua_srs_sentences';
  static const String _keyAutoplay = 'lingua_srs_autoplay';
  static const String _keyLessonHierarchyOrder =
      'lingua_srs_lesson_hierarchy_order';
  static const String _keyLessonFolderExpansion =
      'lingua_srs_lesson_folder_expansion';
  static const String _keyWindowsMigration =
      'lingua_srs_windows_legacy_migration_complete';

  static const String defaultSampleYaml = '''
Lesson: Unit 2/Lesson 26

nouns:
  - ko: 아줌마
    audio: https://example.com/audio/2016/01/Lesson26v2.mp3
    en: middle aged/older woman
    notes: |
      <p>The word "아주머니" is commonly used as well</p>
      <p>아줌마 and 아주머니 are commonly used to refer to an older woman that you don't know the name of, or even do know the name of but aren't close enough to call her by her name. This also extends to older women who work in a restaurant.</p>
      <p>The age that you could call a female an "아줌마" is ambiguous, but I would say that somewhere between late-thirties to mid-sixties would be appropriate. Any younger, and you would probably be offending a younger woman by thinking she is too old. Any older, and you are better off calling the woman "할머니."</p>
    examples:
      - ko: 저는 **아줌마**를 위해 문을 열었어요
        en: I opened the door for **an older lady**

  - ko: 물건
    audio: https://example.com/audio/2016/01/Lesson26v3.mp3
    en: thing, item, goods
    examples:
      - ko: "제가 산 **물건**을 언제 받을 수 있어요?"
        en: When can I receive the **goods** I purchased?
      - ko: 한국에서는 세금이 **물건** 값에 포함돼요
        en: In Korea, tax is included in the price of **goods**

  - ko: 복도
    audio: https://example.com/audio/2016/01/Lesson26v4.mp3
    en: hall, hallway
    notes: The pronunciation of this word is closer to "복또"
    examples:
      - ko: "**복도**에서 달리는 것은 위험해요"
        audio: https://example.com/audio/2016/02/Lesson26s14.mp3
        en: It is dangerous to run in the **hallway**
      - ko: 이 **복도**를 걸레로 다 청소하는 데 시간이 많이 필요할 것 같아요
        en: It will probably take a long time to clean this **hallway** with just a rag

  - ko: 목적
    audio: https://example.com/audio/2016/01/Lesson26v5.mp3
    en: purpose, aim, goal
    notes: The pronunciation of this word is closer to "목쩍"
    examples:
      - ko: 저는 **목적**을 이루지 못했어요
        en: I couldn't achieve my **goal**
      - ko: "우리 학교의 **목적**은 국제고등학교가 되는 것이다"
        audio: https://example.com/audio/2016/02/Lesson26s6.mp3
        en: Our school's **goal** is becoming an international school
      - ko: 친구와 여행의 **목적**을 정하고 여행 일정을 대충 만들었어요
        en: I set the **goals** of the trip with my friend and then made rough travel plans

verbs:
  - ko: 도착하다
    en: to arrive
    notes: Regular verb. Followed by 에 for destination.
    examples:
      - ko: 우리는 공항에 정각에 **도착했어요**
        en: We arrived at the airport on time
      - ko: 기차가 곧 **도착할** 거예요
        en: The train will arrive soon

adjectives:
  - ko: 복잡하다
    en: complicated, crowded
    notes: Used for complicated situations or crowded streets/places.
    examples:
      - ko: 이 문제는 너무 **복잡해요**
        en: This problem is too complicated
      - ko: 출퇴근 시간에 지하철은 매우 **복잡해요**
        en: The subway is very crowded during rush hour
''';

  static const String _keyMaxReviews24h = 'lingua_srs_max_reviews_24h';
  static const String _keyReviewTimestamps = 'lingua_srs_review_timestamps_24h';
  static final Map<String, String> _lessonMarkdownCache = {};
  static Set<String> _storedLessonMarkdownIds = {};

  static Future<bool> loadAutoplay() async {
    final prefs = await SharedPreferences.getInstance();
    await _migrateLegacyWindowsPreferences(prefs);
    return prefs.getBool(_keyAutoplay) ?? true;
  }

  static Future<void> saveAutoplay(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyAutoplay, value);
  }

  static Future<Map<String, int>> loadLessonHierarchyOrder() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString(_keyLessonHierarchyOrder);
    if (json == null || json.isEmpty) return {};

    final decoded = jsonDecode(json);
    if (decoded is! Map) {
      throw const FormatException('Lesson hierarchy order must be a map.');
    }
    return decoded.map((key, value) {
      if (value is! int) {
        throw FormatException('Invalid order value for "$key".');
      }
      return MapEntry(key.toString(), value);
    });
  }

  static Future<void> saveLessonHierarchyOrder(
    Map<String, int> order,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyLessonHierarchyOrder, jsonEncode(order));
  }

  static Future<Map<String, bool>> loadLessonFolderExpansion() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString(_keyLessonFolderExpansion);
    if (json == null || json.isEmpty) return {};

    final decoded = jsonDecode(json);
    if (decoded is! Map) {
      throw const FormatException('Lesson folder expansion must be a map.');
    }
    return decoded.map((key, value) {
      if (value is! bool) {
        throw FormatException('Invalid expansion value for "$key".');
      }
      return MapEntry(key.toString(), value);
    });
  }

  static Future<void> saveLessonFolderExpansion(
    Map<String, bool> expansion,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyLessonFolderExpansion, jsonEncode(expansion));
  }

  static Future<int> loadMaxReviews24h() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_keyMaxReviews24h) ?? 100;
  }

  static Future<void> saveMaxReviews24h(int limit) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyMaxReviews24h, limit);
  }

  static Future<List<DateTime>> loadReviewTimestamps() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_keyReviewTimestamps) ?? [];
    final now = DateTime.now();
    final valid = <DateTime>[];
    for (final s in list) {
      final dt = DateTime.tryParse(s);
      if (dt != null && now.difference(dt).inHours < 24) {
        valid.add(dt);
      }
    }
    return valid;
  }

  static Future<void> saveReviewTimestamps(List<DateTime> timestamps) async {
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now();
    final strings = timestamps
        .where((t) => now.difference(t).inHours < 24)
        .map((t) => t.toIso8601String())
        .toList();
    await prefs.setStringList(_keyReviewTimestamps, strings);
  }

  static Future<List<Sentence>> loadSentences() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(_keySentences);
    if (jsonStr == null || jsonStr.isEmpty) return [];

    try {
      final List<dynamic> list = jsonDecode(jsonStr);
      return list
          .map((e) => Sentence.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (e) {
      return [];
    }
  }

  static Future<void> saveSentences(List<Sentence> sentences) async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = jsonEncode(sentences.map((s) => s.toJson()).toList());
    await prefs.setString(_keySentences, jsonStr);
  }

  static Future<List<Lesson>> loadLessons() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(_keyLessons);

    if (jsonStr != null && jsonStr.isNotEmpty) {
      List<Lesson>? lessons;
      try {
        final List<dynamic> list = jsonDecode(jsonStr);
        lessons = list
            .map((e) => Lesson.fromJson(Map<String, dynamic>.from(e)))
            .toList();
      } catch (e) {
        // Fallback to sample
      }
      if (lessons != null) {
        await _loadLessonMarkdown(prefs, lessons);
        return lessons;
      }
    }

    // Default sample on first run
    final parsed = YamlParserService.parseLessonYaml(defaultSampleYaml);
    await saveLessons([parsed.lesson]);
    await saveSentences(parsed.sentences);
    final lessons = [parsed.lesson];
    await _loadLessonMarkdown(prefs, lessons);
    return lessons;
  }

  static Future<void> saveLessons(List<Lesson> lessons) async {
    final prefs = await SharedPreferences.getInstance();
    final markdownIds = <String>[];
    if (lessons.any((lesson) => lesson.markdownContent.isNotEmpty) ||
        _storedLessonMarkdownIds.isNotEmpty ||
        prefs.getStringList(_keyLessonMarkdownIds)?.isNotEmpty == true) {
      final directory = await getApplicationSupportDirectory();
      final previousIds = {
        ..._storedLessonMarkdownIds,
        ...?prefs.getStringList(_keyLessonMarkdownIds),
      };
      final markdownDirectory = Directory(
        '${directory.path}${Platform.pathSeparator}lesson_markdown',
      );
      for (final lesson in lessons) {
        final markdown = lesson.markdownContent;
        if (markdown.isEmpty) continue;
        markdownIds.add(lesson.id);
        if (_lessonMarkdownCache[lesson.id] == markdown) continue;

        await markdownDirectory.create(recursive: true);
        await _markdownFile(
          directory,
          lesson.id,
        ).writeAsString(markdown, flush: true);
        _lessonMarkdownCache[lesson.id] = markdown;
      }
      for (final removedId in previousIds.difference(markdownIds.toSet())) {
        final file = _markdownFile(directory, removedId);
        if (await file.exists()) await file.delete();
        _lessonMarkdownCache.remove(removedId);
      }
      _storedLessonMarkdownIds = markdownIds.toSet();
      await prefs.setStringList(_keyLessonMarkdownIds, markdownIds);
    }

    final jsonStr = jsonEncode(lessons.map((l) => l.toJson()).toList());
    await prefs.setString(_keyLessons, jsonStr);
  }

  static Future<void> _loadLessonMarkdown(
    SharedPreferences prefs,
    List<Lesson> lessons,
  ) async {
    final ids = prefs.getStringList(_keyLessonMarkdownIds) ?? const [];
    if (ids.isEmpty) {
      _storedLessonMarkdownIds = {};
      return;
    }

    final directory = await getApplicationSupportDirectory();
    final lessonsById = {for (final lesson in lessons) lesson.id: lesson};
    for (final id in ids) {
      final lesson = lessonsById[id];
      if (lesson == null) continue;
      final file = _markdownFile(directory, id);
      if (!await file.exists()) {
        debugPrint(
          'Markdown content for lesson "$id" is missing from storage.',
        );
        continue;
      }
      final markdown = await file.readAsString();
      lesson.markdownContent = markdown;
      _lessonMarkdownCache[id] = markdown;
    }
    _storedLessonMarkdownIds = ids.toSet();
  }

  static File _markdownFile(Directory directory, String lessonId) {
    final safeId = base64Url.encode(utf8.encode(lessonId)).replaceAll('=', '');
    return File(
      '${directory.path}${Platform.pathSeparator}lesson_markdown'
      '${Platform.pathSeparator}$safeId.md',
    );
  }

  static Future<void> _migrateLegacyWindowsPreferences(
    SharedPreferences prefs,
  ) async {
    if (!Platform.isWindows || prefs.getBool(_keyWindowsMigration) == true) {
      return;
    }

    final roamingPath = Platform.environment['APPDATA'];
    if (roamingPath == null || roamingPath.isEmpty) return;

    final legacyFile = File(
      '$roamingPath${Platform.pathSeparator}com.example${Platform.pathSeparator}'
      'lingua_srs${Platform.pathSeparator}shared_preferences.json',
    );
    if (!await legacyFile.exists()) {
      await prefs.setBool(_keyWindowsMigration, true);
      return;
    }

    final Object? decodedLegacyStore;
    try {
      decodedLegacyStore = jsonDecode(await legacyFile.readAsString());
    } on FormatException catch (error) {
      debugPrint('Legacy LinguaSRS preferences could not be decoded: $error');
      return;
    }
    if (decodedLegacyStore is! Map) {
      debugPrint(
        'Legacy LinguaSRS preferences have an invalid format; migration was skipped.',
      );
      return;
    }
    final legacyStore = Map<String, dynamic>.from(decodedLegacyStore);
    final legacyLessons = legacyStore['flutter.$_keyLessons'];
    final legacySentences = legacyStore['flutter.$_keySentences'];
    if (legacyLessons is! String ||
        legacySentences is! String ||
        !_isValidStoredLessonData(legacyLessons, legacySentences)) {
      debugPrint(
        'Legacy LinguaSRS preferences were found but are invalid; migration was skipped.',
      );
      return;
    }

    final currentLessons = prefs.getString(_keyLessons);
    final currentSentences = prefs.getString(_keySentences);
    final currentStoreIsEmpty =
        currentLessons == null && currentSentences == null;
    final currentStoreIsFreshSample =
        currentLessons != null &&
        currentSentences != null &&
        _isPristineSampleData(currentLessons, currentSentences);

    if (!currentStoreIsEmpty && !currentStoreIsFreshSample) {
      await prefs.setBool(_keyWindowsMigration, true);
      debugPrint(
        'Existing LinguaSRS preferences were preserved; legacy migration was not needed.',
      );
      return;
    }

    await prefs.setString(_keyLessons, legacyLessons);
    await prefs.setString(_keySentences, legacySentences);
    final legacyAutoplay = legacyStore['flutter.$_keyAutoplay'];
    if (legacyAutoplay is bool) {
      await prefs.setBool(_keyAutoplay, legacyAutoplay);
    }
    await prefs.setBool(_keyWindowsMigration, true);
    debugPrint(
      'Migrated LinguaSRS preferences from the previous Windows app data directory.',
    );
  }

  static bool _isValidStoredLessonData(
    String lessonsJson,
    String sentencesJson,
  ) {
    try {
      final lessonsData = jsonDecode(lessonsJson);
      final sentencesData = jsonDecode(sentencesJson);
      if (lessonsData is! List || sentencesData is! List) return false;

      for (final lessonData in lessonsData) {
        Lesson.fromJson(Map<String, dynamic>.from(lessonData as Map));
      }
      for (final sentenceData in sentencesData) {
        Sentence.fromJson(Map<String, dynamic>.from(sentenceData as Map));
      }
      return true;
    } on FormatException {
      return false;
    } on TypeError {
      return false;
    }
  }

  static bool _isPristineSampleData(String lessonsJson, String sentencesJson) {
    try {
      final lessonsData = jsonDecode(lessonsJson);
      final sentencesData = jsonDecode(sentencesJson);
      if (lessonsData is! List ||
          lessonsData.length != 1 ||
          sentencesData is! List) {
        return false;
      }

      final currentLesson = Lesson.fromJson(
        Map<String, dynamic>.from(lessonsData.single as Map),
      );
      final currentSentences = sentencesData
          .map(
            (sentence) =>
                Sentence.fromJson(Map<String, dynamic>.from(sentence as Map)),
          )
          .toList();
      final sample = YamlParserService.parseLessonYaml(defaultSampleYaml);
      if (currentLesson.title != sample.lesson.title ||
          currentLesson.targetLanguage != sample.lesson.targetLanguage ||
          currentLesson.nativeLanguage != sample.lesson.nativeLanguage ||
          currentLesson.vocabularies.length !=
              sample.lesson.vocabularies.length ||
          !_haveSameSentenceContent(currentSentences, sample.sentences)) {
        return false;
      }

      final currentSentencesById = {
        for (final sentence in currentSentences) sentence.id: sentence,
      };
      for (var index = 0; index < sample.lesson.vocabularies.length; index++) {
        final currentVocab = currentLesson.vocabularies[index];
        final sampleVocab = sample.lesson.vocabularies[index];
        if (currentVocab.targetWord != sampleVocab.targetWord ||
            currentVocab.translation != sampleVocab.translation ||
            currentVocab.pos != sampleVocab.pos ||
            (currentVocab.audioUrl != sampleVocab.audioUrl &&
                !_hasLegacySampleAudio(currentVocab)) ||
            currentVocab.notes != sampleVocab.notes ||
            !_isNewDefaultCard(
              currentVocab.cardTargetToNative,
              sampleVocab.cardTargetToNative,
            ) ||
            !_isNewDefaultCard(
              currentVocab.cardNativeToTarget,
              sampleVocab.cardNativeToTarget,
            )) {
          return false;
        }

        final linkedSentences = currentVocab.sentenceIds
            .map((id) => currentSentencesById[id])
            .whereType<Sentence>()
            .toList();
        final sampleLinkedSentences = sampleVocab.sentenceIds
            .map(
              (id) => sample.sentences
                  .where((sentence) => sentence.id == id)
                  .single,
            )
            .toList();
        if (linkedSentences.length != currentVocab.sentenceIds.length ||
            !_haveSameSentenceContent(linkedSentences, sampleLinkedSentences)) {
          return false;
        }
      }
      return true;
    } on FormatException {
      return false;
    } on TypeError {
      return false;
    } on StateError {
      return false;
    }
  }

  static bool _isNewDefaultCard(SrsCard card, SrsCard expectedCard) {
    return card.isEnabled == expectedCard.isEnabled &&
        card.interval == 0 &&
        card.repetitions == 0 &&
        card.easeFactor == 2.5 &&
        card.lastReviewed == null &&
        card.status == SrsStatus.isNew;
  }

  static bool _hasLegacySampleAudio(VocabItem vocab) {
    return (vocab.targetWord == '도착하다' &&
            vocab.audioUrl ==
                'https://example.com/audio/2016/01/Lesson26v8.mp3') ||
        (vocab.targetWord == '복잡하다' &&
            vocab.audioUrl ==
                'https://example.com/audio/2016/01/Lesson26v15.mp3');
  }

  static bool _haveSameSentenceContent(
    List<Sentence> first,
    List<Sentence> second,
  ) {
    if (first.length != second.length) return false;
    String signature(Sentence sentence) =>
        '${sentence.targetText}\u0000${sentence.translationText}\u0000${sentence.audioUrl ?? ''}';
    final firstSignatures = first.map(signature).toList()..sort();
    final secondSignatures = second.map(signature).toList()..sort();
    for (var index = 0; index < firstSignatures.length; index++) {
      if (firstSignatures[index] != secondSignatures[index]) return false;
    }
    return true;
  }
}
