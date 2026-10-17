import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/ai_discussion_message.dart';
import '../models/lesson.dart';
import '../models/sentence.dart';
import '../models/srs_card.dart';
import 'yaml_parser_service.dart';

class StorageService {
  static const String _keyLessons = 'lingua_srs_lessons';
  static const String _keyLessonMarkdownIds = 'lingua_srs_lesson_markdown_ids';
  static const String _keySentences = 'lingua_srs_sentences';
  static const String _keyDeepSeekApiKey = 'lingua_srs_deepseek_api_key';
  static const String _keyAiDiscussions = 'lingua_srs_ai_discussions';
  static const String _keyAutoplay = 'lingua_srs_autoplay';
  static const String _keyLessonHierarchyOrder =
      'lingua_srs_lesson_hierarchy_order';
  static const String _keyLessonFolderExpansion =
      'lingua_srs_lesson_folder_expansion';
  static const String _keyWindowsMigration =
      'lingua_srs_windows_legacy_migration_complete';

  /// Debug-only seed lesson: Markdown with YAML frontmatter that exercises the
  /// lesson reader (headings, lists, tables, code, quotes, spoilers, TTS).
  static const String debugSeedMarkdown = '''
---
vocabulary:
  nouns:
    - ko: 아줌마
      en: middle aged/older woman
      notes: |
        Commonly used for an older woman whose name you do not know.

        * Polite alternative: **아주머니**
        * Use **할머니** for a much older woman.
      examples:
        - ko: 저는 **아줌마**를 위해 문을 열었어요
          en: I opened the door for **an older lady**
          notes: "Cloze test: the bold word is hidden on EN ➔ KO cards."
    - ko: 물건
      en: thing, item, goods
      examples:
        - ko: "제가 산 **물건**을 언제 받을 수 있어요?"
          en: When can I receive the **goods** I purchased?
        - ko: 가게에 **물건**이 많아요
          en: There are many **items** in the shop
    - ko: 복도
      en: hall, hallway
      notes: The pronunciation is closer to "복또".
      examples:
        - ko: "**복도**에서 달리면 위험해요"
          en: It is dangerous to run in the **hallway**
  verbs:
    - ko: 도착하다
      en: to arrive
      notes: Regular verb. Followed by 에 for the destination.
      examples:
        - ko: 우리는 공항에 정각에 **도착했어요**
          en: We arrived at the airport on time
        - ko: 기차가 곧 **도착할** 거예요
          en: The train will arrive soon
  adjectives:
    - ko: 복잡하다
      en: complicated, crowded
      notes: Used for complicated situations or crowded places.
      examples:
        - ko: 이 문제는 너무 **복잡해요**
          en: This problem is too complicated
        - ko: 출퇴근 시간에 지하철은 매우 **복잡해요**
          en: The subway is very crowded during rush hour
---

# Debug Seed::Markdown Rendering

This lesson is generated debug data for checking Markdown rendering in the
lesson reader. It is only seeded on a fresh debug install.

## Text styles

**Bold**, *italic*, ~~strikethrough~~, `inline code`, and a
[link](https://example.com).

## Lists

1. First item
2. Second item
   * Nested bullet
   * Another nested bullet
3. Third item

- [x] Task list item (done)
- [ ] Task list item (todo)

## Table

| Pattern | Meaning | Example |
|---------|---------|---------|
| 았/었어요 | past tense | 도착했어요 |
| 을/를 | object marker | 물건을 |
| 에 | destination | 공항에 |

## Quote and code

> Notes and warnings can be written as block quotes.

```text
Fenced code blocks keep their spacing.
  도착하다 -> 도착했어요
```

---

## Lesson components

Read aloud: <TTS>안녕하세요, 만나서 반갑습니다.</TTS>

Hidden answer: <span class="spoiler">정답은 **복잡해요**</span> (hover or tap to reveal).

## Long section

Paragraph for scrolling. 한국어 문장을 천천히 읽어 보세요.

Another paragraph for scrolling. 문장을 소리 내어 읽어 보세요.
''';

  static const String _keyMaxReviews24h = 'lingua_srs_max_reviews_24h';
  static const String _keyReviewTimestamps = 'lingua_srs_review_timestamps_24h';
  static final Map<String, String> _lessonMarkdownCache = {};
  static Set<String> _storedLessonMarkdownIds = {};

  static Future<String> loadDeepSeekApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyDeepSeekApiKey) ?? '';
  }

  static Future<void> saveDeepSeekApiKey(String apiKey) async {
    final prefs = await SharedPreferences.getInstance();
    final trimmedApiKey = apiKey.trim();
    if (trimmedApiKey.isEmpty) {
      await prefs.remove(_keyDeepSeekApiKey);
    } else {
      await prefs.setString(_keyDeepSeekApiKey, trimmedApiKey);
    }
  }

  static Future<Map<String, List<AiDiscussionMessage>>>
  loadAiDiscussions() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString(_keyAiDiscussions);
    if (json == null || json.isEmpty) return {};

    final decoded = jsonDecode(json);
    if (decoded is! Map) {
      throw const FormatException('AI discussions must be a map.');
    }
    final discussions = <String, List<AiDiscussionMessage>>{};
    for (final entry in decoded.entries) {
      if (entry.value is! List) {
        throw FormatException(
          'Invalid AI discussion history for "${entry.key}".',
        );
      }
      discussions[entry.key.toString()] = (entry.value as List).map((message) {
        if (message is! Map) {
          throw const FormatException('Invalid AI discussion message.');
        }
        return AiDiscussionMessage.fromJson(Map<String, dynamic>.from(message));
      }).toList();
    }
    return discussions;
  }

  static Future<void> saveAiDiscussions(
    Map<String, List<AiDiscussionMessage>> discussions,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _keyAiDiscussions,
      jsonEncode(
        discussions.map(
          (key, messages) => MapEntry(
            key,
            messages.map((message) => message.toJson()).toList(),
          ),
        ),
      ),
    );
  }

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

  static Future<void> saveLessonHierarchyOrder(Map<String, int> order) async {
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

    // Debug seed data is for development only; release builds start empty.
    if (!kDebugMode) return [];

    final parsed = YamlParserService.parseLessonYaml(debugSeedMarkdown);
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
      final sample = YamlParserService.parseLessonYaml(debugSeedMarkdown);
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
            currentVocab.audioUrl != sampleVocab.audioUrl ||
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
