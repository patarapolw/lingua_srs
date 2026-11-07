/// Text for text-to-speech, with an optional locale prefix that picks the
/// voice: `zh-TW:垃圾` is spoken as `垃圾` by a Taiwanese Mandarin voice.
///
/// The prefix is kept inside the stored `tts` text and only split off here,
/// when speaking. It is a locale (a 2–3 letter language, then optional script
/// or region subtags, such as `ko`, `zh-TW` or `zh-Hant-TW`), followed by `:`
/// with no space after it, at the very start of the text. A colon followed by
/// a space is always text, as is anything before a colon that does not look
/// like a locale (so `10:30` and `Note:` stay text).
class TtsText {
  /// The locale from the prefix, normalized (`zh-TW`), or null when there is
  /// no prefix.
  final String? locale;

  /// The text to speak, without the prefix.
  final String text;

  const TtsText(this.text, {this.locale});

  static final _prefix = RegExp(
    r'^([A-Za-z]{2,3}(?:[-_](?:[A-Za-z]{4}|[A-Za-z]{2}|[0-9]{3}))*):(?!\s)',
  );

  /// Splits a locale prefix off [raw]. Without one, the whole of [raw] is the
  /// text. A prefix with nothing after it is not a prefix.
  static TtsText parse(String raw) {
    final trimmed = raw.trim();
    final match = _prefix.firstMatch(trimmed);
    if (match == null) return TtsText(trimmed);
    final rest = trimmed.substring(match.end).trim();
    if (rest.isEmpty) return TtsText(trimmed);
    return TtsText(rest, locale: normalizeLocale(match[1]!));
  }

  /// Writes a locale in its usual case: `zh-tw` → `zh-TW`,
  /// `zh_hant` → `zh-Hant`.
  static String normalizeLocale(String locale) {
    final parts = locale.split(RegExp('[-_]'));
    return [
      parts.first.toLowerCase(),
      for (final part in parts.skip(1))
        if (part.length == 4)
          '${part[0].toUpperCase()}${part.substring(1).toLowerCase()}'
        else
          part.toUpperCase(),
    ].join('-');
  }
}
