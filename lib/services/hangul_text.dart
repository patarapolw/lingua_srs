/// Composes Korean text whose syllables are stored as separate jamo, as
/// macOS often stores file and folder names (Unicode NFD: `한` as
/// `ᄒ` + `ᅡ` + `ᆫ`), into whole syllables (NFC). The two look the same
/// but compare as different, so lesson names from a Mac folder or ZIP would
/// not match the same names typed or imported elsewhere.
///
/// Only conjoining Hangul jamo are composed, by the algorithm in the Unicode
/// Standard (section 3.12); all other text is returned as it is.
String composeHangul(String text) {
  if (!text.runes.any(_isJamo)) return text;
  final out = <int>[];
  for (final rune in text.runes) {
    final last = out.isEmpty ? -1 : out.last;
    final l = last - _lBase;
    final v = rune - _vBase;
    if (l >= 0 && l < _lCount && v >= 0 && v < _vCount) {
      out[out.length - 1] = _sBase + (l * _vCount + v) * _tCount;
      continue;
    }
    final s = last - _sBase;
    final t = rune - _tBase;
    if (s >= 0 && s < _sCount && s % _tCount == 0 && t > 0 && t < _tCount) {
      out[out.length - 1] = last + t;
      continue;
    }
    out.add(rune);
  }
  return String.fromCharCodes(out);
}

const _sBase = 0xAC00;
const _lBase = 0x1100;
const _vBase = 0x1161;
const _tBase = 0x11A7;
const _lCount = 19;
const _vCount = 21;
const _tCount = 28;
const _sCount = _lCount * _vCount * _tCount;

bool _isJamo(int rune) => rune >= 0x1100 && rune <= 0x11FF;
