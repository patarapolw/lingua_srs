import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../models/sentence.dart';
import 'tts_text.dart';
import 'tts_voice.dart';

class AudioService extends ChangeNotifier {
  final AudioPlayer _player;
  final FlutterTts _tts;
  final bool _offlineTts;
  final Random _random;
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

  TtsVoiceUsed? _lastVoice;

  /// The voice the last offline TTS utterance was spoken with, or tried to
  /// be, so an editor can say when a locale prefix found no voice of its own.
  TtsVoiceUsed? get lastVoice => _lastVoice;

  /// Every voice of the device's current TTS engine, for showing which
  /// locales can be used in a `tts` prefix. Only offline TTS (Android) has a
  /// voice list; elsewhere this is empty.
  Future<TtsVoiceList> listVoices() async {
    if (!usesOfflineTts) return const TtsVoiceList(null, []);
    String? engine;
    var voices = <TtsVoice>[];
    try {
      final defaultEngine = await _tts.getDefaultEngine;
      engine = defaultEngine?.toString();
      voices = TtsVoice.fromPlugin(await _tts.getVoices);
      final installed = <String, bool>{};
      for (final voice in voices) {
        installed[voice.locale] ??=
            await _tts.isLanguageInstalled(voice.locale) == true;
      }
      voices = [
        for (final voice in voices)
          voice.withInstalled(installed[voice.locale] ?? false),
      ];
    } catch (e) {
      debugPrint('Could not list TTS voices: $e');
    }
    voices.sort((a, b) {
      final byLocale = a.locale.compareTo(b.locale);
      return byLocale != 0 ? byLocale : a.name.compareTo(b.name);
    });
    return TtsVoiceList(engine, voices);
  }

  AudioService() : this.withPlayers();

  /// Lets tests supply fake players, and force the offline-TTS code path on a
  /// non-Android host.
  @visibleForTesting
  AudioService.withPlayers({
    AudioPlayer? player,
    FlutterTts? tts,
    bool? offlineTts,
    Random? random,
  }) : _player = player ?? AudioPlayer(),
       _random = random ?? Random(),
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

  /// The language code for the online TTS service. Chinese keeps its region
  /// (`zh-TW` for Taiwan and traditional script, else `zh-CN`); other
  /// languages are reduced to the language alone.
  String _resolveLanguageCode(String? lang) {
    if (lang == null || lang.isEmpty) return 'ko';
    final lower = lang.toLowerCase().trim();
    final parts = lower.split(RegExp('[-_]'));
    if (parts.first == 'zh' || parts.first == 'chinese') {
      const traditional = {'tw', 'hant', 'hk', 'mo'};
      return parts.skip(1).any(traditional.contains) ? 'zh-TW' : 'zh-CN';
    }
    if (lower == 'ko' || lower == 'korean') return 'ko';
    if (lower == 'ja' || lower == 'japanese') return 'ja';
    if (lower == 'es' || lower == 'spanish') return 'es';
    if (lower == 'fr' || lower == 'french') return 'fr';
    if (lower == 'de' || lower == 'german') return 'de';
    if (lower == 'en' || lower == 'english') return 'en';
    return parts.first;
  }

  /// Generates an audio stream URL for TTS. A locale prefix on [text]
  /// (`zh-TW:垃圾`, see [TtsText]) picks the voice instead of [language].
  String getTtsUrl(String text, {String? language}) {
    final tts = TtsText.parse(text);
    return _ttsUrl(
      Sentence.cleanForSpeech(tts.text),
      language: tts.locale ?? language,
    );
  }

  String _ttsUrl(String clean, {String? language}) {
    final lang = _resolveLanguageCode(language);
    final encoded = Uri.encodeComponent(clean);
    return 'https://translate.google.com/translate_tts?ie=UTF-8&tl=$lang&client=tw-ob&q=$encoded';
  }

  bool _isCurrent(int session) => !_isDisposed && session == _generation;

  /// Uses an installed offline Android voice; other platforms stream and cache online TTS.
  ///
  /// A locale prefix on [text] (`zh-TW:垃圾`, see [TtsText]) is not spoken:
  /// it picks the voice instead of [language].
  Future<void> speak(String text, {String? language}) async {
    if (Sentence.cleanForSpeech(TtsText.parse(text).text).isEmpty) return;
    await _speak(text, ++_generation, language: language);
  }

  Future<void> _speak(String text, int session, {String? language}) async {
    final tts = TtsText.parse(text);
    final clean = Sentence.cleanForSpeech(tts.text);
    if (clean.isEmpty) return;
    final voice = tts.locale ?? language;

    if (usesOfflineTts) {
      await _haltPlayback();
      if (!_isCurrent(session)) return;
      await _speakWithOfflineAndroidTts(clean, text, session, language: voice);
      return;
    }

    final ttsUrl = _ttsUrl(clean, language: voice);
    await _playAudio(ttsUrl, session, playingKey: 'tts_${text.trim()}');
  }

  Future<void> _speakWithOfflineAndroidTts(
    String cleanText,
    String originalText,
    int session, {
    String? language,
  }) async {
    try {
      // A region given with the language (a `ko-KR:` prefix) is kept, so its
      // voices are preferred; otherwise the language is resolved as for
      // online TTS, which turns plain `zh` into `zh-CN`.
      final requested = language != null && TtsVoice.regionOf(language) != null
          ? language
          : _resolveLanguageCode(language);
      final requestedLanguage = TtsVoice.languageOf(requested);
      final requestedRegion = TtsVoice.regionOf(requested);
      final availableVoices = await _tts.getVoices;
      if (!_isCurrent(session)) return;
      if (availableVoices is! List) {
        debugPrint('Android offline TTS returned an invalid voice list.');
        return;
      }

      final offlineVoices = TtsVoice.fromPlugin(availableVoices)
          .where(
            (voice) => voice.offline && voice.language == requestedLanguage,
          )
          .toList();
      // A language can have several installed voices. Varying them keeps
      // reviews from sounding monotonous; any that fails is skipped below.
      offlineVoices.shuffle(_random);
      // A region (zh-TW) puts that region's voices first; the language's
      // other voices are still tried when none of them can be selected.
      if (requestedRegion != null) {
        bool inRegion(TtsVoice voice) => voice.isInRegion(requestedRegion);
        final preferred = offlineVoices.where(inRegion).toList();
        offlineVoices
          ..removeWhere(inRegion)
          ..insertAll(0, preferred);
      }

      TtsVoice? selected;
      for (final voice in offlineVoices) {
        if (await _tts.isLanguageInstalled(voice.locale) != true) continue;
        final choice = {'name': voice.name, 'locale': voice.locale};
        if (await _tts.setVoice(choice) == 1) {
          selected = voice;
          break;
        }
      }
      if (!_isCurrent(session)) return;
      _lastVoice = TtsVoiceUsed(
        text: originalText.trim(),
        requested: requested,
        voice: selected,
      );

      if (selected == null) {
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
