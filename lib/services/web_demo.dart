import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'yaml_parser_service.dart';

/// The web build is a demo (#277): flashcards and lessons only. It has no AI
/// features and no sync, so it needs no server and sends nothing to one; all
/// data stays in the browser's storage.
abstract final class WebDemo {
  static bool? _override;

  /// Whether this build is the web demo: true on the web.
  static bool get enabled => _override ?? kIsWeb;

  /// Makes [enabled] return [value] (null: back to [kIsWeb]), for tests.
  @visibleForTesting
  static set debugEnabled(bool? value) => _override = value;

  /// What Settings says about the demo in place of the sync and AI sections.
  static const settingsNote =
      'This is the web demo. It has no account and no server: lessons and '
      'study progress are kept in this browser only. AI features and sync '
      'are in the desktop and mobile apps. Back up keeps a copy, which '
      'Restore can open in the app.';

  /// The lessons a first visit starts with, and the folder each goes in.
  static const sampleLessons = [
    (asset: 'assets/demo/korean-greetings.md', folder: 'Korean basics'),
    (asset: 'assets/demo/korean-cafe.md', folder: 'Korean basics'),
    (asset: 'assets/demo/spanish-greetings.md', folder: 'Spanish basics'),
  ];

  /// Set once the sample lessons were added, so a learner who deletes them
  /// does not get them back. It does not start with `lingua_srs_`, so a
  /// backup leaves it out and a restore keeps it.
  static const _seededKey = 'web_demo_seeded';

  /// Whether the sample lessons should be added now: in the demo, on a first
  /// visit, with no lessons yet.
  static Future<bool> shouldAddSamples({required bool hasLessons}) async {
    if (!enabled || hasLessons) return false;
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_seededKey) != true;
  }

  /// Remembers that the sample lessons were added.
  static Future<void> markSamplesAdded() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_seededKey, true);
  }

  /// Reads [sampleLessons] from [bundle] (the app's assets by default).
  static Future<List<YamlParseResult>> loadSamples([
    AssetBundle? bundle,
  ]) async {
    final assets = bundle ?? rootBundle;
    return [
      for (final sample in sampleLessons)
        YamlParserService.parseLessonYaml(
          await assets.loadString(sample.asset),
          defaultUnitTitle: sample.folder,
        ),
    ];
  }
}
