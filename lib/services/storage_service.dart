import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/ai_discussion_message.dart';
import '../models/lesson.dart';
import '../models/saved_time.dart';
import '../models/sentence.dart';
import '../models/shared_vocab.dart';
import '../models/srs_card.dart';
import '../models/typed_question.dart';
import '../models/vocab_item.dart';
import '../models/vocab_merge_record.dart';
import 'secret_storage.dart';
import 'sync_change_tracker.dart';
import 'sync_pairing.dart';
import 'sync_record_cipher.dart';

class StorageService {
  static const String _keyLessons = 'lingua_srs_lessons';
  static const String _keyLessonMarkdownIds = 'lingua_srs_lesson_markdown_ids';
  static const String _keyImportedMarkdownSources =
      'lingua_srs_imported_markdown_sources';
  static const String _keySentences = 'lingua_srs_sentences';
  static const String _keySharedVocab = 'lingua_srs_shared_vocab';
  static const String _keyDeepSeekApiKey = 'lingua_srs_deepseek_api_key';
  static const String _keySyncPairing = 'lingua_srs_sync_pairing';
  static const String _keySyncState = 'lingua_srs_sync_state';
  static const String _keySyncDataKey = 'lingua_srs_sync_data_key';
  static const String _keySyncLastSyncedAt = 'lingua_srs_sync_last_synced_at';
  static const String _keySyncRemoteActivity =
      'lingua_srs_sync_remote_activity';
  static const String _keyVocabMergeHistory = 'lingua_srs_vocab_merge_history';
  static const String _keyAiDiscussions = 'lingua_srs_ai_discussions';
  static const String _keyTypedQuestions = 'lingua_srs_typed_questions';
  static const String _keyAutoplay = 'lingua_srs_autoplay';
  static const String _keyShowAi = 'lingua_srs_show_ai';
  static const String _keyPronunciation = 'lingua_srs_pronunciation';
  static const String _keyLessonHierarchyOrder =
      'lingua_srs_lesson_hierarchy_order';
  static const String _keyLessonFolderExpansion =
      'lingua_srs_lesson_folder_expansion';
  static const String _keyWindowsMigration =
      'lingua_srs_windows_legacy_migration_complete';

  static const String _keyMaxReviews24h = 'lingua_srs_max_reviews_24h';
  static const String _keyMaxNewCards24h = 'lingua_srs_max_new_cards_24h';
  static const String _keyReviewTimestamps = 'lingua_srs_review_timestamps_24h';
  static const String _keyDailyReviewCounts = 'lingua_srs_daily_review_counts';
  static const String _keyDailyRatingCounts = 'lingua_srs_daily_rating_counts';
  static const String _keyDailyNewCardCounts =
      'lingua_srs_daily_new_card_counts';

  /// Defaults for the rolling 24-hour limits. 0 means unlimited.
  static const int defaultMaxReviews24h = 100;
  static const int defaultMaxNewCards24h = 10;
  static final Map<String, String> _lessonMarkdownCache = {};
  static Set<String> _storedLessonMarkdownIds = {};
  static SecretStorage _secretStorage = const PlatformSecretStorage();

  @visibleForTesting
  static set secretStorageForTesting(SecretStorage? storage) {
    _secretStorage = storage ?? const PlatformSecretStorage();
  }

  static void resetLessonMarkdownCache() {
    _lessonMarkdownCache.clear();
    _storedLessonMarkdownIds = {};
  }

  static Future<String> loadDeepSeekApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    return (await _loadSecret(prefs, _keyDeepSeekApiKey)) ?? '';
  }

  static Future<void> saveDeepSeekApiKey(String apiKey) async {
    final prefs = await SharedPreferences.getInstance();
    final trimmedApiKey = apiKey.trim();
    if (trimmedApiKey.isEmpty) {
      await _secretStorage.delete(_keyDeepSeekApiKey);
    } else {
      await _secretStorage.write(_keyDeepSeekApiKey, trimmedApiKey);
    }
    await prefs.remove(_keyDeepSeekApiKey);
  }

  /// The sync account this device is signed in to, or null when signed out or
  /// the stored link can no longer be read.
  static Future<SyncPairing?> loadSyncPairing() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = await _loadSecret(prefs, _keySyncPairing);
    if (raw == null || raw.isEmpty) return null;
    try {
      return SyncPairing.parse(raw);
    } on FormatException {
      return null;
    }
  }

  /// The unlocked data key of the account this device is signed in to, from
  /// the keychain. Null when there is none, or it cannot be read; the sync
  /// then unlocks it again with the password.
  static Future<SyncDataKey?> loadSyncDataKey() async {
    try {
      final raw = await _secretStorage.read(_keySyncDataKey);
      if (raw == null || raw.isEmpty) return null;
      return SyncDataKey.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
    } catch (error) {
      debugPrint('Could not read the sync data key: $error');
      return null;
    }
  }

  static Future<void> saveSyncDataKey(SyncDataKey? key) async {
    if (key == null) {
      await _secretStorage.delete(_keySyncDataKey);
    } else {
      await _secretStorage.write(_keySyncDataKey, jsonEncode(key.toJson()));
    }
  }

  /// When this device last finished a sync, or null.
  static Future<DateTime?> loadLastSyncedAt() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keySyncLastSyncedAt);
    return raw == null ? null : tryLoadedTime(raw);
  }

  static Future<void> saveLastSyncedAt(DateTime? time) async {
    final prefs = await SharedPreferences.getInstance();
    if (time == null) {
      await prefs.remove(_keySyncLastSyncedAt);
    } else {
      await prefs.setString(_keySyncLastSyncedAt, savedTime(time));
    }
  }

  /// Other devices' study activity, pulled by sync, by `<device id>:<day>`.
  static Future<Map<String, Map<String, dynamic>>>
  loadSyncRemoteActivity() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keySyncRemoteActivity);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw) as Map;
      return {
        for (final entry in decoded.entries)
          entry.key as String: Map<String, dynamic>.from(entry.value as Map),
      };
    } catch (error) {
      debugPrint('Could not read synced activity: $error');
      return {};
    }
  }

  static Future<void> saveSyncRemoteActivity(
    Map<String, Map<String, dynamic>> activity,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keySyncRemoteActivity, jsonEncode(activity));
  }

  /// What this device knows about its synced records. A missing or unreadable
  /// state starts again, which only means every record is pushed once more.
  static Future<SyncChangeTracker> loadSyncChangeTracker() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keySyncState);
    if (raw == null || raw.isEmpty) return SyncChangeTracker();
    try {
      return SyncChangeTracker.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
    } catch (error) {
      debugPrint('Could not read the sync state: $error');
      return SyncChangeTracker();
    }
  }

  static Future<void> saveSyncChangeTracker(SyncChangeTracker tracker) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keySyncState, jsonEncode(tracker.toJson()));
  }

  static Future<void> saveSyncPairing(SyncPairing? pairing) async {
    final prefs = await SharedPreferences.getInstance();
    if (pairing == null) {
      await _secretStorage.delete(_keySyncPairing);
    } else {
      await _secretStorage.write(_keySyncPairing, pairing.link);
    }
    await prefs.remove(_keySyncPairing);
  }

  static Future<String?> _loadSecret(
    SharedPreferences prefs,
    String key,
  ) async {
    final String? value;
    try {
      value = await _secretStorage.read(key);
    } catch (error) {
      // For example a locked or missing keyring on Linux. Starting without the
      // secret is better than not starting, and anything still in preferences
      // is left for the next start.
      debugPrint('Could not read $key from secure storage: $error');
      return null;
    }
    if (value != null) {
      await prefs.remove(key);
      return value;
    }

    final legacyValue = prefs.getString(key);
    if (legacyValue == null) return null;
    if (legacyValue.isNotEmpty) {
      try {
        await _secretStorage.write(key, legacyValue);
      } catch (error) {
        debugPrint('Could not move $key to secure storage: $error');
        return legacyValue; // keep it in preferences until that works
      }
    }
    await prefs.remove(key);
    return legacyValue;
  }

  static Future<List<VocabMergeRecord>> loadMergeHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keyVocabMergeHistory);
    if (raw == null || raw.isEmpty) return [];
    try {
      return (jsonDecode(raw) as List)
          .map(
            (e) =>
                VocabMergeRecord.fromJson(Map<String, dynamic>.from(e as Map)),
          )
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> saveMergeHistory(List<VocabMergeRecord> records) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _keyVocabMergeHistory,
      jsonEncode(records.map((r) => r.toJson()).toList()),
    );
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

  /// Questions typed in AI chats, by id. See `TypedQuestions`.
  static Future<Map<String, TypedQuestion>> loadTypedQuestions() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString(_keyTypedQuestions);
    if (json == null || json.isEmpty) return {};
    return parseTypedQuestions(jsonDecode(json));
  }

  /// [decoded] as stored by [saveTypedQuestions]. Throws a
  /// [FormatException] when it is not.
  static Map<String, TypedQuestion> parseTypedQuestions(Object? decoded) {
    if (decoded is! Map) {
      throw const FormatException('Typed questions must be a map.');
    }
    return {
      for (final entry in decoded.entries)
        entry.key.toString(): entry.value is Map
            ? TypedQuestion.fromJson(Map<String, dynamic>.from(entry.value))
            : throw const FormatException('Invalid typed question.'),
    };
  }

  static Future<void> saveTypedQuestions(
    Map<String, TypedQuestion> questions,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _keyTypedQuestions,
      jsonEncode(
        questions.map((id, question) => MapEntry(id, question.toJson())),
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

  /// Whether AI features are shown on this device. On by default.
  static Future<bool> loadShowAi() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyShowAi) ?? true;
  }

  static Future<void> saveShowAi(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyShowAi, value);
  }

  static Future<Set<String>> loadPronunciationOptions() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_keyPronunciation) ?? const <String>[]).toSet();
  }

  static Future<void> savePronunciationOptions(Set<String> options) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_keyPronunciation, options.toList()..sort());
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
    return prefs.getInt(_keyMaxReviews24h) ?? defaultMaxReviews24h;
  }

  static Future<void> saveMaxReviews24h(int limit) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyMaxReviews24h, limit);
  }

  static Future<int> loadMaxNewCards24h() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_keyMaxNewCards24h) ?? defaultMaxNewCards24h;
  }

  static Future<void> saveMaxNewCards24h(int limit) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyMaxNewCards24h, limit);
  }

  static Future<List<DateTime>> loadReviewTimestamps() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_keyReviewTimestamps) ?? [];
    final now = DateTime.now();
    final valid = <DateTime>[];
    for (final s in list) {
      final dt = tryLoadedTime(s);
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
        .map(savedTime)
        .toList();
    await prefs.setStringList(_keyReviewTimestamps, strings);
  }

  static Future<Map<DateTime, int>> loadDailyReviewCounts() =>
      _loadDayCounts(_keyDailyReviewCounts);

  static Future<void> saveDailyReviewCounts(Map<DateTime, int> counts) =>
      _saveDayCounts(_keyDailyReviewCounts, counts);

  /// New cards started (given their first review) per day, counted since
  /// this was added.
  static Future<Map<DateTime, int>> loadDailyNewCardCounts() =>
      _loadDayCounts(_keyDailyNewCardCounts);

  static Future<void> saveDailyNewCardCounts(Map<DateTime, int> counts) =>
      _saveDayCounts(_keyDailyNewCardCounts, counts);

  /// A count per day, saved as `{"YYYY-MM-DD": count}`.
  static Future<Map<DateTime, int>> _loadDayCounts(String key) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(key);
    if (raw == null || raw.isEmpty) return {};

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final counts = <DateTime, int>{};
      for (final entry in decoded.entries) {
        final date = DateTime.tryParse(entry.key.toString());
        if (date != null && entry.value is int && entry.value > 0) {
          final day = DateTime(date.year, date.month, date.day);
          counts[day] = entry.value as int;
        }
      }
      return counts;
    } catch (_) {
      return {};
    }
  }

  static Future<void> _saveDayCounts(
    String key,
    Map<DateTime, int> counts,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      key,
      jsonEncode({
        for (final entry in counts.entries)
          '${entry.key.year.toString().padLeft(4, '0')}-'
                  '${entry.key.month.toString().padLeft(2, '0')}-'
                  '${entry.key.day.toString().padLeft(2, '0')}':
              entry.value,
      }),
    );
  }

  /// Reviews per day and rating, recorded since ratings were first counted.
  /// Saved as `{"YYYY-MM-DD": {"good": 3, "again": 1}}`.
  static Future<Map<DateTime, Map<SrsRating, int>>>
  loadDailyRatingCounts() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keyDailyRatingCounts);
    if (raw == null || raw.isEmpty) return {};

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final counts = <DateTime, Map<SrsRating, int>>{};
      for (final entry in decoded.entries) {
        final date = DateTime.tryParse(entry.key.toString());
        final ratings = ratingCountsFromJson(entry.value);
        if (date != null && ratings.isNotEmpty) {
          counts[DateTime(date.year, date.month, date.day)] = ratings;
        }
      }
      return counts;
    } catch (_) {
      return {};
    }
  }

  static Future<void> saveDailyRatingCounts(
    Map<DateTime, Map<SrsRating, int>> counts,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _keyDailyRatingCounts,
      jsonEncode({
        for (final entry in counts.entries)
          '${entry.key.year.toString().padLeft(4, '0')}-'
              '${entry.key.month.toString().padLeft(2, '0')}-'
              '${entry.key.day.toString().padLeft(2, '0')}': ratingCountsToJson(
            entry.value,
          ),
      }),
    );
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
        legacy.putIfAbsent(vocab.id, () => []).add(MapEntry(lesson, vocab));
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
