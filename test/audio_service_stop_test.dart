import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:lingua_srs/services/audio_service.dart';

/// Stands in for the audioplayers plugin. A clip "plays" until [finishClip] is
/// called (or the service stops it), like a real clip would.
class _FakePlayer implements AudioPlayer {
  final _completeController = StreamController<void>.broadcast();
  final _stateController = StreamController<PlayerState>.broadcast();
  final played = <Source>[];
  var stopCount = 0;

  List<String> get playedPaths =>
      played.map((s) => (s as DeviceFileSource).path).toList();

  void finishClip() => _completeController.add(null);

  @override
  Stream<void> get onPlayerComplete => _completeController.stream;

  @override
  Stream<PlayerState> get onPlayerStateChanged => _stateController.stream;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #play) {
      played.add(invocation.positionalArguments.first as Source);
    } else if (invocation.memberName == #stop) {
      stopCount++;
    }
    return Future<void>.value();
  }
}

/// Stands in for flutter_tts with one installed offline Korean voice. An
/// utterance lasts until [stop] is called.
class _FakeTts implements FlutterTts {
  final spoken = <String>[];
  var stopCount = 0;

  /// When set, the voice lookup does not return until it is completed.
  Completer<void>? voicesGate;
  Completer<void>? _speaking;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final name = invocation.memberName;
    if (name == #getVoices) {
      final gate = voicesGate?.future ?? Future<void>.value();
      return gate.then(
        (_) => [
          {'name': 'ko-offline', 'locale': 'ko-KR', 'network_required': '0'},
        ],
      );
    }
    if (name == #isLanguageInstalled) return Future<dynamic>.value(true);
    if (name == #setVoice) return Future<dynamic>.value(1);
    if (name == #speak) {
      spoken.add(invocation.positionalArguments.first as String);
      _speaking = Completer<void>();
      return _speaking!.future;
    }
    if (name == #stop) {
      stopCount++;
      final speaking = _speaking;
      if (speaking != null && !speaking.isCompleted) speaking.complete();
    }
    return Future<dynamic>.value(1);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  AudioService serviceFor(
    _FakePlayer player, {
    _FakeTts? tts,
    bool offlineTts = false,
  }) {
    final service = AudioService.withPlayers(
      player: player,
      tts: tts ?? _FakeTts(),
      offlineTts: offlineTts,
    );
    addTearDown(service.dispose);
    return service;
  }

  group('answer sequence with audio files', () {
    test('plays the word, then the sentence, when nothing stops it', () async {
      final player = _FakePlayer();
      final service = serviceFor(player);

      final sequence = service.playAnswerSequence(
        vocabAudio: '/clips/word.mp3',
        sentenceAudio: '/clips/sentence.mp3',
      );
      await pumpEventQueue();
      expect(player.playedPaths, ['/clips/word.mp3']);

      player.finishClip();
      await Future<void>.delayed(const Duration(milliseconds: 450));
      expect(player.playedPaths, ['/clips/word.mp3', '/clips/sentence.mp3']);

      player.finishClip();
      await sequence;
      expect(service.isPlaying, isFalse);
    });

    test('stop() during the word cancels the sentence', () async {
      final player = _FakePlayer();
      final service = serviceFor(player);

      final sequence = service.playAnswerSequence(
        vocabAudio: '/clips/word.mp3',
        sentenceAudio: '/clips/sentence.mp3',
      );
      await pumpEventQueue();
      expect(service.isPlaying, isTrue);

      await service.stop();
      await sequence;

      expect(player.playedPaths, ['/clips/word.mp3']);
      expect(service.isPlaying, isFalse);
      expect(service.currentlyPlayingKey, isNull);
    });

    test('stop() in the pause cancels the sentence', () async {
      final player = _FakePlayer();
      final service = serviceFor(player);

      final sequence = service.playAnswerSequence(
        vocabAudio: '/clips/word.mp3',
        sentenceAudio: '/clips/sentence.mp3',
      );
      await pumpEventQueue();
      player.finishClip();
      await pumpEventQueue(); // the word is done; the sequence is pausing

      await service.stop();
      await sequence; // returns once the pause ends

      expect(player.playedPaths, ['/clips/word.mp3']);
      expect(service.isPlaying, isFalse);
    });

    test('a new playback is not cancelled by the one it replaced', () async {
      final player = _FakePlayer();
      final service = serviceFor(player);

      final first = service.playAudio('/clips/a.mp3');
      await pumpEventQueue();
      final second = service.playAudio('/clips/b.mp3');
      await pumpEventQueue();

      // The first clip winding down must not reset the second one's state.
      expect(service.isPlaying, isTrue);
      expect(service.currentlyPlayingKey, '/clips/b.mp3');

      player.finishClip();
      await Future.wait([first, second]);
      expect(service.isPlaying, isFalse);
    });
  });

  group('offline text-to-speech (Android)', () {
    test('stop() during an utterance stops the engine', () async {
      final tts = _FakeTts();
      final service = serviceFor(_FakePlayer(), tts: tts, offlineTts: true);

      final speaking = service.speak('안녕하세요', language: 'ko');
      await pumpEventQueue();
      expect(tts.spoken, ['안녕하세요']);
      expect(service.isPlaying, isTrue);
      expect(service.currentlyPlayingKey, 'tts_안녕하세요');

      await service.stop();
      await speaking;

      expect(tts.stopCount, 1);
      expect(service.isPlaying, isFalse);
      expect(service.currentlyPlayingKey, isNull);
    });

    test('stop() during the voice lookup prevents speech', () async {
      final tts = _FakeTts()..voicesGate = Completer<void>();
      final service = serviceFor(_FakePlayer(), tts: tts, offlineTts: true);

      final speaking = service.speak('안녕하세요', language: 'ko');
      await pumpEventQueue();
      await service.stop();
      tts.voicesGate!.complete();
      await speaking;

      expect(tts.spoken, isEmpty);
      expect(service.isPlaying, isFalse);
    });

    test('stop() during the word cancels the spoken sentence', () async {
      final tts = _FakeTts();
      final service = serviceFor(_FakePlayer(), tts: tts, offlineTts: true);

      final sequence = service.playAnswerSequence(
        vocabText: '단어',
        sentenceText: '문장',
        targetLanguage: 'ko',
      );
      await pumpEventQueue();
      expect(tts.spoken, ['단어']);

      await service.stop();
      await sequence;

      expect(tts.spoken, ['단어']);
      expect(service.isPlaying, isFalse);
    });
  });
}
