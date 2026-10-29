import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../models/sentence.dart';

class AudioService extends ChangeNotifier {
  final AudioPlayer _player;
  final FlutterTts _tts;
  final bool _offlineTts;
  Directory? _cacheDir;

  bool _isPlaying = false;
  String? _currentlyPlayingKey;
  bool _isSpeakingWithNativeTts = false;
  StreamSubscription? _completeSub;
  Completer<void>? _activePlaybackCompleter;
  bool _isDisposed = false;

  /// Bumped by every [stop] and by every new playback. An async playback (a
  /// single clip, a TTS utterance or a whole answer sequence) remembers the
  /// value it started under and gives up as soon as it no longer matches, so a
  /// stopped or superseded playback can neither start its next clip nor
  /// overwrite the state of the playback that replaced it.
  int _generation = 0;

  bool get isPlaying => _isPlaying;
  String? get currentlyPlayingKey => _currentlyPlayingKey;
  bool get usesOfflineTts => _offlineTts;

  AudioService() : this.withPlayers();

  /// Lets tests supply fake players, and force the offline-TTS code path on a
  /// non-Android host.
  @visibleForTesting
  AudioService.withPlayers({
    AudioPlayer? player,
    FlutterTts? tts,
    bool? offlineTts,
  }) : _player = player ?? AudioPlayer(),
       _tts = tts ?? FlutterTts(),
       _offlineTts = offlineTts ?? (!kIsWeb && Platform.isAndroid) {
    _initCacheDir();
    _completeSub = _player.onPlayerComplete.listen((_) {
      _isPlaying = false;
      _currentlyPlayingKey = null;
      if (!_isDisposed) notifyListeners();
      if (_activePlaybackCompleter != null &&
          !_activePlaybackCompleter!.isCompleted) {
        _activePlaybackCompleter!.complete();
      }
    });

    _player.onPlayerStateChanged.listen((state) {
      final playing = state == PlayerState.playing;
      if (playing != _isPlaying) {
        _isPlaying = playing;
        if (!_isDisposed) notifyListeners();
      }
    });
  }

  Future<void> _initCacheDir() async {
    try {
      Directory baseDir;
      try {
        baseDir = await getApplicationCacheDirectory();
      } catch (_) {
        baseDir = await getApplicationSupportDirectory();
      }

      final targetDir = Platform.isWindows
          ? Directory(
              '${Platform.environment['LOCALAPPDATA'] ?? baseDir.path}${Platform.pathSeparator}cc.polv${Platform.pathSeparator}lingua.srs${Platform.pathSeparator}audio_cache',
            )
          : Directory('${baseDir.path}${Platform.pathSeparator}audio_cache');

      _cacheDir = targetDir;
      if (!await _cacheDir!.exists()) {
        await _cacheDir!.create(recursive: true);
      }

      await _migrateLegacyCacheIfNeeded();
    } catch (e) {
      debugPrint('Error initializing audio sandbox cache directory: $e');
    }
  }

  Future<void> _migrateLegacyCacheIfNeeded() async {
    if (_cacheDir == null || !Platform.isWindows) return;

    final legacyDir = Directory(
      '${Platform.environment['APPDATA'] ?? ''}${Platform.pathSeparator}com.example${Platform.pathSeparator}lingua_srs${Platform.pathSeparator}audio_cache',
    );
    if (!await legacyDir.exists()) return;

    final cachedEntities = await _cacheDir!.list().toList();
    if (cachedEntities.any((entity) => entity is File || entity is Directory)) {
      return;
    }

    await _copyCacheTree(legacyDir, _cacheDir!);
  }

  Future<void> _copyCacheTree(Directory sourceDir, Directory targetDir) async {
    await for (final entity in sourceDir.list(
      recursive: false,
      followLinks: false,
    )) {
      final fileName = entity.path.split(Platform.pathSeparator).last;
      final destinationPath =
          '${targetDir.path}${Platform.pathSeparator}$fileName';

      if (entity is File) {
        final destination = File(destinationPath);
        if (!await destination.exists()) {
          await entity.copy(destination.path);
        }
      } else if (entity is Directory) {
        final childTarget = Directory(destinationPath);
        if (!await childTarget.exists()) {
          await childTarget.create(recursive: true);
        }
        await _copyCacheTree(entity, childTarget);
      }
    }
  }

  String _getCacheFilePath(String url) {
    final hash = md5.convert(utf8.encode(url)).toString();
    return '${_cacheDir!.path}/$hash.mp3';
  }

  Future<void> _downloadAndCache(String url, String targetPath) async {
    try {
      final uri = Uri.parse(url);
      final response = await http
          .get(
            uri,
            headers: {
              'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
            },
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200 && response.bodyBytes.length > 200) {
        final tempFile = File('$targetPath.tmp');
        await tempFile.writeAsBytes(response.bodyBytes);
        await tempFile.rename(targetPath);
        debugPrint('Successfully cached audio to: $targetPath');
      }
    } catch (e) {
      debugPrint('Background download failed for $url: $e');
    }
  }

  /// Pre-fetches a list of audio or TTS URLs in background so they are ready for instant offline play
  void prefetchAudios(List<String?> urls) {
    if (_cacheDir == null) return;
    for (final url in urls) {
      if (url == null || url.trim().isEmpty) continue;
      final trimmed = url.trim();
      if (!trimmed.startsWith('http://') && !trimmed.startsWith('https://')) {
        continue;
      }

      final cachePath = _getCacheFilePath(trimmed);
      final file = File(cachePath);
      if (!file.existsSync() || file.lengthSync() < 200) {
        unawaited(_downloadAndCache(trimmed, cachePath));
      }
    }
  }

  String _resolveLanguageCode(String? lang) {
    if (lang == null || lang.isEmpty) return 'ko';
    final lower = lang.toLowerCase().trim();
    if (lower == 'ko' || lower == 'korean') return 'ko';
    if (lower == 'ja' || lower == 'japanese') return 'ja';
    if (lower == 'zh' || lower == 'chinese') return 'zh-CN';
    if (lower == 'es' || lower == 'spanish') return 'es';
    if (lower == 'fr' || lower == 'french') return 'fr';
    if (lower == 'de' || lower == 'german') return 'de';
    if (lower == 'en' || lower == 'english') return 'en';
    if (lower.contains('-')) return lower.split('-').first;
    return lower;
  }

  /// Generates an audio stream URL for TTS
  String getTtsUrl(String text, {String? language}) {
    final clean = Sentence.cleanForSpeech(text);
    final lang = _resolveLanguageCode(language);
    final encoded = Uri.encodeComponent(clean);
    return 'https://translate.google.com/translate_tts?ie=UTF-8&tl=$lang&client=tw-ob&q=$encoded';
  }

  bool _isCurrent(int session) => !_isDisposed && session == _generation;

  /// Uses an installed offline Android voice; other platforms stream and cache online TTS.
  Future<void> speak(String text, {String? language}) async {
    if (Sentence.cleanForSpeech(text).isEmpty) return;
    await _speak(text, ++_generation, language: language);
  }

  Future<void> _speak(String text, int session, {String? language}) async {
    final clean = Sentence.cleanForSpeech(text);
    if (clean.isEmpty) return;

    if (usesOfflineTts) {
      await _haltPlayback();
      if (!_isCurrent(session)) return;
      await _speakWithOfflineAndroidTts(
        clean,
        text,
        session,
        language: language,
      );
      return;
    }

    final ttsUrl = getTtsUrl(clean, language: language);
    await _playAudio(ttsUrl, session, playingKey: 'tts_${text.trim()}');
  }

  Future<void> _speakWithOfflineAndroidTts(
    String cleanText,
    String originalText,
    int session, {
    String? language,
  }) async {
    try {
      final requestedLanguage = _resolveLanguageCode(language)
          .toLowerCase()
          .split('-')
          .first;
      final availableVoices = await _tts.getVoices;
      if (!_isCurrent(session)) return;
      if (availableVoices is! List) {
        debugPrint('Android offline TTS returned an invalid voice list.');
        return;
      }

      final offlineVoices = availableVoices
          .whereType<Map>()
          .map((voice) => Map<String, dynamic>.from(voice))
          .where((voice) {
            final locale = voice['locale']?.toString().toLowerCase() ?? '';
            return locale.split('-').first == requestedLanguage &&
                voice['network_required']?.toString() == '0';
          })
          .toList();

      var voiceSelected = false;
      for (final voice in offlineVoices) {
        final locale = voice['locale']?.toString();
        final name = voice['name']?.toString();
        if (locale == null ||
            name == null ||
            await _tts.isLanguageInstalled(locale) != true) {
          continue;
        }
        if (await _tts.setVoice({'name': name, 'locale': locale}) == 1) {
          voiceSelected = true;
          break;
        }
      }

      if (!voiceSelected) {
        debugPrint(
          'No installed offline Android TTS voice is available for "$requestedLanguage". '
          'Install an offline voice in Android text-to-speech settings.',
        );
        return;
      }

      await _tts.awaitSpeakCompletion(true);
      // Every await above is a chance for stop() to have run. The native-TTS
      // flag is only set below, so stop() could not have halted the engine.
      if (!_isCurrent(session)) return;
      _currentlyPlayingKey = 'tts_${originalText.trim()}';
      _isPlaying = true;
      _isSpeakingWithNativeTts = true;
      notifyListeners();
      await _tts.speak(cleanText);
    } catch (e) {
      debugPrint('Android offline TTS failed: $e');
    } finally {
      if (_isCurrent(session)) {
        _isSpeakingWithNativeTts = false;
        _isPlaying = false;
        _currentlyPlayingKey = null;
        notifyListeners();
      }
    }
  }

  /// Plays a single audio source.
  /// If it is a remote URL:
  /// - If already cached locally, plays the local file instantly with 0 latency.
  /// - If not cached yet, streams from the URL immediately while caching in the background for subsequent offline runs.
  Future<void> playAudio(String? urlOrPath, {String? playingKey}) async {
    if (urlOrPath == null || urlOrPath.trim().isEmpty) return;
    await _playAudio(urlOrPath.trim(), ++_generation, playingKey: playingKey);
  }

  Future<void> _playAudio(
    String trimmed,
    int session, {
    String? playingKey,
  }) async {
    try {
      await _haltPlayback();
      if (!_isCurrent(session)) return;

      _currentlyPlayingKey = playingKey ?? trimmed;
      _isPlaying = true;
      notifyListeners();

      final completer = _activePlaybackCompleter = Completer<void>();

      Source source;
      final isRemote =
          trimmed.startsWith('http://') || trimmed.startsWith('https://');

      if (isRemote) {
        // Ensure cache directory exists
        if (_cacheDir == null) {
          await _initCacheDir();
          if (!_isCurrent(session)) return;
        }

        final cachePath = _cacheDir != null ? _getCacheFilePath(trimmed) : null;
        final cachedFile = cachePath != null ? File(cachePath) : null;

        if (cachedFile != null &&
            cachedFile.existsSync() &&
            cachedFile.lengthSync() > 200) {
          // Play from local cache (0 latency, 100% offline!)
          source = DeviceFileSource(cachePath!);
        } else {
          // Stream immediately on first run
          source = UrlSource(trimmed);
          // And download in the background for offline caching
          if (cachePath != null) {
            unawaited(_downloadAndCache(trimmed, cachePath));
          }
        }
      } else if (trimmed.startsWith('assets/')) {
        source = AssetSource(trimmed.replaceFirst('assets/', ''));
      } else {
        source = DeviceFileSource(trimmed);
      }

      await _player.play(source);
      await completer.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () {},
      );
    } catch (e) {
      debugPrint('Audio playback error: $e');
    } finally {
      // A stopped or superseded playback must leave the state alone: stop()
      // already reset it, or a newer playback now owns it.
      if (_isCurrent(session)) {
        _isPlaying = false;
        _currentlyPlayingKey = null;
        notifyListeners();
      }
    }
  }

  /// Plays vocab first (audio URL or TTS), then waits and plays the chosen sentence (audio URL or TTS).
  ///
  /// [stop] (or any newer playback) cancels the whole sequence, including the
  /// pause between the two clips and the sentence that has not started yet.
  Future<void> playAnswerSequence({
    String? vocabAudio,
    String? vocabText,
    String? sentenceAudio,
    String? sentenceText,
    String? targetLanguage,
  }) async {
    final session = ++_generation;
    await _haltPlayback();
    if (!_isCurrent(session)) return;

    // 1. Play vocab audio if URL exists, else speak vocabText via TTS
    if (vocabAudio != null && vocabAudio.trim().isNotEmpty) {
      await _playAudio(vocabAudio.trim(), session);
    } else if (vocabText != null && vocabText.trim().isNotEmpty) {
      await _speak(vocabText, session, language: targetLanguage);
    }
    if (!_isCurrent(session)) return;

    // Small pleasant pause between word and sentence
    await Future.delayed(const Duration(milliseconds: 350));
    if (!_isCurrent(session)) return;

    // 2. Play sentence audio if URL exists, else speak sentenceText via TTS
    if (sentenceAudio != null && sentenceAudio.trim().isNotEmpty) {
      await _playAudio(sentenceAudio.trim(), session);
    } else if (sentenceText != null && sentenceText.trim().isNotEmpty) {
      await _speak(sentenceText, session, language: targetLanguage);
    }
  }

  /// Stops whatever is playing and cancels any answer sequence in progress.
  Future<void> stop() async {
    _generation++;
    await _haltPlayback();
  }

  /// Silences the players and resets the playing state, without cancelling the
  /// playback session that called it (see [_generation]).
  Future<void> _haltPlayback() async {
    try {
      final completer = _activePlaybackCompleter;
      if (completer != null && !completer.isCompleted) {
        completer.complete();
      }
      await _player.stop();
      if (_isSpeakingWithNativeTts) {
        await _tts.stop();
      }
    } catch (e) {
      debugPrint('Error stopping audio: $e');
    } finally {
      _isSpeakingWithNativeTts = false;
      _isPlaying = false;
      _currentlyPlayingKey = null;
      if (!_isDisposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    _completeSub?.cancel();
    _player.dispose();
    if (_isSpeakingWithNativeTts) {
      _tts.stop();
    }
    super.dispose();
  }
}
