import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:lingua_srs/services/audio_service.dart';

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
  _VoicesTts(this.voices, {this.unselectable = const {}});

  final List<Map<String, String>> voices;

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
    if (name == #getVoices) return Future<dynamic>.value(voices);
    if (name == #isLanguageInstalled) return Future<dynamic>.value(true);
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

    test('only considers offline voices of the requested language', () async {
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

    test('speaks nothing when no offline voice is installed', () async {
      final tts = _VoicesTts([_voice('ko-online', 'ko-KR', online: true)]);
      final service = offlineService(tts);

      await service.speak('안녕하세요', language: 'ko');

      expect(tts.spoken, isEmpty);
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

    test('a tts locale prefix picks that region\'s voice', () async {
      final tts = _VoicesTts([
        _voice('zh-cn-a', 'zh-CN'),
        _voice('zh-tw-a', 'zh-TW'),
        _voice('zh-cn-b', 'zh-CN'),
      ]);
      final service = offlineService(tts);

      for (var i = 0; i < 10; i++) {
        await service.speak('zh-TW:垃圾', language: 'zh-CN');
      }

      expect(tts.spoken, everyElement('垃圾'));
      expect(tts.voiceUsed, everyElement('zh-tw-a'));
    });

    test(
      'falls back to any voice of the language without the region',
      () async {
        final tts = _VoicesTts([_voice('zh-cn-a', 'zh-CN')]);
        final service = offlineService(tts);

        await service.speak('zh-TW:垃圾', language: 'zh-CN');

        expect(tts.spoken, ['垃圾']);
        expect(tts.voiceUsed, ['zh-cn-a']);
      },
    );

    test('the online TTS URL uses the tts locale prefix', () {
      final service = offlineService(_VoicesTts([]));

      final prefixed = Uri.parse(
        service.getTtsUrl('zh-TW:垃圾', language: 'zh-CN'),
      ).queryParameters;
      expect(prefixed['tl'], 'zh-TW');
      expect(prefixed['q'], '垃圾');

      final taiwan = Uri.parse(service.getTtsUrl('垃圾', language: 'zh-TW'))
          .queryParameters;
      expect(taiwan['tl'], 'zh-TW');

      final spaced = Uri.parse(service.getTtsUrl('en: hello', language: 'ko'))
          .queryParameters;
      expect(spaced['tl'], 'ko');
      expect(spaced['q'], 'en: hello');
    });

    test('the online TTS URL leaves out bracketed text too', () {
      final service = offlineService(_VoicesTts([]));

      final url = service.getTtsUrl('먹다 (to eat)', language: 'ko');

      expect(Uri.parse(url).queryParameters['q'], '먹다');
    });
  });
}
