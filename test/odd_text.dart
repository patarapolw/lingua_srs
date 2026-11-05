import 'dart:math';

/// Text made of random pieces of every awkward kind, so tests cover characters
/// nobody thought to write down. It is seeded, so a failing case can be
/// replayed from its seed.

/// Inclusive ranges of code points, none of them surrogates.
const _ranges = <(int, int)>[
  (0x21, 0x7e), // printable ASCII, including + & = % # ? / \ : @ ; ' "
  (0x00, 0x1f), // controls, including NUL, tab and newline
  (0x7f, 0x9f), // DEL and the C1 controls
  (0x20, 0x20), // space
  (0xa0, 0xa0), // no-break space
  (0x2000, 0x200a), // wide and thin spaces
  (0x3000, 0x3000), // ideographic space
  (0xa1, 0x24f), // accented Latin
  (0x300, 0x36f), // combining marks
  (0x370, 0x52f), // Greek and Cyrillic
  (0x5d0, 0x5ea), // Hebrew
  (0x627, 0x64a), // Arabic
  (0x3040, 0x309f), // kana
  (0x4e00, 0x4f00), // CJK
  (0xac00, 0xac50), // Hangul
  (0x200b, 0x200f), // zero-width and direction marks
  (0x202a, 0x202e), // direction overrides
  (0xfeff, 0xfeff), // byte order mark
  (0xe000, 0xe0ff), // private use
  (0xfff9, 0xffff), // specials and noncharacters
  (0x1d400, 0x1d7ff), // mathematical alphanumerics
  (0x1f300, 0x1f64f), // emoji
  (0x1f900, 0x1f9ff), // more emoji
];

/// One random character, which can be two UTF-16 units long. A text field
/// cannot hold a newline, so widget tests pass `newlines: false`.
String oddChar(Random random, {bool newlines = true}) {
  while (true) {
    final (low, high) = _ranges[random.nextInt(_ranges.length)];
    final codePoint = low + random.nextInt(high - low + 1);
    if (newlines || (codePoint != 0x0a && codePoint != 0x0d)) {
      return String.fromCharCode(codePoint);
    }
  }
}

String oddText(Random random, {int maxLength = 40, bool newlines = true}) {
  final buffer = StringBuffer();
  final length = 1 + random.nextInt(maxLength);
  for (var i = 0; i < length; i++) {
    buffer.write(oddChar(random, newlines: newlines));
  }
  return buffer.toString();
}

/// The code points of [text], for failure messages.
String hex(String text) =>
    text.runes.map((rune) => rune.toRadixString(16)).join(' ');
