import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/ai_discussion_message.dart';
import '../models/lesson.dart';
import '../models/sentence.dart';
import '../models/shared_vocab.dart';
import '../models/vocab_merge_record.dart';
import 'storage_service.dart';

class BackupService {
  static const _format = 'lingua_srs_backup';
  static const _version = 1;
  static const _keyPrefix = 'lingua_srs_';
  static const _keyDeepSeekApiKey = 'lingua_srs_deepseek_api_key';
  static const _keySyncPairing = 'lingua_srs_sync_pairing';
  static const _keySyncState = 'lingua_srs_sync_state';
  static const _keySyncLastSyncedAt = 'lingua_srs_sync_last_synced_at';

  /// Secrets and sync state that stay on the device: never written to a
  /// backup, and left alone by a restore.
  static const _deviceOnlyKeys = {
    _keyDeepSeekApiKey,
    _keySyncPairing,
    _keySyncState,
    _keySyncLastSyncedAt,
  };
  static const _keyLessonMarkdownIds = 'lingua_srs_lesson_markdown_ids';
  static const _stringPreferenceKeys = {
    'lingua_srs_lessons',
    'lingua_srs_imported_markdown_sources',
    'lingua_srs_sentences',
    'lingua_srs_shared_vocab',
    'lingua_srs_vocab_merge_history',
    'lingua_srs_ai_discussions',
    'lingua_srs_lesson_hierarchy_order',
    'lingua_srs_lesson_folder_expansion',
  };
  static const _stringListPreferenceKeys = {
    _keyLessonMarkdownIds,
    'lingua_srs_pronunciation',
    'lingua_srs_review_timestamps_24h',
  };

  static Future<String> createBackup() async {
    final prefs = await SharedPreferences.getInstance();
    final preferences = <String, Object>{};
    for (final key in prefs.getKeys()) {
      if (!key.startsWith(_keyPrefix) || _deviceOnlyKeys.contains(key)) {
        continue;
      }
      final value = prefs.get(key);
      if (!_isSupportedPreference(value)) {
        throw StateError('Unsupported preference value for "$key".');
      }
      preferences[key] = value is List<String>
          ? List<String>.from(value)
          : value!;
    }

    final directory = await getApplicationSupportDirectory();
    final lessonMarkdown = <String, String>{};
    final markdownIds =
        (preferences[_keyLessonMarkdownIds] as List<String>?) ?? const [];
    for (final id in markdownIds) {
      final file = _markdownFile(directory, id);
      if (await file.exists()) {
        lessonMarkdown[id] = await file.readAsString();
      }
    }
    preferences[_keyLessonMarkdownIds] = lessonMarkdown.keys.toList();

    return jsonEncode({
      'format': _format,
      'version': _version,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'preferences': preferences,
      'lessonMarkdown': lessonMarkdown,
    });
  }

  static Future<void> restoreBackup(String backup) async {
    final decoded = jsonDecode(backup);
    if (decoded is! Map ||
        decoded['format'] != _format ||
        decoded['version'] != _version ||
        decoded['preferences'] is! Map ||
        decoded['lessonMarkdown'] is! Map) {
      throw const FormatException('Unsupported LinguaSRS backup.');
    }

    final preferences = Map<String, dynamic>.from(
      decoded['preferences'] as Map,
    );
    final lessonMarkdown = Map<String, dynamic>.from(
      decoded['lessonMarkdown'] as Map,
    );
    if (preferences.entries.any(
          (entry) =>
              !entry.key.startsWith(_keyPrefix) ||
              _deviceOnlyKeys.contains(entry.key) ||
              !_isValidPreference(entry.key, entry.value),
        ) ||
        lessonMarkdown.entries.any((entry) => entry.value is! String)) {
      throw const FormatException('Invalid LinguaSRS backup data.');
    }
    for (final entry in preferences.entries.toList()) {
      if (entry.value is List) {
        preferences[entry.key] = (entry.value as List).cast<String>().toList();
      }
    }

    final markdownIds =
        (preferences[_keyLessonMarkdownIds] as List<String>?) ?? const [];
    if (lessonMarkdown.keys
            .toSet()
            .difference(markdownIds.toSet())
            .isNotEmpty ||
        markdownIds
            .toSet()
            .difference(lessonMarkdown.keys.toSet())
            .isNotEmpty) {
      throw const FormatException('Invalid lesson Markdown in backup.');
    }
    _validateStoredData(preferences);

    final prefs = await SharedPreferences.getInstance();
    final previousMarkdownIds =
        prefs.getStringList(_keyLessonMarkdownIds) ?? const [];
    final directory = await getApplicationSupportDirectory();
    await _writeLessonMarkdown(directory, lessonMarkdown);
    for (final id in previousMarkdownIds.toSet().difference(
      markdownIds.toSet(),
    )) {
      final file = _markdownFile(directory, id);
      if (await file.exists()) await file.delete();
    }

    for (final key in prefs.getKeys()) {
      if (key.startsWith(_keyPrefix) && !_deviceOnlyKeys.contains(key)) {
        await prefs.remove(key);
      }
    }
    for (final entry in preferences.entries) {
      final value = entry.value;
      if (value is String) {
        await prefs.setString(entry.key, value);
      } else if (value is bool) {
        await prefs.setBool(entry.key, value);
      } else if (value is int) {
        await prefs.setInt(entry.key, value);
      } else if (value is double) {
        await prefs.setDouble(entry.key, value);
      } else if (value is List<String>) {
        await prefs.setStringList(entry.key, value);
      }
    }
    StorageService.resetLessonMarkdownCache();
  }

  static void _validateStoredData(Map<String, dynamic> preferences) {
    try {
      final lessons = _decodePreference(preferences, 'lingua_srs_lessons');
      if (lessons != null) {
        if (lessons is! List) throw const FormatException();
        for (final lesson in lessons) {
          Lesson.fromJson(Map<String, dynamic>.from(lesson as Map));
        }
      }
      final sentences = _decodePreference(preferences, 'lingua_srs_sentences');
      if (sentences != null) {
        if (sentences is! List) throw const FormatException();
        for (final sentence in sentences) {
          Sentence.fromJson(Map<String, dynamic>.from(sentence as Map));
        }
      }

      final importedSources = _decodePreference(
        preferences,
        'lingua_srs_imported_markdown_sources',
      );
      if (importedSources != null &&
          (importedSources is! Map ||
              importedSources.values.any((value) => value is! String))) {
        throw const FormatException();
      }

      final sharedVocab = _decodePreference(
        preferences,
        'lingua_srs_shared_vocab',
      );
      if (sharedVocab != null) {
        if (sharedVocab is! Map) throw const FormatException();
        for (final shared in sharedVocab.values) {
          SharedVocab.fromJson(Map<String, dynamic>.from(shared as Map));
        }
      }

      final mergeHistory = _decodePreference(
        preferences,
        'lingua_srs_vocab_merge_history',
      );
      if (mergeHistory != null) {
        if (mergeHistory is! List) throw const FormatException();
        for (final record in mergeHistory) {
          VocabMergeRecord.fromJson(Map<String, dynamic>.from(record as Map));
        }
      }

      final discussions = _decodePreference(
        preferences,
        'lingua_srs_ai_discussions',
      );
      if (discussions != null) {
        if (discussions is! Map) throw const FormatException();
        for (final messages in discussions.values) {
          if (messages is! List) throw const FormatException();
          for (final message in messages) {
            AiDiscussionMessage.fromJson(
              Map<String, dynamic>.from(message as Map),
            );
          }
        }
      }

      final hierarchyOrder = _decodePreference(
        preferences,
        'lingua_srs_lesson_hierarchy_order',
      );
      if (hierarchyOrder != null &&
          (hierarchyOrder is! Map ||
              hierarchyOrder.values.any((value) => value is! int))) {
        throw const FormatException();
      }

      final folderExpansion = _decodePreference(
        preferences,
        'lingua_srs_lesson_folder_expansion',
      );
      if (folderExpansion != null &&
          (folderExpansion is! Map ||
              folderExpansion.values.any((value) => value is! bool))) {
        throw const FormatException();
      }
    } catch (_) {
      throw const FormatException('Invalid app data in backup.');
    }
  }

  static Object? _decodePreference(
    Map<String, dynamic> preferences,
    String key,
  ) {
    final value = preferences[key];
    return value == null ? null : jsonDecode(value as String);
  }

  static bool _isValidPreference(String key, Object? value) {
    if (!_isSupportedPreference(value)) return false;
    if (_stringPreferenceKeys.contains(key)) return value is String;
    if (_stringListPreferenceKeys.contains(key)) {
      return value is List && value.every((item) => item is String);
    }
    if (key == 'lingua_srs_max_reviews_24h' ||
        key == 'lingua_srs_max_new_cards_24h') {
      return value is int;
    }
    if (key == 'lingua_srs_autoplay' ||
        key == 'lingua_srs_show_ai' ||
        key == 'lingua_srs_windows_legacy_migration_complete') {
      return value is bool;
    }
    return true;
  }

  static bool _isSupportedPreference(Object? value) =>
      value is String ||
      value is bool ||
      value is int ||
      value is double ||
      (value is List && value.every((item) => item is String));

  static Future<void> _writeLessonMarkdown(
    Directory directory,
    Map<String, dynamic> lessonMarkdown,
  ) async {
    for (final entry in lessonMarkdown.entries) {
      final file = _markdownFile(directory, entry.key);
      await file.parent.create(recursive: true);
      await file.writeAsString(entry.value as String, flush: true);
    }
  }

  static File _markdownFile(Directory directory, String lessonId) {
    final safeId = base64Url.encode(utf8.encode(lessonId)).replaceAll('=', '');
    return File(
      '${directory.path}${Platform.pathSeparator}lesson_markdown'
      '${Platform.pathSeparator}$safeId.md',
    );
  }
}
