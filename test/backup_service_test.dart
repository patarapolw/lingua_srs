import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/lesson.dart';
import 'package:lingua_srs/models/typed_question.dart';
import 'package:lingua_srs/services/backup_service.dart';
import 'package:lingua_srs/services/storage_service.dart';
import 'package:lingua_srs/services/sync_pairing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _syncPassword = 'correct horse battery staple';
final _syncLink = SyncPairing(
  endpoint: Uri.parse('https://sync.example.com'),
  email: 'reader@example.com',
  password: _syncPassword,
).link;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory storageDirectory;

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'lingua_srs_deepseek_api_key': 'device-only-key',
      'lingua_srs_sync_pairing': _syncLink,
      'lingua_srs_lessons': jsonEncode([
        Lesson(id: 'lesson-id', title: 'Saved').toJson(),
      ]),
      'lingua_srs_sentences': '[]',
      'lingua_srs_lesson_markdown_ids': <dynamic>['lesson-id'],
      'lingua_srs_max_reviews_24h': 50,
    });
    storageDirectory = Directory.systemTemp.createTempSync(
      'lingua_srs_backup_test_',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (call) async {
          if (call.method == 'getApplicationSupportDirectory') {
            return storageDirectory.path;
          }
          throw MissingPluginException('Unexpected method: ${call.method}');
        });
    final markdown =
        File('${storageDirectory.path}/lesson_markdown/bGVzc29uLWlk.md')
          ..createSync(recursive: true)
          ..writeAsStringSync('# Saved lesson');
    expect(markdown.existsSync(), isTrue);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    await storageDirectory.delete(recursive: true);
  });

  test('backup includes app data and Markdown but omits the API key', () async {
    final backup = jsonDecode(await BackupService.createBackup()) as Map;

    expect(backup['format'], 'lingua_srs_backup');
    expect(backup['version'], 1);
    expect(
      backup['preferences'],
      containsPair('lingua_srs_max_reviews_24h', 50),
    );
    expect(
      (backup['preferences'] as Map).containsKey('lingua_srs_deepseek_api_key'),
      isFalse,
    );
    expect(backup['lessonMarkdown'], {'lesson-id': '# Saved lesson'});
  });

  test('backup omits the sync pairing and restore keeps it', () async {
    final backup = await BackupService.createBackup();
    expect(
      (jsonDecode(backup) as Map)['preferences'] as Map,
      isNot(contains('lingua_srs_sync_pairing')),
    );
    expect(backup, isNot(contains(_syncPassword)));
    expect(backup, isNot(contains('reader@example.com')));

    final prefs = await SharedPreferences.getInstance();
    await BackupService.restoreBackup(backup);

    expect(prefs.getString('lingua_srs_sync_pairing'), _syncLink);
  });

  test('restore rejects a backup that carries a sync pairing', () async {
    final backup = jsonEncode({
      'format': 'lingua_srs_backup',
      'version': 1,
      'preferences': {
        'lingua_srs_sync_pairing': 'linguasrs://sync?email=other%40example.com',
        'lingua_srs_sentences': '[]',
      },
      'lessonMarkdown': {},
    });

    await expectLater(
      BackupService.restoreBackup(backup),
      throwsFormatException,
    );

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('lingua_srs_sync_pairing'), _syncLink);
  });

  test(
    'restore replaces app data and Markdown, preserving the local API key',
    () async {
      final backup = await BackupService.createBackup();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('lingua_srs_lessons', '[]');
      await prefs.setString('lingua_srs_unrelated_old_value', 'remove me');
      await prefs.setString('other_plugin_preference', 'keep me');
      await File('${storageDirectory.path}/lesson_markdown/bGVzc29uLWlk.md')
          .writeAsString('old content');

      await BackupService.restoreBackup(backup);

      expect(prefs.getString('lingua_srs_deepseek_api_key'), 'device-only-key');
      expect(prefs.getInt('lingua_srs_max_reviews_24h'), 50);
      expect(prefs.getString('lingua_srs_unrelated_old_value'), isNull);
      expect(prefs.getString('other_plugin_preference'), 'keep me');
      expect(
        await File('${storageDirectory.path}/lesson_markdown/bGVzc29uLWlk.md')
            .readAsString(),
        '# Saved lesson',
      );
      final lessons = await StorageService.loadLessons();
      expect(lessons.single.title, 'Saved');
      expect(lessons.single.markdownContent, '# Saved lesson');
    },
  );

  test('backup keeps typed AI questions and restore returns them', () async {
    final question = TypedQuestion(
      language: 'ko',
      scope: TypedQuestionScope.word,
      template: 'Is {word} formal?',
      uses: 2,
      lastUsed: DateTime.utc(2026, 11, 1),
    );
    await StorageService.saveTypedQuestions({'ko:word:is{}formal': question});
    final backup = await BackupService.createBackup();
    await StorageService.saveTypedQuestions({});

    await BackupService.restoreBackup(backup);

    final restored = await StorageService.loadTypedQuestions();
    expect(restored.keys, ['ko:word:is{}formal']);
    expect(restored.values.single.toJson(), question.toJson());
  });

  test('restore rejects typed AI questions it cannot read', () async {
    final backup = jsonEncode({
      'format': 'lingua_srs_backup',
      'version': 1,
      'preferences': {
        'lingua_srs_typed_questions': jsonEncode({
          'ko:word:x': {'template': 'x'},
        }),
        'lingua_srs_sentences': '[]',
      },
      'lessonMarkdown': {},
    });

    await expectLater(
      BackupService.restoreBackup(backup),
      throwsFormatException,
    );
  });

  test(
    'invalid lesson data is rejected before changing saved preferences',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final backup = jsonEncode({
        'format': 'lingua_srs_backup',
        'version': 1,
        'preferences': {
          'lingua_srs_lessons': 'invalid',
          'lingua_srs_sentences': '[]',
        },
        'lessonMarkdown': {},
      });

      await expectLater(
        BackupService.restoreBackup(backup),
        throwsFormatException,
      );

      expect(prefs.getString('lingua_srs_lessons'), isNot('invalid'));
      expect(prefs.getString('lingua_srs_deepseek_api_key'), 'device-only-key');
    },
  );
}
