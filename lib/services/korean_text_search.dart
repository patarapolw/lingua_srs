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

  static const _irregularConjugations = {
    '봤어요': '보',
    '봤다': '보',
    '봤습니다': '보',
    '봐요': '보',
    '봐서': '보',
    '봅니다': '보',
    '갔어요': '가',
    '갔다': '가',
    '갑니다': '가',
    '가요': '가',
    '왔어요': '오',
    '왔습니다': '오',
    '와요': '오',
    '와서': '오',
    '줬어요': '주',
    '줘요': '주',
    '줘서': '주',
    '됐어요': '되',
    '돼요': '되',
    '되어요': '되',
    '썼어요': '쓰',
    '써요': '쓰',
    '들었어요': '듣',
    '들어요': '듣',
    '걸어요': '걷',
  };

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
      tokens.addAll(_variants(word));
      tokens.addAll(_bigrams(word));
    }
    return tokens;
  }

  static Set<String> _variants(String word) {
    final variants = <String>{word};
    if (!_words(word).every((part) => part.runes.every(_isHangul))) {
      return variants;
    }

    if (word.endsWith('다') && word.runes.length > 1) {
      variants.add(word.substring(0, word.length - 1));
    }

    for (final conjugation in _irregularConjugations.entries) {
      if (word.endsWith(conjugation.key)) {
        variants.add(
          '${word.substring(0, word.length - conjugation.key.length)}'
          '${conjugation.value}',
        );
      }
    }

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
}
