import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Where lessons' Markdown is kept: a file per lesson in the app's support
/// folder, or, on the web, which has no files, a preference per lesson (the
/// browser's local storage).
class LessonMarkdownStore {
  final SharedPreferences _prefs;
  final Directory? _directory;

  LessonMarkdownStore._(this._prefs, this._directory);

  static Future<LessonMarkdownStore> open(SharedPreferences prefs) async =>
      LessonMarkdownStore._(
        prefs,
        kIsWeb ? null : await getApplicationSupportDirectory(),
      );

  /// A store that keeps Markdown in [prefs] alone, as on the web, for tests.
  @visibleForTesting
  static LessonMarkdownStore inPreferences(SharedPreferences prefs) =>
      LessonMarkdownStore._(prefs, null);

  static String _safeId(String lessonId) =>
      base64Url.encode(utf8.encode(lessonId)).replaceAll('=', '');

  /// The preference that keeps a lesson's Markdown on the web. It does not
  /// start with `lingua_srs_`, so a backup does not take it as a setting:
  /// backups carry lessons' Markdown on their own.
  static String prefsKey(String lessonId) =>
      'lesson_markdown_${_safeId(lessonId)}';

  File _file(Directory directory, String lessonId) => File(
    '${directory.path}${Platform.pathSeparator}lesson_markdown'
    '${Platform.pathSeparator}${_safeId(lessonId)}.md',
  );

  Future<String?> read(String lessonId) async {
    final directory = _directory;
    if (directory == null) return _prefs.getString(prefsKey(lessonId));
    final file = _file(directory, lessonId);
    if (!await file.exists()) return null;
    return file.readAsString();
  }

  Future<void> write(String lessonId, String markdown) async {
    final directory = _directory;
    if (directory == null) {
      await _prefs.setString(prefsKey(lessonId), markdown);
      return;
    }
    final file = _file(directory, lessonId);
    await file.parent.create(recursive: true);
    await file.writeAsString(markdown, flush: true);
  }

  Future<void> delete(String lessonId) async {
    final directory = _directory;
    if (directory == null) {
      await _prefs.remove(prefsKey(lessonId));
      return;
    }
    final file = _file(directory, lessonId);
    if (await file.exists()) await file.delete();
  }
}
