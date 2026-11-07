/// A voice of the device's text-to-speech engine, as flutter_tts lists it.
///
/// Android reports locales as BCP 47 tags (`zh-TW`, `ko-KR`), but some engines
/// use three-letter codes (`cmn`, `zho`, `kor`, `TWN`). [language] and
/// [region] map those to the two-letter codes a `tts` prefix uses, so
/// `zh-TW:` finds a voice whatever the engine calls it.
class TtsVoice {
  final String name;

  /// The locale exactly as the engine reports it.
  final String locale;

  /// Whether the voice works without a network connection.
  final bool offline;

  /// Whether the voice's language data is installed (only known once
  /// [AudioService.listVoices] has asked).
  final bool? installed;

  const TtsVoice({
    required this.name,
    required this.locale,
    required this.offline,
    this.installed,
  });

  /// Reads the result of flutter_tts's `getVoices`, skipping entries without
  /// a name or locale.
  static List<TtsVoice> fromPlugin(dynamic voices) {
    if (voices is! List) return [];
    return [
      for (final voice in voices.whereType<Map>())
        if (voice['name'] != null && voice['locale'] != null)
          TtsVoice(
            name: voice['name'].toString(),
            locale: voice['locale'].toString(),
            offline: voice['network_required']?.toString() == '0',
          ),
    ];
  }

  TtsVoice withInstalled(bool installed) => TtsVoice(
    name: name,
    locale: locale,
    offline: offline,
    installed: installed,
  );

  /// The two-letter language of the voice (`zh` for `cmn-TW`).
  String get language => languageOf(locale);

  /// The region of the voice (`tw` for `zh-TW`), lower case, or null.
  String? get region => regionOf(locale);

  /// Whether the voice belongs to [region] (lower case, such as `tw`), by its
  /// locale or, when the locale has no region, by its name
  /// (`cmn-tw-x-ctc-local`).
  bool isInRegion(String region) {
    final own = this.region;
    if (own != null) return own == region;
    return _subtags(name).skip(1).map(_regionAlias).contains(region);
  }

  static const _languageAliases = {
    'cmn': 'zh',
    'zho': 'zh',
    'chi': 'zh',
    'kor': 'ko',
    'jpn': 'ja',
    'eng': 'en',
    'spa': 'es',
    'fra': 'fr',
    'fre': 'fr',
    'deu': 'de',
    'ger': 'de',
  };

  static const _regionAliases = {
    'twn': 'tw',
    'chn': 'cn',
    'hkg': 'hk',
    'mac': 'mo',
    'kor': 'kr',
    'jpn': 'jp',
    'usa': 'us',
    'gbr': 'gb',
  };

  static List<String> _subtags(String tag) =>
      tag.toLowerCase().split(RegExp('[-_]'));

  static String _regionAlias(String subtag) => _regionAliases[subtag] ?? subtag;

  /// The two-letter language of a locale tag.
  static String languageOf(String tag) {
    final language = _subtags(tag).first;
    return _languageAliases[language] ?? language;
  }

  /// The region of a locale tag, lower case and two letters where known, or
  /// null when it has none. A four-letter subtag is a script, not a region.
  static String? regionOf(String tag) {
    for (final subtag in _subtags(tag).skip(1)) {
      if (subtag.length == 2 || subtag.length == 3) return _regionAlias(subtag);
    }
    return null;
  }
}

/// The voices of the device's current TTS engine.
class TtsVoiceList {
  /// The engine's package name, such as `com.samsung.SMT` or
  /// `com.google.android.tts`, when the platform reports it.
  final String? engine;
  final List<TtsVoice> voices;

  const TtsVoiceList(this.engine, this.voices);
}

/// Which voice spoke [text], or tried to.
class TtsVoiceUsed {
  /// The text as it was passed to `speak`, prefix included.
  final String text;

  /// The locale that was asked for (`zh-TW`), after the prefix and the
  /// lesson's language were resolved.
  final String requested;

  /// The voice that spoke, or null when no installed voice was found.
  final TtsVoice? voice;

  const TtsVoiceUsed({required this.text, required this.requested, this.voice});

  /// Whether the voice is of another region (or language) than [requested],
  /// so it may not sound as expected.
  bool get isSubstitute {
    final voice = this.voice;
    if (voice == null) return true;
    if (voice.language != TtsVoice.languageOf(requested)) return true;
    final region = TtsVoice.regionOf(requested);
    return region != null && !voice.isInRegion(region);
  }
}
