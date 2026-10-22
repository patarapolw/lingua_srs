class KoreanTextSearch {
  static const _particles = [
    '으로부터',
    '으로써',
    '으로서',
    '에게서',
    '한테서',
    '으로',
    '에서',
    '에게',
    '한테',
    '부터',
    '까지',
    '처럼',
    '보다',
    '마다',
    '조차',
    '마저',
    '은',
    '는',
    '이',
    '가',
    '을',
    '를',
    '에',
    '와',
    '과',
    '도',
    '만',
    '의',
    '로',
    '랑',
    '께',
  ];

  static const _haConjugations = [
    '했습니다',
    '하였습니다',
    '하겠습니다',
    '했어요',
    '했었어요',
    '했었다',
    '했어',
    '했다',
    '했죠',
    '해요',
    '하는',
    '하면',
    '하고',
    '해서',
    '하여',
    '하며',
    '할',
    '한',
    '해',
    '합니다',
    '합니까',
  ];

  // Suffixes are not tried bare.
  // A bare form like 내 would otherwise yield 넣, and 넣다 would match any sentence containing 내.
  // The bare 해체 forms (추워, 도와) are therefore not covered.
  // Known gaps: ㅅ irregulars (낫다 → 나아요) and adjective forms like 추운 aren’t covered.
  static const _irregularSuffixes = [
    '았습니다',
    '었습니다',
    '습니다',
    '았어요',
    '었어요',
    '어요',
    '아요',
    '으세요',
    '세요',
    '았다',
    '었다',
    '다',
    '어서',
    '아서',
    '서',
    '으면',
    '으니',
    '요',
  ];

  static const _endings = [
    '었습니다',
    '았었습니다',
    '었었습니다',
    '았습니다',
    '었어요',
    '았어요',
    '였습니다',
    '이었다',
    '았다',
    '었다',
    '었고',
    '았고',
    '어서',
    '아서',
    '어요',
    '아요',
    '습니다',
    '습니까',
    '세요',
    '으면',
    '으니',
    '으면서',
    '면서',
    '는다',
    'ㄴ다',
    '고',
  ];

  static bool matches({
    required String query,
    required String targetText,
    required String translationText,
  }) {
    final normalizedQuery = _normalize(query);
    if (normalizedQuery.isEmpty) return true;

    final target = _normalize(targetText);
    final translation = _normalize(translationText);
    if (target.contains(normalizedQuery) ||
        translation.contains(normalizedQuery)) {
      return true;
    }

    final queryWords = _words(normalizedQuery);
    if (queryWords.isEmpty) return false;
    final document = _tokens('$target $translation');
    return queryWords.every((word) {
      final variants = _variants(word);
      if (variants.any(document.contains)) return true;

      final queryBigrams = _bigrams(word);
      if (queryBigrams.isEmpty) return false;
      final sharedBigrams = queryBigrams.where(document.contains).length;
      return sharedBigrams >= (queryBigrams.length + 1) ~/ 2;
    });
  }

  static Set<String> tokenize(String text) => _tokens(_normalize(text));

  /// True if [a] and [b] look like forms of the same Korean word: identical, or
  /// sharing a stem once endings, particles and irregular conjugation are
  /// removed. A one-syllable stem only counts as the dictionary stem of one of
  /// them (크 from 크다), which keeps 아이/아 and 배/배우다 apart.
  static bool areVariants(String a, String b) {
    final wordsA = _words(_normalize(a));
    final wordsB = _words(_normalize(b));
    if (wordsA.isEmpty || wordsA.length != wordsB.length) return false;
    for (var i = 0; i < wordsA.length; i++) {
      final x = wordsA[i], y = wordsB[i];
      if (x != y && !_stemOverlap(x, y) && !_stemOverlap(y, x)) return false;
    }
    return true;
  }

  // The query side never expands irregular stems (it over-generates).
  static bool _stemOverlap(String query, String document) {
    final q = _variants(query);
    final d = _variants(document, expandIrregular: true);
    return q
        .intersection(d)
        .any((s) => s.runes.length >= 2 || query == '$s다' || document == '$s다');
  }

  static String _normalize(String text) {
    return text
        .replaceAll(RegExp(r'<[^>]*>'), ' ')
        .replaceAll(RegExp(r'[*_`~]'), '')
        .toLowerCase()
        .trim();
  }

  static List<String> _words(String text) {
    final words = <String>[];
    final current = StringBuffer();
    var currentIsHangul = false;

    void flush() {
      if (current.isEmpty) return;
      words.add(current.toString());
      current.clear();
    }

    for (final rune in text.runes) {
      final isHangul = _isHangul(rune);
      final isAsciiWord =
          (rune >= 0x30 && rune <= 0x39) ||
          (rune >= 0x61 && rune <= 0x7a) ||
          (rune >= 0x41 && rune <= 0x5a);
      if (!isHangul && !isAsciiWord) {
        flush();
        continue;
      }
      if (current.isNotEmpty && currentIsHangul != isHangul) flush();
      currentIsHangul = isHangul;
      current.writeCharCode(rune);
    }
    flush();
    return words;
  }

  static bool _isHangul(int rune) =>
      (rune >= 0xac00 && rune <= 0xd7a3) ||
      (rune >= 0x1100 && rune <= 0x11ff) ||
      (rune >= 0x3130 && rune <= 0x318f);

  static Set<String> _tokens(String text) {
    final tokens = <String>{};
    for (final word in _words(text)) {
      tokens.addAll(_variants(word, expandIrregular: true));
      tokens.addAll(_bigrams(word));
    }
    return tokens;
  }

  static Set<String> _variants(String word, {bool expandIrregular = false}) {
    final variants = <String>{word};
    if (!_words(word).every((part) => part.runes.every(_isHangul))) {
      return variants;
    }

    if (word.endsWith('다') && word.runes.length > 1) {
      variants.add(word.substring(0, word.length - 1));
    }

    if (expandIrregular) variants.addAll(_irregularStems(word));

    for (final ending in _haConjugations) {
      if (word.endsWith(ending) && word.length >= ending.length) {
        variants.add('${word.substring(0, word.length - ending.length)}하');
      }
    }

    for (final ending in _endings) {
      if (word.endsWith(ending) && word.length > ending.length) {
        variants.add(word.substring(0, word.length - ending.length));
      }
    }

    for (final particle in _particles) {
      if (word.endsWith(particle) && word.length > particle.length) {
        variants.add(word.substring(0, word.length - particle.length));
      }
    }

    return variants.where((variant) => variant.isNotEmpty).toSet();
  }

  static Set<String> _bigrams(String word) {
    final runes = word.runes.toList(growable: false);
    if (runes.length < 2 || !runes.every(_isHangul)) return const {};
    return {
      for (var index = 0; index < runes.length - 1; index++)
        String.fromCharCodes(runes.skip(index).take(2)),
    };
  }

  // Jamo indices used by _irregularStems
  static const _jongSsang = 20; // ㅆ final

  static List<int>? _decompose(String ch) {
    final r = ch.runes.first;
    if (r < 0xac00 || r > 0xd7a3) return null;
    final code = r - 0xac00;
    return [code ~/ 588, (code % 588) ~/ 28, code % 28];
  }

  static String _compose(int initial, int medial, int tail) =>
      String.fromCharCode(0xac00 + initial * 588 + medial * 28 + tail);

  /// Restores dictionary stems of irregular verbs (ㄷ, ㅂ, 르, 으, ㅎ and
  /// vowel contractions) from conjugated words. Over-generates on purpose;
  /// only use for document tokens, never for the query.
  static Set<String> _irregularStems(String word) {
    final stems = <String>{};
    // ㅂ irregular attributive: 추운→춥, 아름다운→아름답
    if (word.endsWith('운') && word.runes.length > 1) {
      final head = word.substring(0, word.length - 1);
      final last = _decompose(head.substring(head.length - 1));
      if (last != null && last[2] == 0) {
        stems.add(
          '${head.substring(0, head.length - 1)}${_compose(last[0], last[1], 17)}',
        );
      }
    }

    for (final suffix in _irregularSuffixes) {
      if (!word.endsWith(suffix) || word.length <= suffix.length) continue;
      final head = word.substring(0, word.length - suffix.length);
      final last = _decompose(head.substring(head.length - 1));
      if (last == null) continue;
      final initial = last[0], medial = last[1];
      var tail = last[2];
      if (suffix == '다' && tail != _jongSsang) continue;
      final droppedSsang = tail == _jongSsang;
      if (droppedSsang) tail = 0; // 갔→가, 추웠→추워, 봤→봐

      final pre = head.substring(0, head.length - 1);
      final prev = pre.isEmpty
          ? null
          : _decompose(pre.substring(pre.length - 1));
      final preOfPre = pre.isEmpty ? '' : pre.substring(0, pre.length - 1);

      if (droppedSsang) stems.add('$pre${_compose(initial, medial, tail)}');
      // ㄷ irregular: 들→듣, 걸→걷
      if (tail == 8) stems.add('$pre${_compose(initial, medial, 7)}');
      // ㅂ irregular: 추워→춥, 도와→돕
      if (initial == 11 &&
          tail == 0 &&
          (medial == 9 || medial == 14) &&
          prev != null &&
          prev[2] == 0) {
        stems.add('$preOfPre${_compose(prev[0], prev[1], 17)}');
      }
      // 르 irregular: 몰라→모르
      if (initial == 5 &&
          tail == 0 &&
          (medial == 0 || medial == 4) &&
          prev != null &&
          prev[2] == 8) {
        stems.add(
          '$preOfPre${_compose(prev[0], prev[1], 0)}${_compose(5, 18, 0)}',
        );
      }
      // 으 drop: 써→쓰, 아파→아프
      if (initial != 11 && tail == 0 && (medial == 0 || medial == 4)) {
        stems.add('$pre${_compose(initial, 18, 0)}');
      }
      // ㅎ irregular: 그래→그렇
      if (tail == 0 && medial == 1) {
        stems.add('$pre${_compose(initial, 4, 27)}');
      }
      if (tail == 0 && medial == 3) {
        stems.add('$pre${_compose(initial, 2, 27)}');
      }
      // vowel contraction: 봐→보, 줘→주, 돼→되, 마셔→마시
      if (tail == 0) {
        const contractions = {9: 8, 14: 13, 10: 11, 6: 20};
        final m = contractions[medial];
        if (m != null) stems.add('$pre${_compose(initial, m, 0)}');
      }
    }
    return stems;
  }
}
