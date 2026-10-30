import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/sentence.dart';
import 'package:lingua_srs/providers/app_provider.dart';
import 'package:lingua_srs/services/audio_service.dart';
import 'package:lingua_srs/views/sentence_pool_view.dart';
import 'package:lingua_srs/widgets/audio_button.dart';
import 'package:lingua_srs/widgets/audio_edit_fields.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Records what the buttons ask to play, without touching audio plugins.
class _RecordingAudio extends ChangeNotifier implements AudioService {
  final spoken = <String>[];
  final played = <String>[];

  @override
  bool get isPlaying => false;
  @override
  String? get currentlyPlayingKey => null;
  @override
  bool get usesOfflineTts => true;
  @override
  Future<void> speak(String text, {String? language}) async => spoken.add(text);
  @override
  Future<void> playAudio(String? urlOrPath, {String? playingKey}) async {
    if (urlOrPath != null) played.add(urlOrPath);
  }

  @override
  Future<void> stop() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

const _ttsLabel = 'Korean TTS text (optional)';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget harness(_RecordingAudio audio, Widget child) =>
      ChangeNotifierProvider<AudioService>.value(
        value: audio,
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Padding(padding: const EdgeInsets.all(16), child: child),
            ),
          ),
        ),
      );

  group('TtsTextField', () {
    late TextEditingController tts;
    late TextEditingController word;

    setUp(() {
      tts = TextEditingController();
      word = TextEditingController(text: '배');
    });
    tearDown(() {
      tts.dispose();
      word.dispose();
    });

    Future<void> pump(WidgetTester tester, _RecordingAudio audio) =>
        tester.pumpWidget(
          harness(audio, TtsTextField(controller: tts, spokenFallback: word)),
        );

    testWidgets('is collapsed while blank and opens on tap', (tester) async {
      await pump(tester, _RecordingAudio());

      expect(find.text('Text-to-speech'), findsOneWidget);
      expect(find.text('Speaks the text as written.'), findsOneWidget);
      expect(find.widgetWithText(TextField, _ttsLabel), findsNothing);

      await tester.tap(find.text('Text-to-speech'));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(TextField, _ttsLabel), findsOneWidget);
    });

    testWidgets('starts open, and says what it speaks, once it has text', (
      tester,
    ) async {
      tts.text = '세 개';
      await pump(tester, _RecordingAudio());

      expect(find.widgetWithText(TextField, _ttsLabel), findsOneWidget);
      expect(find.text('Speaks: 세 개'), findsOneWidget);
    });

    testWidgets('previews from the collapsed header, without opening it', (
      tester,
    ) async {
      final audio = _RecordingAudio();
      await pump(tester, audio);

      await tester.tap(find.byTooltip('Play Text-to-Speech'));
      await tester.pump();

      expect(audio.spoken, ['배']);
      expect(find.widgetWithText(TextField, _ttsLabel), findsNothing);
    });

    testWidgets('previews the override, or the word while it is blank', (
      tester,
    ) async {
      final audio = _RecordingAudio();
      await pump(tester, audio);
      await tester.tap(find.text('Text-to-speech'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Play Text-to-Speech'));
      await tester.pump();
      expect(audio.spoken, ['배']);

      await tester.enterText(find.widgetWithText(TextField, _ttsLabel), '세 개');
      await tester.pump();
      await tester.tap(find.byTooltip('Play Text-to-Speech'));
      await tester.pump();
      expect(audio.spoken, ['배', '세 개']);

      // The word being typed elsewhere in the dialog is followed too.
      await tester.enterText(find.widgetWithText(TextField, _ttsLabel), '');
      word.text = '사과';
      await tester.pump();
      await tester.tap(find.byTooltip('Play Text-to-Speech'));
      await tester.pump();
      expect(audio.spoken, ['배', '세 개', '사과']);
    });
  });

  group('SentenceAudioChoice', () {
    Future<List<bool>> pump(
      WidgetTester tester, {
      required bool hasRecording,
      bool useAudio = true,
    }) async {
      final choices = <bool>[];
      var current = useAudio;
      await tester.pumpWidget(
        harness(
          _RecordingAudio(),
          StatefulBuilder(
            builder: (context, setState) => SentenceAudioChoice(
              hasRecording: hasRecording,
              useAudio: current,
              onChanged: (value) {
                choices.add(value);
                setState(() => current = value);
              },
            ),
          ),
        ),
      );
      return choices;
    }

    FilterChip chip(WidgetTester tester) =>
        tester.widget<FilterChip>(find.byType(FilterChip));

    testWidgets('has nothing to choose without a recording', (tester) async {
      await pump(tester, hasRecording: false);

      expect(find.byType(FilterChip), findsNothing);
    });

    testWidgets('is ticked while the recording is used, and toggles', (
      tester,
    ) async {
      final choices = await pump(tester, hasRecording: true);
      expect(find.text('Use recording'), findsOneWidget);
      expect(chip(tester).selected, isTrue);

      await tester.tap(find.byType(FilterChip));
      await tester.pump();
      expect(chip(tester).selected, isFalse);

      await tester.tap(find.byType(FilterChip));
      await tester.pump();
      expect(chip(tester).selected, isTrue);
      expect(choices, [false, true]);
    });

    testWidgets('starts unticked when the recording is off', (tester) async {
      await pump(tester, hasRecording: true, useAudio: false);

      expect(chip(tester).selected, isFalse);
    });
  });

  group('AudioUrlField', () {
    late TextEditingController url;

    setUp(() => url = TextEditingController());
    tearDown(() => url.dispose());

    Future<List<bool>> pump(WidgetTester tester, _RecordingAudio audio) async {
      final choices = <bool>[];
      var useAudio = true;
      await tester.pumpWidget(
        harness(
          audio,
          StatefulBuilder(
            builder: (context, setState) => AudioUrlField(
              controller: url,
              useAudio: useAudio,
              onUseAudioChanged: (value) {
                choices.add(value);
                setState(() => useAudio = value);
              },
            ),
          ),
        ),
      );
      return choices;
    }

    testWidgets('offers neither preview nor checkbox without a URL', (
      tester,
    ) async {
      await pump(tester, _RecordingAudio());

      expect(find.byType(AudioButton), findsOneWidget);
      expect(find.byTooltip('Play Audio'), findsNothing);
      expect(find.text('Use this recording'), findsNothing);
    });

    testWidgets('previews the URL as typed, and can switch it off', (
      tester,
    ) async {
      final audio = _RecordingAudio();
      final choices = await pump(tester, audio);

      await tester.enterText(
        find.widgetWithText(TextField, 'Audio URL'),
        ' https://example.com/a.mp3 ',
      );
      await tester.pump();
      expect(find.text('Use this recording'), findsOneWidget);

      await tester.tap(find.byTooltip('Play Audio'));
      await tester.pump();
      expect(audio.played, ['https://example.com/a.mp3']);

      await tester.tap(find.byType(CheckboxListTile));
      await tester.pump();
      expect(choices, [false]);
      expect(
        tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
        isFalse,
      );

      // Switched off, the recording can still be previewed, to judge it.
      await tester.tap(find.byTooltip('Play Audio'));
      await tester.pump();
      expect(audio.played, hasLength(2));
      expect(url.text.trim(), 'https://example.com/a.mp3');
    });
  });

  group('Sentence Pool', () {
    const pathProviderChannel = MethodChannel(
      'plugins.flutter.io/path_provider',
    );
    late Directory storageDirectory;

    setUp(() {
      storageDirectory = Directory.systemTemp.createTempSync(
        'lingua_srs_edit_dialog_audio_test_',
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

    Future<(AppProvider, Sentence?)> openPool(
      WidgetTester tester,
      _RecordingAudio audio, {
      Sentence? sentence,
    }) async {
      final provider = await loadedProvider(tester);
      Sentence? stored;
      if (sentence != null) {
        stored = await tester.runAsync(
          () => provider.addSentenceToPool(sentence),
        );
      }
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AppProvider>.value(value: provider),
            ChangeNotifierProvider<AudioService>.value(value: audio),
          ],
          child: const MaterialApp(home: SentencePoolView()),
        ),
      );
      await tester.pump();
      await tester.pump();
      return (provider, stored);
    }

    Sentence appleSentence() => Sentence(
      targetText: '사과를 먹어요',
      translationText: 'I eat an apple',
      audioUrl: 'https://example.com/apple.mp3',
    );

    /// Saving writes to storage, so the dialog closes a little later.
    Future<void> saveAndWait(WidgetTester tester) async {
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      for (
        var i = 0;
        i < 50 && find.byType(AlertDialog).evaluate().isNotEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pumpAndSettle();
      // The dialog's controllers are disposed a second after it closes.
      await tester.pump(const Duration(seconds: 1));
    }

    testWidgets('rows have no audio button', (tester) async {
      await openPool(
        tester,
        _RecordingAudio(),
        sentence: appleSentence()..ttsText = '사과를 먹어요',
      );

      expect(find.text('I eat an apple'), findsOneWidget);
      expect(find.byType(AudioButton), findsNothing);
      expect(find.byIcon(Icons.volume_up_rounded), findsNothing);
      expect(find.byIcon(Icons.record_voice_over_outlined), findsNothing);
    });

    testWidgets('the edit dialog previews the audio URL and the TTS text', (
      tester,
    ) async {
      final audio = _RecordingAudio();
      await openPool(
        tester,
        audio,
        sentence: appleSentence()..ttsText = '사과를 먹어요 천천히',
      );

      await tester.tap(find.text('I eat an apple'));
      await tester.pumpAndSettle();
      expect(find.text('Edit Sentence'), findsOneWidget);

      await tester.tap(find.byTooltip('Play Audio'));
      await tester.pump();
      expect(audio.played, ['https://example.com/apple.mp3']);

      // A TTS text is already set, so its tile starts open.
      expect(find.widgetWithText(TextField, _ttsLabel), findsOneWidget);
      await tester.tap(find.byTooltip('Play Text-to-Speech'));
      await tester.pump();
      expect(audio.spoken, ['사과를 먹어요 천천히']);
    });

    testWidgets('previews TTS as the sentence when there is no TTS text', (
      tester,
    ) async {
      final audio = _RecordingAudio();
      await openPool(
        tester,
        audio,
        sentence: Sentence(targetText: '사과를 먹어요', translationText: 'apple'),
      );

      await tester.tap(find.text('apple'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Play Audio'), findsNothing);
      expect(find.text('Use this recording'), findsNothing);

      await tester.tap(find.text('Text-to-speech'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Play Text-to-Speech'));
      await tester.pump();
      expect(audio.spoken, ['사과를 먹어요']);
    });

    testWidgets('saves the TTS text and the choice to skip the recording', (
      tester,
    ) async {
      final (_, stored) = await openPool(
        tester,
        _RecordingAudio(),
        sentence: appleSentence(),
      );
      final sentence = stored!;
      expect(sentence.ttsText, isNull);
      expect(sentence.useAudio, isTrue);

      await tester.tap(find.text('I eat an apple'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Text-to-speech'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, _ttsLabel),
        '  사과를 먹어요 (slowly)  ',
      );
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pump();
      await saveAndWait(tester);

      expect(sentence.ttsText, '사과를 먹어요 (slowly)');
      expect(sentence.useAudio, isFalse);
      expect(sentence.audioUrl, 'https://example.com/apple.mp3');
      expect(sentence.playableAudioUrl, isNull);
      expect(sentence.speechText, '사과를 먹어요 (slowly)');
    });

    testWidgets('clearing the TTS text goes back to speaking the sentence', (
      tester,
    ) async {
      final (_, stored) = await openPool(
        tester,
        _RecordingAudio(),
        sentence: appleSentence()..ttsText = '다른 말',
      );
      final sentence = stored!;

      await tester.tap(find.text('I eat an apple'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, _ttsLabel), '');
      await tester.pump();
      await saveAndWait(tester);

      expect(sentence.ttsText, isNull);
      expect(sentence.speechText, '사과를 먹어요');
    });

    testWidgets('a new sentence can be added with TTS text', (tester) async {
      final (provider, _) = await openPool(tester, _RecordingAudio());

      await tester.tap(find.widgetWithText(FilledButton, 'Add Sentence'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Target Sentence (Markdown)'),
        '3개 주세요',
      );
      await tester.tap(find.text('Text-to-speech'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, _ttsLabel),
        '세 개 주세요',
      );
      await saveAndWait(tester);

      final added = provider.sentences.single;
      expect(added.targetText, '3개 주세요');
      expect(added.ttsText, '세 개 주세요');
      expect(added.useAudio, isTrue);
    });
  });
}
