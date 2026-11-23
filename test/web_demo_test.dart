import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/providers/app_provider.dart';
import 'package:lingua_srs/services/lesson_markdown_store.dart';
import 'package:lingua_srs/services/storage_service.dart';
import 'package:lingua_srs/services/sync_pairing.dart';
import 'package:lingua_srs/services/web_demo.dart';
import 'package:lingua_srs/views/settings_dialog.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'secret_storage_mock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(setUpSecretStorage);
  tearDown(() => WebDemo.debugEnabled = null);

  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory storageDirectory;

  setUp(() {
    storageDirectory = Directory.systemTemp.createTempSync(
      'lingua_srs_web_demo_test_',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (call) async {
          if (call.method == 'getApplicationSupportDirectory') {
            return storageDirectory.path;
          }
          throw MissingPluginException('Unexpected method: ${call.method}');
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    if (storageDirectory.existsSync()) {
      await storageDirectory.delete(recursive: true);
    }
  });

  Future<AppProvider> loadedProvider(
    WidgetTester tester, [
    Map<String, Object> prefs = const {},
  ]) async {
    SharedPreferences.setMockInitialValues({
      'lingua_srs_windows_legacy_migration_complete': true,
      ...prefs,
    });
    final provider = AppProvider();
    addTearDown(provider.dispose);
    for (var i = 0; i < 200 && provider.isLoading; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(provider.isLoading, isFalse, reason: 'provider never loaded');
    return provider;
  }

  test('the demo is the web build', () {
    // Tests do not run on the web.
    expect(WebDemo.enabled, isFalse);
    WebDemo.debugEnabled = true;
    expect(WebDemo.enabled, isTrue);
  });

  test('every sample lesson reads, with words and examples', () async {
    final samples = await WebDemo.loadSamples();
    expect(samples, hasLength(WebDemo.sampleLessons.length));
    for (final sample in samples) {
      expect(sample.lesson.vocabularies, isNotEmpty);
      expect(sample.lesson.markdownContent, isNotEmpty);
      for (final vocab in sample.lesson.vocabularies) {
        expect(
          vocab.sentenceIds,
          isNotEmpty,
          reason: '${vocab.targetWord} has no example',
        );
      }
    }
    expect(
      [for (final sample in samples) sample.lesson.folderPath],
      [
        ['Korean basics'],
        ['Korean basics'],
        ['Spanish basics'],
      ],
    );
  });

  testWidgets('a first visit to the demo starts with the sample lessons', (
    tester,
  ) async {
    WebDemo.debugEnabled = true;
    final provider = await loadedProvider(tester);

    expect(
      [for (final lesson in provider.lessons) lesson.displayTitle],
      ['Greetings', 'At the café', 'Saludos'],
    );
    // It opens on the first sample's language, not the last one imported.
    expect(provider.activeLanguage, 'ko');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('web_demo_seeded'), isTrue);
  });

  testWidgets('deleted sample lessons do not come back', (tester) async {
    WebDemo.debugEnabled = true;
    final provider = await loadedProvider(tester, {'web_demo_seeded': true});
    expect(provider.lessons, isEmpty);
  });

  testWidgets('the apps do not get the sample lessons', (tester) async {
    final provider = await loadedProvider(tester);
    expect(provider.lessons, isEmpty);
  });

  testWidgets('the demo has no AI features, even when turned on', (
    tester,
  ) async {
    WebDemo.debugEnabled = true;
    final provider = await loadedProvider(tester, {
      'web_demo_seeded': true,
      'lingua_srs_show_ai': true,
    });
    await tester.runAsync(() => provider.setDeepSeekApiKey('sk-test'));
    expect(provider.showAi, isFalse);
    expect(provider.canUseAi, isFalse);

    WebDemo.debugEnabled = false;
    expect(provider.showAi, isTrue);
  });

  test('the demo reads no AI key or sync sign-in', () async {
    SharedPreferences.setMockInitialValues({});
    final pairing = SyncPairing(
      endpoint: Uri.parse('https://sync.example.com'),
      email: 'reader@example.com',
      password: 'TEST-ONLY-SYNC-PASSWORD',
    );
    await StorageService.saveDeepSeekApiKey('sk-test');
    await StorageService.saveSyncPairing(pairing);

    WebDemo.debugEnabled = true;
    expect(await StorageService.loadDeepSeekApiKey(), isEmpty);
    expect(await StorageService.loadSyncPairing(), isNull);

    WebDemo.debugEnabled = false;
    expect(await StorageService.loadDeepSeekApiKey(), 'sk-test');
    expect(await StorageService.loadSyncPairing(), isNotNull);
  });

  testWidgets('Settings in the demo has no sync or AI sections', (
    tester,
  ) async {
    WebDemo.debugEnabled = true;
    final provider = await loadedProvider(tester, {'web_demo_seeded': true});
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppProvider>.value(
        value: provider,
        child: const MaterialApp(home: Scaffold(body: SettingsDialog())),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Web demo'), findsOneWidget);
    expect(find.text(WebDemo.settingsNote), findsOneWidget);
    expect(find.text('Sync'), findsNothing);
    expect(find.text('AI features'), findsNothing);
    expect(find.textContaining('DeepSeek'), findsNothing);
    expect(find.text('Back up'), findsOneWidget);
  });

  test('on the web, lessons\' Markdown is kept in preferences', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = LessonMarkdownStore.inPreferences(prefs);

    expect(await store.read('lesson-1'), isNull);
    await store.write('lesson-1', '# Greetings');
    expect(await store.read('lesson-1'), '# Greetings');
    // Not a `lingua_srs_` setting, which a backup would copy as one.
    expect(
      prefs.getKeys().where((key) => key.startsWith('lingua_srs_')),
      isEmpty,
    );

    await store.delete('lesson-1');
    expect(await store.read('lesson-1'), isNull);
    expect(prefs.getKeys(), isEmpty);
  });
}
