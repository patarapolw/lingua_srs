import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/sentence.dart';
import 'package:lingua_srs/providers/app_provider.dart';
import 'package:lingua_srs/services/audio_service.dart';
import 'package:lingua_srs/services/tts_voice.dart';
import 'package:lingua_srs/views/sentence_pool_view.dart';
import 'package:lingua_srs/widgets/dialog_save_shortcuts.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  Future<void> stop() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

/// Presses [key] with Ctrl, or with Cmd when [meta] is set.
Future<void> pressWithModifier(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool meta = false,
}) async {
  final modifier = meta
      ? LogicalKeyboardKey.metaLeft
      : LogicalKeyboardKey.controlLeft;
  await tester.sendKeyDownEvent(modifier);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(modifier);
  await tester.pump();
}

/// The text field labelled [label] has the keyboard focus.
bool hasFocus(WidgetTester tester, String label) => tester
    .widget<EditableText>(
      find.descendant(
        of: find.widgetWithText(TextField, label),
        matching: find.byType(EditableText),
      ),
    )
    .focusNode
    .hasFocus;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(setUpSecretStorage);

  group('DialogSaveShortcuts', () {
    Future<List<String>> pumpShortcuts(
      WidgetTester tester, {
      Completer<void>? pending,
    }) async {
      final saves = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DialogSaveShortcuts(
              onSave: () {
                saves.add('save');
                return pending?.future ?? Future<void>.value();
              },
              child: const TextField(maxLines: 3),
            ),
          ),
        ),
      );
      await tester.pump();
      return saves;
    }

    testWidgets('saves on Ctrl or Cmd with Enter or S', (tester) async {
      final saves = await pumpShortcuts(tester);

      await pressWithModifier(tester, LogicalKeyboardKey.enter);
      await pressWithModifier(tester, LogicalKeyboardKey.enter, meta: true);
      await pressWithModifier(tester, LogicalKeyboardKey.keyS);
      await pressWithModifier(tester, LogicalKeyboardKey.keyS, meta: true);

      expect(saves, hasLength(4));
    });

    testWidgets('works from inside a text field', (tester) async {
      final saves = await pumpShortcuts(tester);
      await tester.tap(find.byType(TextField));
      await tester.pump();

      await pressWithModifier(tester, LogicalKeyboardKey.enter);

      expect(saves, hasLength(1));
    });

    testWidgets('plain Enter and S do not save', (tester) async {
      final saves = await pumpShortcuts(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.pump();

      expect(saves, isEmpty);
    });

    testWidgets('a second press while saving does nothing', (tester) async {
      final pending = Completer<void>();
      final saves = await pumpShortcuts(tester, pending: pending);

      await pressWithModifier(tester, LogicalKeyboardKey.keyS);
      await pressWithModifier(tester, LogicalKeyboardKey.keyS);
      expect(saves, hasLength(1));

      pending.complete();
      await tester.pump();
      await pressWithModifier(tester, LogicalKeyboardKey.keyS);
      expect(saves, hasLength(2));
    });
  });

  group('Sentence Pool dialog', () {
    const pathProviderChannel = MethodChannel(
      'plugins.flutter.io/path_provider',
    );
    late Directory storageDirectory;

    setUp(() {
      storageDirectory = Directory.systemTemp.createTempSync(
        'lingua_srs_dialog_save_shortcuts_test_',
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

    Future<AppProvider> openPool(
      WidgetTester tester, {
      Sentence? sentence,
    }) async {
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
      if (sentence != null) {
        await tester.runAsync(() => provider.addSentenceToPool(sentence));
      }
      tester.view.physicalSize = const Size(1200, 2400);
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
          child: const MaterialApp(home: SentencePoolView()),
        ),
      );
      await tester.pump();
      await tester.pump();
      return provider;
    }

    /// Saving writes to storage, so the dialog closes a little later.
    Future<void> waitForClose(WidgetTester tester) async {
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

    testWidgets('adding starts in the sentence field and saves on Ctrl+Enter', (
      tester,
    ) async {
      final provider = await openPool(tester);
      await tester.tap(find.text('Add Sentence'));
      await tester.pumpAndSettle();

      expect(find.text('Add Sentence to Pool'), findsOneWidget);
      expect(hasFocus(tester, 'Target Sentence'), isTrue);

      await tester.enterText(
        find.widgetWithText(TextField, 'Target Sentence'),
        '배를 먹어요',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Translation'),
        'I eat a pear',
      );
      await pressWithModifier(tester, LogicalKeyboardKey.enter);
      await waitForClose(tester);

      expect(find.byType(AlertDialog), findsNothing);
      expect(provider.sentences.map((s) => s.targetText), contains('배를 먹어요'));
    });

    testWidgets('editing saves on Cmd+S before any field is clicked', (
      tester,
    ) async {
      final sentence = Sentence(
        targetText: '사과를 먹어요',
        translationText: 'I eat an apple',
      );
      await openPool(tester, sentence: sentence);
      await tester.tap(find.text('I eat an apple'));
      await tester.pumpAndSettle();
      expect(find.text('Edit Sentence'), findsOneWidget);
      expect(hasFocus(tester, 'Target Sentence'), isFalse);

      tester
              .widget<TextField>(find.widgetWithText(TextField, 'Translation'))
              .controller!
              .text =
          'I am eating an apple';
      await pressWithModifier(tester, LogicalKeyboardKey.keyS, meta: true);
      await waitForClose(tester);

      expect(find.byType(AlertDialog), findsNothing);
      expect(sentence.translationText, 'I am eating an apple');
    });
  });
}
