import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:lingua_srs/services/audio_service.dart';
import 'package:lingua_srs/widgets/audio_edit_fields.dart';
import 'package:lingua_srs/widgets/tts_language_sheet.dart';
import 'package:lingua_srs/models/vocab_item.dart';
import 'package:provider/provider.dart';

import 'debug_print_capture.dart';

/// Stands in for the audioplayers plugin; nothing here plays a clip.
class _FakePlayer implements AudioPlayer {
  final _completeController = StreamController<void>.broadcast();
  final _stateController = StreamController<PlayerState>.broadcast();

  @override
  Stream<void> get onPlayerComplete => _completeController.stream;

  @override
  Stream<PlayerState> get onPlayerStateChanged => _stateController.stream;

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

/// Stands in for flutter_tts with a configurable list of installed voices.
/// Utterances finish at once.
class _VoicesTts implements FlutterTts {
  _VoicesTts(
    this.voices, {
    this.unselectable = const {},
    this.notInstalled = const {},
  });

  final List<Map<String, String>> voices;

  /// Locales whose language data is missing.
  final Set<String> notInstalled;

  /// How often the voice list was asked for.
  var voiceListCalls = 0;

  /// Voices whose `setVoice` reports failure.
  final Set<String> unselectable;

  /// Every voice tried, in order, including the ones that failed.
  final tried = <String>[];
  final spoken = <String>[];

  /// The voice that was active for each utterance.
  final voiceUsed = <String>[];
  String? _current;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final name = invocation.memberName;
    if (name == #getVoices) {
      voiceListCalls++;
      return Future<dynamic>.value(voices);
    }
    if (name == #getDefaultEngine) {
      return Future<dynamic>.value('com.example.tts');
    }
    if (name == #isLanguageInstalled) {
      final locale = invocation.positionalArguments.first;
      return Future<dynamic>.value(!notInstalled.contains(locale));
    }
    if (name == #setVoice) {
      final voice = (invocation.positionalArguments.first as Map)['name'];
      tried.add(voice as String);
      if (unselectable.contains(voice)) return Future<dynamic>.value(0);
      _current = voice;
      return Future<dynamic>.value(1);
    }
    if (name == #speak) {
      spoken.add(invocation.positionalArguments.first as String);
      voiceUsed.add(_current ?? '');
    }
    return Future<dynamic>.value(1);
  }
}

Map<String, String> _voice(String name, String locale, {bool online = false}) =>
    {'name': name, 'locale': locale, 'network_required': online ? '1' : '0'};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // AudioService opens its on-disk audio cache through path_provider.
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory storageDirectory;

  setUp(() {
    storageDirectory = Directory.systemTemp.createTempSync(
      'lingua_srs_audio_service_tts_test_',
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

  AudioService offlineService(_VoicesTts tts, {int seed = 1}) {
    final service = AudioService.withPlayers(
      player: _FakePlayer(),
      tts: tts,
      offlineTts: true,
      random: Random(seed),
    );
    addTearDown(service.dispose);
    return service;
  }

  group('offline TTS voices', () {
    test('varies between several installed voices of the language', () async {
      final tts = _VoicesTts([
        _voice('ko-a', 'ko-KR'),
        _voice('ko-b', 'ko-KR'),
        _voice('ko-c', 'ko-KR'),
      ]);
      final service = offlineService(tts);

      for (var i = 0; i < 30; i++) {
        await service.speak('안녕하세요', language: 'ko');
      }

      expect(tts.spoken, hasLength(30));
      expect(
        tts.voiceUsed.toSet().length,
        greaterThan(1),
        reason: 'always the same voice would be the old behaviour',
      );
      expect(
        tts.voiceUsed.toSet().difference({'ko-a', 'ko-b', 'ko-c'}),
        isEmpty,
      );
    });

    test('prefers offline voices of the requested language', () async {
      final tts = _VoicesTts([
        _voice('ko-offline', 'ko-KR'),
        _voice('ko-online', 'ko-KR', online: true),
        _voice('ja-offline', 'ja-JP'),
      ]);
      final service = offlineService(tts);

      for (var i = 0; i < 15; i++) {
        await service.speak('안녕하세요', language: 'ko');
      }

      expect(tts.voiceUsed.toSet(), {'ko-offline'});
    });

    test('skips a voice that cannot be selected', () async {
      final tts = _VoicesTts(
        [_voice('ko-broken', 'ko-KR'), _voice('ko-good', 'ko-KR')],
        unselectable: {'ko-broken'},
      );
      final service = offlineService(tts);

      for (var i = 0; i < 20; i++) {
        await service.speak('안녕하세요', language: 'ko');
      }

      expect(tts.spoken, hasLength(20), reason: 'every utterance is spoken');
      expect(tts.voiceUsed.toSet(), {'ko-good'});
    });

    test('a region prefers voices of that region', () async {
      final tts = _VoicesTts([
        _voice('zh-cn-a', 'zh-CN'),
        _voice('zh-tw-a', 'zh-TW'),
        _voice('zh-cn-b', 'zh-CN'),
      ]);
      final service = offlineService(tts);

      for (var i = 0; i < 15; i++) {
        await service.speak('垃圾', language: 'zh-TW');
      }

      expect(tts.voiceUsed.toSet(), {'zh-tw-a'});
    });

    test('falls back to the language without a voice of the region', () async {
      final tts = _VoicesTts([_voice('zh-cn-a', 'zh-CN')]);
      final service = offlineService(tts);

      await service.speak('垃圾', language: 'zh-TW');

      expect(tts.voiceUsed, ['zh-cn-a']);
    });

    test('uses a network voice without an offline one', () async {
      final tts = _VoicesTts([
        _voice('ko-online', 'ko-KR', online: true),
        _voice('ja-offline', 'ja-JP'),
      ]);
      final service = offlineService(tts);

      await service.speak('안녕하세요', language: 'ko');

      expect(tts.voiceUsed, ['ko-online']);
    });

    test('a network voice of the region beats an offline voice of another '
        'region', () async {
      final tts = _VoicesTts([
        _voice('zh-cn-offline', 'zh-CN'),
        _voice('zh-tw-online', 'zh-TW', online: true),
      ]);
      final service = offlineService(tts);

      for (var i = 0; i < 10; i++) {
        await service.speak('垃圾', language: 'zh-TW');
      }

      expect(tts.voiceUsed.toSet(), {'zh-tw-online'});
    });

    test('speaks nothing when the language has no voice', () async {
      final tts = _VoicesTts([_voice('ja-offline', 'ja-JP')]);
      final service = offlineService(tts);
      final printed = captureDebugPrints();

      await service.speak('안녕하세요', language: 'ko');

      expect(tts.spoken, isEmpty);
      expect(printed, [contains('No Android TTS voice')]);
    });
  });

  group('the voice used', () {
    test('records a voice of another region as a substitute', () async {
      final tts = _VoicesTts([_voice('zh-cn-a', 'zh-CN')]);
      final service = offlineService(tts);

      await service.speak('zh-TW:垃圾', language: 'ko');

      final used = service.lastVoice!;
      expect(used.text, 'zh-TW:垃圾');
      expect(used.requested, 'zh-TW');
      expect(used.voice!.name, 'zh-cn-a');
      expect(used.isSubstitute, isTrue);
    });

    test('records no voice when none of the language is installed', () async {
      final service = offlineService(_VoicesTts([_voice('ko-a', 'ko-KR')]));
      captureDebugPrints();

      await service.speak('ja:ゴミ', language: 'ko');

      expect(service.lastVoice!.voice, isNull);
      expect(service.lastVoice!.requested, 'ja');
    });

    test('finds a region voice reported with three-letter codes', () async {
      final tts = _VoicesTts([
        _voice('mainland', 'zh-CN'),
        _voice('taiwan', 'cmn-TW'),
      ]);
      final service = offlineService(tts);

      await service.speak('zh-TW:垃圾', language: 'ko');

      expect(tts.voiceUsed, ['taiwan']);
      expect(service.lastVoice!.isSubstitute, isFalse);
    });

    test('a region prefix of another language prefers that region', () async {
      final tts = _VoicesTts([
        _voice('ko-kr', 'ko-KR'),
        _voice('ko-kp', 'ko-KP'),
      ]);
      final service = offlineService(tts);

      for (var i = 0; i < 10; i++) {
        await service.speak('ko-KP:안녕', language: 'zh');
      }

      expect(tts.voiceUsed.toSet(), {'ko-kp'});
    });

    test('lists the engine and its voices by locale', () async {
      final service = offlineService(
        _VoicesTts([
          _voice('zh-tw-a', 'zh-TW'),
          _voice('ko-a', 'ko-KR', online: true),
        ]),
      );

      final list = await service.listVoices();

      expect(list.engine, 'com.example.tts');
      expect(list.voices.map((v) => v.locale), ['ko-KR', 'zh-TW']);
      expect(list.voices.map((v) => v.offline), [false, true]);
      expect(list.voices.map((v) => v.installed), [null, true]);
    });

    test('keeps the voice list instead of asking the engine again', () async {
      final tts = _VoicesTts([_voice('ko-a', 'ko-KR')]);
      final service = offlineService(tts);

      final first = await service.listVoices();
      final second = await service.listVoices();

      expect(identical(first, second), isTrue);
      expect(tts.voiceListCalls, 1);
    });

    testWidgets('the language sheet picks a prefix by name or code', (
      tester,
    ) async {
      final service = offlineService(
        _VoicesTts(
          [
            _voice('zh-tw-a', 'zh-TW'),
            _voice('zh-tw-b', 'zh-TW', online: true),
            _voice('ja-online', 'ja-JP', online: true),
            _voice('ko-online', 'ko-KR', online: true),
            _voice('ar-local', 'ar'),
            _voice('zh-cn-a', 'zh-CN'),
          ],
          notInstalled: {'ar'},
        ),
      );
      final controller = TextEditingController(text: 'zh-CN:垃圾');
      addTearDown(controller.dispose);
      final fallback = TextEditingController(text: '垃圾');
      addTearDown(fallback.dispose);
      await tester.pumpWidget(
        ChangeNotifierProvider<AudioService>.value(
          value: service,
          child: MaterialApp(
            home: Scaffold(
              body: TtsTextField(
                controller: controller,
                spokenFallback: fallback,
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(() => service.listVoices());

      await tester.tap(find.text('Spoken in Chinese (China)'));
      await tester.pumpAndSettle();

      List<String?> rows() => tester
          .widgetList<ListTile>(
            find.descendant(
              of: find.byType(TtsLanguageSheet),
              matching: find.byType(ListTile),
            ),
          )
          .map((tile) => (tile.title as Text?)?.data)
          .toList();
      // The text's language and the default one come first; Arabic has no
      // installed voice; the engine stays in the log.
      expect(rows(), [
        'Default (Korean)',
        'Chinese (China)',
        'Chinese (Taiwan)',
        'Korean (South Korea)',
        'Japanese (Japan)',
      ]);
      expect(find.textContaining('com.example.tts'), findsNothing);

      await tester.enterText(find.byType(TextField).last, 'taiw');
      await tester.pumpAndSettle();
      expect(rows(), ['Chinese (Taiwan)']);

      // Widget tests must leave debugPrint as they found it.
      final printed = <String>[];
      final originalDebugPrint = debugPrint;
      debugPrint = (message, {wrapWidth}) => printed.add(message ?? '');
      await tester.tap(find.text('Chinese (Taiwan)'));
      await tester.pumpAndSettle();
      debugPrint = originalDebugPrint;

      expect(controller.text, 'zh-TW:垃圾', reason: 'the prefix is replaced');
      expect(printed.single, contains('engine com.example.tts'));
      expect(printed.single, contains('zh-TW zh-tw-b, network'));
      expect(printed.single, contains('zh-CN zh-cn-a, offline, installed'));
      expect(printed.single, isNot(contains('ko-online')));

      await tester.tap(find.text('Spoken in Chinese (Taiwan)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Default (Korean)'));
      await tester.pumpAndSettle();

      expect(controller.text, '垃圾', reason: 'the default has no prefix');
      expect(find.text('Spoken in Korean (default)'), findsOneWidget);
    });

    test('a TTS text that is only a prefix speaks the word in it', () {
      final vocab = VocabItem(
        targetWord: '垃圾',
        translation: 'trash',
        pos: 'nouns',
        ttsText: 'zh-TW:',
      );
      expect(vocab.speechText, 'zh-TW:垃圾');
    });

    testWidgets('the editor note warns when another voice spoke', (
      tester,
    ) async {
      final service = offlineService(_VoicesTts([_voice('zh-cn-a', 'zh-CN')]));
      await tester.runAsync(() => service.speak('zh-TW:垃圾', language: 'zh'));

      await tester.pumpWidget(
        ChangeNotifierProvider<AudioService>.value(
          value: service,
          child: const MaterialApp(
            home: Scaffold(body: TtsVoiceNote(spokenText: 'zh-TW:垃圾')),
          ),
        ),
      );

      expect(
        find.text('No zh-TW voice found; spoken by zh-CN (zh-cn-a).'),
        findsOneWidget,
      );
    });
  });

  group('what TTS says', () {
    test('skips text in round brackets', () async {
      final tts = _VoicesTts([_voice('ko-a', 'ko-KR')]);
      final service = offlineService(tts);

      await service.speak('먹다 (to eat)', language: 'ko');
      await service.speak('저는 **사과**(apple)를 먹어요', language: 'ko');

      expect(tts.spoken, ['먹다', '저는 사과를 먹어요']);
    });

    test('says nothing for text that is only a bracketed note', () async {
      final tts = _VoicesTts([_voice('ko-a', 'ko-KR')]);
      final service = offlineService(tts);

      await service.speak('(only a note)', language: 'ko');

      expect(tts.spoken, isEmpty);
    });

    test('a locale prefix picks the voice and is not spoken', () async {
      final tts = _VoicesTts([
        _voice('ko-a', 'ko-KR'),
        _voice('zh-cn-a', 'zh-CN'),
        _voice('zh-tw-a', 'zh-TW'),
      ]);
      final service = offlineService(tts);

      await service.speak('zh-TW:垃圾', language: 'ko');
      await service.speak('세 개', language: 'ko');

      expect(tts.spoken, ['垃圾', '세 개']);
      expect(tts.voiceUsed, ['zh-tw-a', 'ko-a']);
    });

    test('a colon followed by a space is spoken as text', () async {
      final tts = _VoicesTts([_voice('ko-a', 'ko-KR')]);
      final service = offlineService(tts);

      await service.speak('ko: 세 개', language: 'ko');

      expect(tts.spoken, ['ko: 세 개']);
    });

    test('the online TTS URL uses the prefix locale, without the prefix', () {
      final service = offlineService(_VoicesTts([]));

      final prefixed = Uri.parse(service.getTtsUrl('zh-TW:垃圾', language: 'ko'))
          .queryParameters;
      expect(prefixed['q'], '垃圾');
      expect(prefixed['tl'], 'zh-TW');

      final plain = Uri.parse(service.getTtsUrl('垃圾', language: 'zh'))
          .queryParameters;
      expect(plain['q'], '垃圾');
      expect(plain['tl'], 'zh-CN');

      final korean = Uri.parse(service.getTtsUrl('ko:세 개', language: 'zh'))
          .queryParameters;
      expect(korean['q'], '세 개');
      expect(korean['tl'], 'ko');
    });

    test('the online TTS URL leaves out bracketed text too', () {
      final service = offlineService(_VoicesTts([]));

      final url = service.getTtsUrl('먹다 (to eat)', language: 'ko');

      expect(Uri.parse(url).queryParameters['q'], '먹다');
    });
  });
}
