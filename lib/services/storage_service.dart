import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/ai_discussion_message.dart';
import '../models/lesson.dart';
import '../models/sentence.dart';
import '../models/shared_vocab.dart';
import '../models/vocab_item.dart';

class StorageService {
  static const String _keyLessons = 'lingua_srs_lessons';
  static const String _keyLessonMarkdownIds = 'lingua_srs_lesson_markdown_ids';
  static const String _keyImportedMarkdownSources =
      'lingua_srs_imported_markdown_sources';
  static const String _keySentences = 'lingua_srs_sentences';
  static const String _keySharedVocab = 'lingua_srs_shared_vocab';
  static const String _keyDeepSeekApiKey = 'lingua_srs_deepseek_api_key';
  static const String _keyAiDiscussions = 'lingua_srs_ai_discussions';
  static const String _keyAutoplay = 'lingua_srs_autoplay';
  static const String _keyLessonHierarchyOrder =
      'lingua_srs_lesson_hierarchy_order';
  static const String _keyLessonFolderExpansion =
      'lingua_srs_lesson_folder_expansion';
  static const String _keyWindowsMigration =
      'lingua_srs_windows_legacy_migration_complete';

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

  static Future<Map<String, String>> loadImportedMarkdownSources() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString(_keyImportedMarkdownSources);
    if (json == null || json.isEmpty) return {};

    final decoded = jsonDecode(json);
    if (decoded is! Map) {
      throw const FormatException('Imported Markdown sources must be a map.');
    }
    return decoded.map((key, value) {
      if (value is! String) {
        throw FormatException('Invalid source fingerprint for "$key".');
      }
      return MapEntry(key.toString(), value);
    });
  }

  static Future<void> saveImportedMarkdownSources(
    Map<String, String> sources,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyImportedMarkdownSources, jsonEncode(sources));
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
        _bindSharedVocab(prefs, lessons);
        return lessons;
      }
    }

    return [];
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

    final sharedJson = <String, dynamic>{};
    for (final vocab in lessons.expand((l) => l.vocabularies)) {
      sharedJson.putIfAbsent(vocab.id, () => vocab.shared.toJson());
    }
    await prefs.setString(_keySharedVocab, jsonEncode(sharedJson));

    final jsonStr = jsonEncode(lessons.map((l) => l.toJson()).toList());
    await prefs.setString(_keyLessons, jsonStr);
  }

  static void _bindSharedVocab(SharedPreferences prefs, List<Lesson> lessons) {
    var stored = <String, dynamic>{};
    try {
      final raw = prefs.getString(_keySharedVocab);
      if (raw != null && raw.isNotEmpty) {
        stored = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      }
    } catch (_) {}

    final bound = <String, SharedVocab>{};
    final legacy = <String, List<MapEntry<Lesson, VocabItem>>>{};
    for (final lesson in lessons) {
      for (final vocab in lesson.vocabularies) {
        final existing = bound[vocab.id];
        if (existing != null) {
          vocab.shared = existing;
          continue;
        }
        final json = stored[vocab.id];
        if (json != null) {
          try {
            final shared = SharedVocab.fromJson(
              Map<String, dynamic>.from(json as Map),
            );
            bound[vocab.id] = shared;
            vocab.shared = shared;
            continue;
          } catch (_) {}
        }
        legacy
            .putIfAbsent(vocab.id, () => [])
            .add(MapEntry(lesson, vocab));
      }
    }

    // No stored record: merge the per-lesson copies (old format).
    for (final group in legacy.values) {
      final base = group.reduce(
        (a, b) => _isMoreProgressed(b.value, a.value) ? b : a,
      );
      final shared = SharedVocab(
        cardTargetToNative: base.value.cardTargetToNative,
        cardNativeToTarget: base.value.cardNativeToTarget,
      );
      for (final entry in group) {
        for (final field in SharedVocab.detailFields) {
          shared.mergeImport(
            field,
            entry.value.shared.valueOf(field),
            lessonId: entry.key.id,
          );
        }
      }
      for (final entry in group) {
        entry.value.shared = shared;
      }
    }
  }

  static DateTime _lastReviewed(VocabItem v) {
    final a = v.cardTargetToNative.lastReviewed;
    final b = v.cardNativeToTarget.lastReviewed;
    final epoch = DateTime.fromMillisecondsSinceEpoch(0);
    if (a == null) return b ?? epoch;
    if (b == null) return a;
    return a.isAfter(b) ? a : b;
  }

  static bool _isMoreProgressed(VocabItem a, VocabItem b) {
    final byDate = _lastReviewed(a).compareTo(_lastReviewed(b));
    if (byDate != 0) return byDate > 0;
    int reps(VocabItem v) =>
        v.cardTargetToNative.repetitions + v.cardNativeToTarget.repetitions;
    return reps(a) > reps(b);
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

    if (!currentStoreIsEmpty) {
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
}
