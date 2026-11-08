import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/srs_card.dart';
import 'package:lingua_srs/providers/app_provider.dart';
import 'package:lingua_srs/services/audio_service.dart';
import 'package:lingua_srs/services/tts_voice.dart';
import 'package:lingua_srs/views/lesson_detail_view.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'secret_storage_mock.dart';

/// The review screen must not touch real audio plugins.
class _FakeAudioService extends ChangeNotifier implements AudioService {
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
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory storageDirectory;

  setUp(() {
    storageDirectory = Directory.systemTemp.createTempSync(
      'lingua_srs_card_preview_test_',
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
    expect(provider.isLoading, isFalse);
    return provider;
  }

  testWidgets('previews one part of speech without starting cards', (
    tester,
  ) async {
    final provider = await loadedProvider(tester);
    const yaml =
        '---\n'
        'vocabulary:\n'
        '  nouns:\n'
        '    - ko: 집\n'
        '      en: house\n'
        '    - ko: 책\n'
        '      en: book\n'
        '  verbs:\n'
        '    - ko: 가다\n'
        '      en: go\n'
        '---\n'
        '# Preview\n';
    final lesson = (await tester.runAsync(() => provider.importYaml(yaml)))!;
    final newBefore = lesson.newCardsCount;
    final remainingBefore = provider.remainingNewCards24h;

    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppProvider>.value(value: provider),
          ChangeNotifierProvider<AudioService>(
            create: (_) => _FakeAudioService(),
          ),
        ],
        child: MaterialApp(home: LessonDetailView(lessonId: lesson.id)),
      ),
    );
    await tester.pump();

    await tester.tap(find.widgetWithText(FilterChip, 'NOUNS'));
    await tester.pumpAndSettle();
    // Wide window: a labelled button counting the nouns' new cards.
    expect(find.text('Preview (2)'), findsOneWidget);
    await tester.tap(find.text('Preview (2)'));
    await tester.pumpAndSettle();

    // The review screen, with every card marked as a preview.
    expect(find.text('PREVIEW'), findsOneWidget);
    expect(find.text('Preview · NOUNS: not added to reviews'), findsOneWidget);
    expect(find.text('집'), findsWidgets);

    // Again brings the card back and shows it in Recent Mistakes, still new.
    await tester.tap(find.textContaining('Show Answer'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Again'));
    await tester.pumpAndSettle();
    final missed = lesson.vocabularies
        .firstWhere((vocab) => vocab.targetWord == '집')
        .cardTargetToNative;
    expect(missed.hasRecentMistake, isTrue);
    expect(provider.getRecentMistakesCount(lessonId: lesson.id), 1);
    for (var i = 0; i < 2; i++) {
      expect(find.text('가다'), findsNothing);
      await tester.tap(find.textContaining('Show Answer'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Good'));
      await tester.pumpAndSettle();
    }
    expect(find.text('Preview Complete'), findsOneWidget);
    expect(find.text('Preview Again'), findsOneWidget);
    expect(find.text('Cram (Practice Only)'), findsNothing);

    await tester.pageBack();
    await tester.pumpAndSettle();

    for (final vocab in lesson.vocabularies) {
      expect(vocab.cardTargetToNative.status, SrsStatus.isNew);
      expect(vocab.cardNativeToTarget.status, SrsStatus.isNew);
    }
    expect(provider.reviewsInLast24Hours, 0);
    expect(provider.getRecentMistakesCount(lessonId: lesson.id), 1);
    expect(lesson.newCardsCount, newBefore);
    expect(provider.remainingNewCards24h, remainingBefore);
  });
}
