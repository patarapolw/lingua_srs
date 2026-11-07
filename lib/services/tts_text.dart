import 'locale_names.dart';

/// Text for text-to-speech, with an optional locale prefix that picks the
/// voice: `zh-TW:垃圾` is spoken as `垃圾` by a Taiwanese Mandarin voice.
///
/// The prefix is kept inside the stored `tts` text and only split off here,
/// when speaking. It is a locale (a 2–3 letter language, then optional script
/// or region subtags, such as `ko`, `zh-TW` or `zh-Hant-TW`), followed by `:`
/// with no whitespace after it, with no text in front of it. Anything else is
/// text: a colon followed by a space (`ko: 세 개`), a prefix after other text,
/// or anything before a colon that does not look like a locale (`10:30`,
/// `Note:`).
///
/// A prefix with nothing after it (`zh-TW:`) speaks the word or sentence
/// itself in that locale. A prefix whose language is not a known one (`xx:`)
/// is ignored: the rest is spoken in the usual language.
class TtsText {
  /// The locale from the prefix, normalized (`zh-TW`), or null when there is
  /// no prefix or its language is not known.
  final String? locale;

  /// The text to speak, without the prefix. Empty for a prefix alone.
  final String text;

  const TtsText(this.text, {this.locale});

  static final _prefix = RegExp(
    r'^([A-Za-z]{2,3}(?:[-_](?:[A-Za-z]{4}|[A-Za-z]{2}|[0-9]{3}))*):(?!\s)',
  );

  /// Splits a locale prefix off [raw]. Without one, the whole of [raw] is the
  /// text.
  static TtsText parse(String raw) {
    final trimmed = raw.trim();
    final match = _prefix.firstMatch(trimmed);
    if (match == null) return TtsText(trimmed);
    final rest = trimmed.substring(match.end).trim();
    final locale = normalizeLocale(match[1]!);
    return TtsText(
      rest,
      locale: LocaleNames.isLanguage(locale.split('-').first) ? locale : null,
    );
  }

  /// What to speak for the TTS text [raw] of a word or sentence whose own
  /// text is [fallback]: [fallback] when [raw] is blank, and [fallback] in
  /// the prefix's locale when [raw] is a prefix alone (`zh-TW:` →
  /// `zh-TW:垃圾`). An unknown prefix is dropped.
  static String speechOf(String? raw, String fallback) {
    if (raw == null || raw.trim().isEmpty) return fallback;
    final tts = parse(raw);
    final text = tts.text.isEmpty ? fallback.trim() : tts.text;
    return tts.locale == null ? text : '${tts.locale}:$text';
  }

  /// The TTS text [raw] as it is saved: trimmed, or null when blank. A
  /// prefix alone (`zh-TW:`) is kept.
  static String? clean(String? raw) {
    final trimmed = raw?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  /// [raw] with its locale prefix set to [locale]: an existing prefix is
  /// replaced, otherwise one is added (`垃圾` → `zh-TW:垃圾`). A null
  /// [locale] removes the prefix.
  static String withLocale(String raw, String? locale) {
    final trimmed = raw.trim();
    final match = _prefix.firstMatch(trimmed);
    final rest = match == null ? trimmed : trimmed.substring(match.end);
    return locale == null ? rest : '$locale:$rest';
  }

  /// The locale of [raw]'s prefix, normalized (`zh-tw:` → `zh-TW`), whether
  /// or not text follows it, or null without a prefix of a known language.
  static String? prefixOf(String raw) => parse(raw).locale;

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
