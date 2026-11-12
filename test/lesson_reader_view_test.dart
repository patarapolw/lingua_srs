import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/lesson.dart';
import 'package:lingua_srs/providers/app_provider.dart';
import 'package:lingua_srs/services/audio_service.dart';
import 'package:lingua_srs/services/lesson_links.dart';
import 'package:lingua_srs/services/tts_voice.dart';
import 'package:lingua_srs/views/lesson_detail_view.dart';
import 'package:lingua_srs/views/lesson_reader_view.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_platform_interface/webview_platform_interface.dart';

import 'fake_webview_platform.dart';
import 'secret_storage_mock.dart';

/// Touches no audio plugin.
class _SilentAudioService extends ChangeNotifier implements AudioService {
  @override
  TtsVoiceUsed? get lastVoice => null;
  @override
  bool get isPlaying => false;
  @override
  String? get currentlyPlayingKey => null;
  @override
  bool get usesOfflineTts => true;
  @override
  void prefetchAudios(List<String?> urls) {}
  @override
  String getTtsUrl(String text, {String? language}) => '';
  @override
  Future<void> stop() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(setUpSecretStorage);

  late FakeWebViewPlatform webview;
  setUp(() {
    webview = FakeWebViewPlatform();
    WebViewPlatform.instance = webview;
  });

  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory storageDirectory;

  setUp(() {
    storageDirectory = Directory.systemTemp.createTempSync(
      'lingua_srs_lesson_reader_view_test_',
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
    WidgetTester tester, {
    bool showAi = true,
  }) async {
    SharedPreferences.setMockInitialValues({
      'lingua_srs_windows_legacy_migration_complete': true,
      'lingua_srs_show_ai': showAi,
    });
    final provider = AppProvider();
    addTearDown(provider.dispose);
    for (var i = 0; i < 100 && provider.isLoading; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(provider.isLoading, isFalse, reason: 'provider never loaded');
    return provider;
  }

  /// Opens a lesson with headings, so every app bar action is shown.
  Future<Lesson> openReader(
    WidgetTester tester,
    Size size, {
    bool showAi = true,
  }) async {
    final provider = await loadedProvider(tester, showAi: showAi);
    const markdown =
        '---\nvocabulary:\n  nouns:\n    - ko: 단어\n      en: word\n---\n'
        '# Greetings\n\n## First part\n\nSome text.\n';
    final lesson = (await tester.runAsync(
      () => provider.importYaml(markdown),
    ))!;

    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppProvider>.value(value: provider),
          ChangeNotifierProvider<AudioService>(
            create: (_) => _SilentAudioService(),
          ),
        ],
        child: MaterialApp(home: LessonReaderView(lessonId: lesson.id)),
      ),
    );
    await tester.pumpAndSettle();
    return lesson;
  }

  Finder appBarTitle(Lesson lesson) => find.descendant(
    of: find.byType(AppBar),
    matching: find.text(lesson.displayTitle),
  );

  testWidgets('keeps room for the title on a phone', (tester) async {
    final lesson = await openReader(tester, const Size(360, 800));

    expect(find.byTooltip('Table of contents'), findsOneWidget);
    expect(find.byTooltip('View Vocabulary'), findsOneWidget);
    expect(find.text('View Vocabulary'), findsNothing);
    // Before, the labelled button left the title about 20 px.
    expect(tester.getSize(appBarTitle(lesson)).width, greaterThan(100));
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('View Vocabulary'));
    await tester.pumpAndSettle();
    expect(find.byType(LessonDetailView), findsOneWidget);
  });

  testWidgets('labels View Vocabulary on a wide screen', (tester) async {
    final lesson = await openReader(tester, const Size(1200, 800));

    expect(find.text('View Vocabulary'), findsOneWidget);
    expect(appBarTitle(lesson), findsOneWidget);
  });

  testWidgets('offers Ask AI about lesson while AI is on', (tester) async {
    await openReader(tester, const Size(1200, 800));
    expect(find.byTooltip('Ask AI about lesson'), findsOneWidget);
  });

  testWidgets('hides Ask AI about lesson when AI is off', (tester) async {
    await openReader(tester, const Size(1200, 800), showAi: false);
    expect(find.byTooltip('Ask AI about lesson'), findsNothing);
    expect(find.byTooltip('Edit Markdown'), findsOneWidget);
  });

  testWidgets('shows the virtual path while editing Markdown', (tester) async {
    await openReader(tester, const Size(1200, 800));

    await tester.tap(find.byTooltip('Edit Markdown'));
    await tester.pumpAndSettle();

    expect(find.text('/Greetings.md'), findsOneWidget);
    expect(find.byTooltip('Copy link to this lesson'), findsOneWidget);
  });

  group('lesson links', () {
    Future<(Lesson, Lesson)> openLinked(WidgetTester tester) async {
      final provider = await loadedProvider(tester);
      const vocab = '---\nvocabulary:\n---\n';
      final target = (await tester.runAsync(
        () => provider.importYaml(
          '$vocab# Lesson 26\n\n## Past tense\n\nPast text.\n',
          defaultTitle: 'Lesson 26',
          defaultUnitTitle: 'Unit 2',
        ),
      ))!;
      final source = (await tester.runAsync(
        () => provider.importYaml(
          '$vocab# Start\n\n[[Unit 2::Lesson 26#Past tense]]\n\n'
          '[[Missing lesson]]\n\n'
          '[as a file](unit-2/lesson-26.md#past-tense)\n',
          defaultTitle: 'Start',
        ),
      ))!;
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AppProvider>.value(value: provider),
            ChangeNotifierProvider<AudioService>(
              create: (_) => _SilentAudioService(),
            ),
          ],
          child: MaterialApp(home: LessonReaderView(lessonId: source.id)),
        ),
      );
      await tester.pumpAndSettle();
      return (source, target);
    }

    testWidgets('opens the linked lesson at its heading', (tester) async {
      final (_, target) = await openLinked(tester);

      webview.controller.send({
        'type': 'link',
        'href': const LessonLink(
          lesson: 'Unit 2::Lesson 26',
          heading: 'Past tense',
        ).href,
      });
      await tester.pumpAndSettle();

      final reader = tester.widget<LessonReaderView>(
        find.byType(LessonReaderView).last,
      );
      expect(reader.lessonId, target.id);
      expect(reader.initialHeading, 'Past tense');
      expect(webview.controller.html, contains('Past text.'));
    });

    testWidgets('opens the lesson a .md link points to', (tester) async {
      final (_, target) = await openLinked(tester);

      webview.controller.send({
        'type': 'link',
        'href': 'unit-2/lesson-26.md#past-tense',
      });
      await tester.pumpAndSettle();

      final reader = tester.widget<LessonReaderView>(
        find.byType(LessonReaderView).last,
      );
      expect(reader.lessonId, target.id);
      expect(reader.initialHeading, 'past-tense');
    });

    testWidgets('says when the linked lesson does not exist', (tester) async {
      await openLinked(tester);

      webview.controller.send({
        'type': 'link',
        'href': const LessonLink(lesson: 'Missing lesson').href,
      });
      await tester.pump();

      expect(find.text('No lesson named “Missing lesson”.'), findsOneWidget);
    });
  });
}
