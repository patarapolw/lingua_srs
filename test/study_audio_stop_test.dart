import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/lesson.dart';
import 'package:lingua_srs/providers/app_provider.dart';
import 'package:lingua_srs/services/audio_service.dart';
import 'package:lingua_srs/views/study_view.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Records what the review asks of the audio service, and touches no plugin.
class _RecordingAudioService extends ChangeNotifier implements AudioService {
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

  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory storageDirectory;

  setUp(() {
    storageDirectory = Directory.systemTemp.createTempSync(
      'lingua_srs_study_audio_stop_test_',
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

  testWidgets('revealing the answer autoplays it', (tester) async {
    final provider = await loadedProvider(tester);
    final lesson = await seedTwoNewCards(tester, provider);
    final audio = _RecordingAudioService();
    await openReview(tester, provider, audio, lesson);

    await reveal(tester);

    expect(audio.answerSequences, 1);
  });

  testWidgets('changing into a new card stops the autoplay audio', (
    tester,
  ) async {
    final provider = await loadedProvider(tester);
    final lesson = await seedTwoNewCards(tester, provider);
    final audio = _RecordingAudioService();
    await openReview(tester, provider, audio, lesson);
    await reveal(tester);
    final stopsBefore = audio.stopCalls;

    await tester.tap(find.textContaining('Good'));
    await tester.pumpAndSettle();

    expect(audio.stopCalls, greaterThan(stopsBefore));
    // Now on the next card, front side up.
    expect(find.textContaining('Show Answer'), findsOneWidget);
  });

  testWidgets('leaving the review stops the audio as soon as it is popped', (
    tester,
  ) async {
    final provider = await loadedProvider(tester);
    final lesson = await seedTwoNewCards(tester, provider);
    final audio = _RecordingAudioService();
    await openReview(tester, provider, audio, lesson);
    await reveal(tester);
    final stopsBefore = audio.stopCalls;

    Navigator.of(tester.element(find.byType(StudyView))).pop();
    await tester.pump(); // the exit animation has only just started

    expect(find.byType(StudyView), findsOneWidget);
    expect(audio.stopCalls, greaterThan(stopsBefore));

    await tester.pumpAndSettle();
    expect(find.byType(StudyView), findsNothing);
  });

  testWidgets('removing the review without a pop still stops the audio', (
    tester,
  ) async {
    final provider = await loadedProvider(tester);
    final lesson = await seedTwoNewCards(tester, provider);
    final audio = _RecordingAudioService();
    await openReview(tester, provider, audio, lesson);
    await reveal(tester);
    final stopsBefore = audio.stopCalls;

    await tester.pumpWidget(const SizedBox());
    await tester.pump();

    expect(audio.stopCalls, greaterThan(stopsBefore));
  });

  testWidgets('rotating the device does not stop the audio', (tester) async {
    final provider = await loadedProvider(tester);
    final lesson = await seedTwoNewCards(tester, provider);
    final audio = _RecordingAudioService();
    await openReview(tester, provider, audio, lesson); // portrait
    await reveal(tester);
    final stopsBefore = audio.stopCalls;

    tester.view.physicalSize = const Size(1280, 800); // landscape
    await tester.pumpAndSettle();

    expect(audio.stopCalls, stopsBefore);
    // Same review, same card, still showing its answer, not replayed.
    expect(find.byType(StudyView), findsOneWidget);
    expect(find.textContaining('Good'), findsOneWidget);
    expect(audio.answerSequences, 1);

    tester.view.physicalSize = const Size(800, 1280); // and back
    await tester.pumpAndSettle();

    expect(audio.stopCalls, stopsBefore);
    expect(audio.answerSequences, 1);
  });
}
