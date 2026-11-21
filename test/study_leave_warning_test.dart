import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/lesson.dart';
import 'package:lingua_srs/providers/app_provider.dart';
import 'package:lingua_srs/services/audio_service.dart';
import 'package:lingua_srs/services/tts_voice.dart';
import 'package:lingua_srs/views/study_view.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'secret_storage_mock.dart';

/// Touches no plugin.
class _RecordingAudioService extends ChangeNotifier implements AudioService {
  @override
  TtsVoiceUsed? get lastVoice => null;
  int stopCalls = 0;
  int answerSequences = 0;

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
  Future<void> stop() async {
    stopCalls++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #playAnswerSequence) answerSequences++;
    return Future<void>.value();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(setUpSecretStorage);

  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory storageDirectory;

  setUp(() {
    storageDirectory = Directory.systemTemp.createTempSync(
      'lingua_srs_study_leave_warning_test_',
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

  Future<AppProvider> loadedProvider(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({
      'lingua_srs_windows_legacy_migration_complete': true,
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

  /// A lesson with two new words, studied KO ➔ EN only, so that rating one
  /// card moves the review on to a different card.
  Future<Lesson> seedTwoNewCards(
    WidgetTester tester,
    AppProvider provider,
  ) async {
    const yaml =
        '---\nvocabulary:\n  nouns:\n    - ko: 단어\n      en: word\n'
        '    - ko: 문장\n      en: sentence\n---\n# Lesson\n';
    final lesson = (await tester.runAsync(() => provider.importYaml(yaml)))!;
    for (final vocab in lesson.vocabularies) {
      vocab.cardNativeToTarget.isEnabled = false;
    }
    return lesson;
  }

  /// Opens the review as its own route above a home page, like the app does.
  Future<void> openReview(
    WidgetTester tester,
    AppProvider provider,
    _RecordingAudioService audio,
    Lesson lesson,
  ) async {
    tester.view.physicalSize = const Size(800, 1280);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppProvider>.value(value: provider),
          ChangeNotifierProvider<AudioService>(create: (_) => audio),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => StudyView(lessonId: lesson.id),
                    ),
                  ),
                  child: const Text('Open review'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open review'));
    await tester.pumpAndSettle();
  }

  Future<void> reveal(WidgetTester tester) async {
    await tester.tap(find.textContaining('Show Answer'));
    await tester.pumpAndSettle();
  }

  Future<void> rateGood(WidgetTester tester) async {
    await reveal(tester);
    await tester.tap(find.textContaining('Good'));
    await tester.pumpAndSettle();
  }

  /// Presses the system back button (Android back, or the browser's).
  Future<void> pressBack(WidgetTester tester) async {
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
  }

  Future<void> openStartedReview(WidgetTester tester) async {
    final provider = await loadedProvider(tester);
    final lesson = await seedTwoNewCards(tester, provider);
    await openReview(tester, provider, _RecordingAudioService(), lesson);
    await rateGood(tester);
  }

  testWidgets('back before any answer is shown leaves without asking', (
    tester,
  ) async {
    final provider = await loadedProvider(tester);
    final lesson = await seedTwoNewCards(tester, provider);
    await openReview(tester, provider, _RecordingAudioService(), lesson);

    await pressBack(tester);

    expect(find.text('Leave this review?'), findsNothing);
    expect(find.byType(StudyView), findsNothing);
  });

  testWidgets('back with the first answer shown asks', (tester) async {
    final provider = await loadedProvider(tester);
    final lesson = await seedTwoNewCards(tester, provider);
    await openReview(tester, provider, _RecordingAudioService(), lesson);
    await reveal(tester);

    await pressBack(tester);

    expect(find.text('Leave this review?'), findsOneWidget);
    expect(find.textContaining('2 cards are left'), findsOneWidget);

    await tester.tap(find.text('Stay'));
    await tester.pumpAndSettle();

    expect(find.byType(StudyView), findsOneWidget);
    expect(find.textContaining('Good'), findsOneWidget);
  });

  testWidgets('back in a started review asks, and Stay keeps the review', (
    tester,
  ) async {
    await openStartedReview(tester);

    await pressBack(tester);

    expect(find.text('Leave this review?'), findsOneWidget);
    expect(find.textContaining('1 card is left'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Wrap up'), findsOneWidget);

    await tester.tap(find.text('Stay'));
    await tester.pumpAndSettle();

    expect(find.text('Leave this review?'), findsNothing);
    expect(find.byType(StudyView), findsOneWidget);
    expect(find.textContaining('Show Answer'), findsOneWidget);
  });

  testWidgets('the AppBar back button asks too, and Leave leaves', (
    tester,
  ) async {
    await openStartedReview(tester);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('Leave this review?'), findsOneWidget);

    await tester.tap(find.text('Leave'));
    await tester.pumpAndSettle();

    expect(find.byType(StudyView), findsNothing);
    expect(find.text('Open review'), findsOneWidget);
  });

  testWidgets('Wrap up from the question wraps the session up', (tester) async {
    await openStartedReview(tester);

    await pressBack(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Wrap up'));
    await tester.pumpAndSettle();

    // The only card left is new, so wrapping up drops it and ends the
    // session, still on the review's own finish screen.
    expect(find.byType(StudyView), findsOneWidget);
    expect(find.text('Session Complete!'), findsOneWidget);
  });

  testWidgets('back from a finished review leaves without asking', (
    tester,
  ) async {
    await openStartedReview(tester);
    await rateGood(tester);
    expect(find.text('Session Complete!'), findsOneWidget);

    await pressBack(tester);

    expect(find.text('Leave this review?'), findsNothing);
    expect(find.byType(StudyView), findsNothing);
  });
}
