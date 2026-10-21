import '../models/sentence.dart';

/// Revised Romanization and broad IPA for Korean, derived from how a word
/// sounds, not how it is spelled.
///
/// Pipeline: split into syllables -> apply sound changes between neighbouring
/// syllables -> render with a per-system table. Sound changes apply within a
/// run of Hangul only, never across spaces or punctuation.
class KoreanPronunciationService {
  KoreanPronunciationService._();

  static final RegExp _hangulRun = RegExp(r'[\uAC00-\uD7A3]+');

  static bool containsHangul(String text) => _hangulRun.hasMatch(text);

  static String romanize(String text) => _convert(text, _romanizeWord);

  /// Syllables are separated by '.'; add [ ] yourself when displaying.
  static String toIpa(String text) => _convert(text, _ipaWord);

  static String _convert(String text, String Function(List<_Syllable>) render) {
    final clean = Sentence.cleanForSpeech(text); // strips **bold**, cloze, etc.
    return clean.replaceAllMapped(_hangulRun, (m) => render(_phonemize(m[0]!)));
  }

  // ---------------------------------------------------------------- jamo

  static const List<String> _initials = [
    'ㄱ',
    'ㄲ',
    'ㄴ',
    'ㄷ',
    'ㄸ',
    'ㄹ',
    'ㅁ',
    'ㅂ',
    'ㅃ',
    'ㅅ',
    'ㅆ',
    'ㅇ',
    'ㅈ',
    'ㅉ',
    'ㅊ',
    'ㅋ',
    'ㅌ',
    'ㅍ',
    'ㅎ',
  ];
  static const List<String> _vowels = [
    'ㅏ',
    'ㅐ',
    'ㅑ',
    'ㅒ',
    'ㅓ',
    'ㅔ',
    'ㅕ',
    'ㅖ',
    'ㅗ',
    'ㅘ',
    'ㅙ',
    'ㅚ',
    'ㅛ',
    'ㅜ',
    'ㅝ',
    'ㅞ',
    'ㅟ',
    'ㅠ',
    'ㅡ',
    'ㅢ',
    'ㅣ',
  ];
  static const List<String> _finals = [
    '',
    'ㄱ',
    'ㄲ',
    'ㄳ',
    'ㄴ',
    'ㄵ',
    'ㄶ',
    'ㄷ',
    'ㄹ',
    'ㄺ',
    'ㄻ',
    'ㄼ',
    'ㄽ',
    'ㄾ',
    'ㄿ',
    'ㅀ',
    'ㅁ',
    'ㅂ',
    'ㅄ',
    'ㅅ',
    'ㅆ',
    'ㅇ',
    'ㅈ',
    'ㅊ',
    'ㅋ',
    'ㅌ',
    'ㅍ',
    'ㅎ',
  ];

  static _Syllable _decompose(int rune) {
    final code = rune - 0xAC00;
    return _Syllable(
      _initials[code ~/ 588],
      _vowels[(code % 588) ~/ 28],
      _finals[code % 28],
    );
  }

  // --------------------------------------------------------- sound rules

  /// Two-consonant finals as [first, second].
  static const Map<String, List<String>> _compoundFinal = {
    'ㄳ': ['ㄱ', 'ㅅ'],
    'ㄵ': ['ㄴ', 'ㅈ'],
    'ㄶ': ['ㄴ', 'ㅎ'],
    'ㄺ': ['ㄹ', 'ㄱ'],
    'ㄻ': ['ㄹ', 'ㅁ'],
    'ㄼ': ['ㄹ', 'ㅂ'],
    'ㄽ': ['ㄹ', 'ㅅ'],
    'ㄾ': ['ㄹ', 'ㅌ'],
    'ㄿ': ['ㄹ', 'ㅍ'],
    'ㅀ': ['ㄹ', 'ㅎ'],
    'ㅄ': ['ㅂ', 'ㅅ'],
  };

  /// What a two-consonant final sounds like before a consonant or at the end.
  static const Map<String, String> _doubleReduced = {
    'ㄳ': 'ㄱ',
    'ㄵ': 'ㄴ',
    'ㄶ': 'ㄴ',
    'ㄺ': 'ㄱ',
    'ㄻ': 'ㅁ',
    'ㄼ': 'ㄹ',
    'ㄽ': 'ㄹ',
    'ㄾ': 'ㄹ',
    'ㄿ': 'ㅂ',
    'ㅀ': 'ㄹ',
    'ㅄ': 'ㅂ',
  };

  /// Single finals collapse to seven sounds: ㄱ ㄴ ㄷ ㄹ ㅁ ㅂ ㅇ.
  static const Map<String, String> _singleReduced = {
    'ㄲ': 'ㄱ',
    'ㅋ': 'ㄱ',
    'ㅅ': 'ㄷ',
    'ㅆ': 'ㄷ',
    'ㅈ': 'ㄷ',
    'ㅊ': 'ㄷ',
    'ㅌ': 'ㄷ',
    'ㅎ': 'ㄷ',
    'ㅍ': 'ㅂ',
  };

  static const Map<String, String> _hAspirate = {'ㄱ': 'ㅋ', 'ㄷ': 'ㅌ', 'ㅈ': 'ㅊ'};
  static const Map<String, String> _toAspirated = {
    'ㄱ': 'ㅋ',
    'ㄷ': 'ㅌ',
    'ㅂ': 'ㅍ',
  };
  static const Map<String, String> _secondAspirated = {
    'ㄱ': 'ㅋ',
    'ㅈ': 'ㅊ',
    'ㅌ': 'ㅌ',
    'ㅍ': 'ㅍ',
  };
  static const Map<String, String> _nasalized = {'ㄱ': 'ㅇ', 'ㄷ': 'ㄴ', 'ㅂ': 'ㅁ'};
  static const Map<String, String> _tensed = {
    'ㄱ': 'ㄲ',
    'ㄷ': 'ㄸ',
    'ㅂ': 'ㅃ',
    'ㅅ': 'ㅆ',
    'ㅈ': 'ㅉ',
  };
  static const Set<String> _stops = {'ㄱ', 'ㄷ', 'ㅂ'};

  static String _neutralize(String coda, [String? nextOnset]) {
    if (coda.isEmpty) return coda;
    if (coda == 'ㄺ' && nextOnset == 'ㄱ') return 'ㄹ'; // 읽고 -> 일꼬
    return _doubleReduced[coda] ?? _singleReduced[coda] ?? coda;
  }

  static List<_Syllable> _phonemize(String run) {
    final syllables = run.runes.map(_decompose).toList();
    for (var i = 0; i + 1 < syllables.length; i++) {
      _applyBoundary(syllables[i], syllables[i + 1]);
    }
    for (final s in syllables) {
      s.coda = _neutralize(s.coda); // word-final codas
    }
    return syllables;
  }

  /// Vowel-initial next syllable: the final moves over (한국어 -> 한구거).
  static void _liaison(_Syllable a, _Syllable b) {
    final c = a.coda;
    if (c == 'ㅇ') return; // ng never moves (강아지)
    if (c == 'ㅎ') {
      a.coda = '';
      return; // silent (좋아요)
    }
    final parts = _compoundFinal[c];
    final String moved;
    if (parts == null) {
      moved = c;
      a.coda = '';
    } else if (parts[1] == 'ㅎ') {
      a.coda = parts[0]; // ㄶ ㅀ: the ㅎ is silent
      return;
    } else {
      a.coda = parts[0];
      if (parts[1] == 'ㅅ') {
        moved = 'ㅆ'; // 값이 -> 갑씨
        b.tensedByRule = true;
      } else {
        moved = parts[1];
      }
    }
    b.onset = moved;
    if (b.nucleus == 'ㅣ') {
      if (moved == 'ㄷ') b.onset = 'ㅈ'; // 굳이 -> 구지
      if (moved == 'ㅌ') b.onset = 'ㅊ'; // 같이 -> 가치
    }
  }

  static String _afterAspiration(String onset, _Syllable b) =>
      onset == 'ㅌ' && b.nucleus == 'ㅣ' ? 'ㅊ' : onset; // 닫히다 -> 다치다

  static void _applyBoundary(_Syllable a, _Syllable b) {
    if (a.coda.isEmpty) return;
    if (b.onset == 'ㅇ') {
      _liaison(a, b);
      return;
    }

    final parts = _compoundFinal[a.coda];

    // ㅎ in the final (ㅎ ㄶ ㅀ) before ㄱ ㄷ ㅈ aspirates; before ㅅ it tenses.
    if (a.coda == 'ㅎ' || (parts != null && parts[1] == 'ㅎ')) {
      final rest = a.coda == 'ㅎ' ? '' : parts![0];
      final aspirated = _hAspirate[b.onset];
      if (aspirated != null) {
        b.onset = aspirated; // 놓고 -> 노코
        a.coda = rest;
        return;
      }
      if (b.onset == 'ㅅ') {
        b.onset = 'ㅆ'; // 좋소 -> 조쏘
        b.tensedByRule = true;
        a.coda = rest;
        return;
      }
    }

    // ㅎ as the next onset aspirates the stop before it.
    if (b.onset == 'ㅎ') {
      if (parts != null && _secondAspirated.containsKey(parts[1])) {
        a.coda = parts[0]; // 앉히다 -> 안치다, 읽히다 -> 일키다
        b.onset = _afterAspiration(_secondAspirated[parts[1]]!, b);
        return;
      }
      final aspirated = _toAspirated[_neutralize(a.coda)];
      if (aspirated != null) {
        a.coda = ''; // 축하 -> 추카, 못하다 -> 모타다
        b.onset = _afterAspiration(aspirated, b);
        return;
      }
    }

    final coda = _neutralize(a.coda, b.onset);
    a.coda = coda;

    // Liquid assimilation and ㄹ -> ㄴ.
    if (b.onset == 'ㄹ') {
      if (coda == 'ㄴ') {
        a.coda = 'ㄹ'; // 신라 -> 실라
        return;
      }
      if (coda == 'ㄹ') return;
      b.onset = 'ㄴ'; // 종로 -> 종노, 국력 -> 궁녁
    }
    if (coda == 'ㄹ' && b.onset == 'ㄴ') {
      b.onset = 'ㄹ'; // 설날 -> 설랄
      return;
    }

    // Nasalisation: 국물 -> 궁물, 입니다 -> 임니다.
    if (b.onset == 'ㄴ' || b.onset == 'ㅁ') {
      a.coda = _nasalized[coda] ?? coda;
      return;
    }

    // Tensification after a stop: 학교 -> 학꾜.
    final tense = _tensed[b.onset];
    if (tense != null && _stops.contains(coda)) {
      b.onset = tense;
      b.tensedByRule = true;
    }
  }

  // ------------------------------------------- Revised Romanization output

  static const Map<String, String> _romanVowel = {
    'ㅏ': 'a',
    'ㅐ': 'ae',
    'ㅑ': 'ya',
    'ㅒ': 'yae',
    'ㅓ': 'eo',
    'ㅔ': 'e',
    'ㅕ': 'yeo',
    'ㅖ': 'ye',
    'ㅗ': 'o',
    'ㅘ': 'wa',
    'ㅙ': 'wae',
    'ㅚ': 'oe',
    'ㅛ': 'yo',
    'ㅜ': 'u',
    'ㅝ': 'wo',
    'ㅞ': 'we',
    'ㅟ': 'wi',
    'ㅠ': 'yu',
    'ㅡ': 'eu',
    'ㅢ': 'ui',
    'ㅣ': 'i',
  };
  static const Map<String, String> _romanOnset = {
    'ㄱ': 'g',
    'ㄲ': 'kk',
    'ㄴ': 'n',
    'ㄷ': 'd',
    'ㄸ': 'tt',
    'ㄹ': 'r',
    'ㅁ': 'm',
    'ㅂ': 'b',
    'ㅃ': 'pp',
    'ㅅ': 's',
    'ㅆ': 'ss',
    'ㅇ': '',
    'ㅈ': 'j',
    'ㅉ': 'jj',
    'ㅊ': 'ch',
    'ㅋ': 'k',
    'ㅌ': 't',
    'ㅍ': 'p',
    'ㅎ': 'h',
  };
  static const Map<String, String> _romanCoda = {
    '': '',
    'ㄱ': 'k',
    'ㄴ': 'n',
    'ㄷ': 't',
    'ㄹ': 'l',
    'ㅁ': 'm',
    'ㅂ': 'p',
    'ㅇ': 'ng',
  };

  /// RR does not write tensification that comes from a sound rule
  /// (학교 = hakgyo), only tense consonants that are spelled (까 = kka).
  static const Map<String, String> _romanUntensed = {
    'ㄲ': 'g',
    'ㄸ': 'd',
    'ㅃ': 'b',
    'ㅆ': 's',
    'ㅉ': 'j',
  };

  static String _romanizeWord(List<_Syllable> syllables) {
    final out = StringBuffer();
    for (var i = 0; i < syllables.length; i++) {
      final s = syllables[i];
      var onset =
          (s.tensedByRule ? _romanUntensed[s.onset] : null) ??
          _romanOnset[s.onset]!;
      if (s.onset == 'ㄹ' && i > 0 && syllables[i - 1].coda == 'ㄹ') {
        onset = 'l'; // 신라 -> silla
      }
      out
        ..write(onset)
        ..write(_romanVowel[s.nucleus]!)
        ..write(_romanCoda[s.coda]!);
    }
    return out.toString();
  }

  // ------------------------------------------------------------ IPA output

  static const String _tense = '\u0348'; // combining double vertical line below
  static const String _tie = '\u0361'; // combining double inverted breve
  static const String _unreleased = '\u031A'; // combining left angle above

  static const Map<String, String> _ipaVowel = {
    'ㅏ': 'a',
    'ㅐ': 'ɛ',
    'ㅑ': 'ja',
    'ㅒ': 'jɛ',
    'ㅓ': 'ʌ',
    'ㅔ': 'e',
    'ㅕ': 'jʌ',
    'ㅖ': 'je',
    'ㅗ': 'o',
    'ㅘ': 'wa',
    'ㅙ': 'wɛ',
    'ㅚ': 'we',
    'ㅛ': 'jo',
    'ㅜ': 'u',
    'ㅝ': 'wʌ',
    'ㅞ': 'we',
    'ㅟ': 'wi',
    'ㅠ': 'ju',
    'ㅡ': 'ɯ',
    'ㅢ': 'ɰi',
    'ㅣ': 'i',
  };
  static const Map<String, String> _ipaOnset = {
    'ㄱ': 'k',
    'ㄲ': 'k$_tense',
    'ㄴ': 'n',
    'ㄷ': 't',
    'ㄸ': 't$_tense',
    'ㄹ': 'ɾ',
    'ㅁ': 'm',
    'ㅂ': 'p',
    'ㅃ': 'p$_tense',
    'ㅅ': 's',
    'ㅆ': 's$_tense',
    'ㅇ': '',
    'ㅈ': 't$_tieɕ',
    'ㅉ': 't$_tieɕ$_tense',
    'ㅊ': 't$_tieɕʰ',
    'ㅋ': 'kʰ',
    'ㅌ': 'tʰ',
    'ㅍ': 'pʰ',
    'ㅎ': 'h',
  };

  /// Lenis stops are voiced between voiced sounds. ɡ below is U+0261.
  static const Map<String, String> _ipaVoiced = {
    'ㄱ': 'ɡ',
    'ㄷ': 'd',
    'ㅂ': 'b',
    'ㅈ': 'd$_tieʑ',
  };
  static const Map<String, String> _ipaCoda = {
    '': '',
    'ㄱ': 'k$_unreleased',
    'ㄴ': 'n',
    'ㄷ': 't$_unreleased',
    'ㄹ': 'l',
    'ㅁ': 'm',
    'ㅂ': 'p$_unreleased',
    'ㅇ': 'ŋ',
  };
  static const Set<String> _sonorants = {'ㄴ', 'ㄹ', 'ㅁ', 'ㅇ'};

  /// ㅅ is [ɕ] before ㅣ and the y/w-glide vowels.
  static const Set<String> _palatalGlide = {
    'ㅣ',
    'ㅑ',
    'ㅒ',
    'ㅕ',
    'ㅖ',
    'ㅛ',
    'ㅠ',
    'ㅟ',
  };

  static String _ipaWord(List<_Syllable> syllables) {
    final out = <String>[];
    for (var i = 0; i < syllables.length; i++) {
      final s = syllables[i];
      final prevCoda = i > 0 ? syllables[i - 1].coda : null;
      final voiced =
          prevCoda != null &&
          (prevCoda.isEmpty || _sonorants.contains(prevCoda));
      final String onset;
      if (s.onset == 'ㄹ') {
        onset = prevCoda == 'ㄹ' ? 'l' : 'ɾ';
      } else if (s.onset == 'ㅅ' && _palatalGlide.contains(s.nucleus)) {
        onset = 'ɕ';
      } else if (s.onset == 'ㅆ' && _palatalGlide.contains(s.nucleus)) {
        onset = 'ɕ$_tense';
      } else if (voiced && _ipaVoiced.containsKey(s.onset)) {
        onset = _ipaVoiced[s.onset]!;
      } else {
        onset = _ipaOnset[s.onset]!;
      }
      out.add('$onset${_ipaVowel[s.nucleus]!}${_ipaCoda[s.coda]!}');
    }
    return out.join('.');
  }
}

class _Syllable {
  _Syllable(this.onset, this.nucleus, this.coda);

  String onset; // one of the 19 initials; 'ㅇ' means silent
  String nucleus;
  String coda; // '' or a final jamo, possibly a two-consonant one

  /// True when a sound rule (not the spelling) made the onset tense, so
  /// Revised Romanization should write the plain letter.
  bool tensedByRule = false;
}
