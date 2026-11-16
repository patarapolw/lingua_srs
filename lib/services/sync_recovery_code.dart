import 'dart:math';

/// A recovery code: a random secret that unlocks the account's data key
/// without the password (see "Recovery code" in `docs/sync.md`).
///
/// The secret is [secretLength] random bytes (160 bits), written in Crockford
/// base32 as 32 characters in groups of 4, such as `7K3M-…`. It is shown once,
/// when it is created, and is never stored, logged or sent anywhere: the
/// server only gets keys derived from it.
class SyncRecoveryCode {
  static const secretLength = 20;
  static const groupLength = 4;

  /// Crockford's base32 alphabet: digits and letters without I, L, O and U, so
  /// that nothing can be read as another character.
  static const _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  static const _characters = secretLength * 8 ~/ 5;

  /// A new random secret.
  static List<int> newSecret([Random? random]) {
    final source = random ?? Random.secure();
    return List<int>.generate(secretLength, (_) => source.nextInt(256));
  }

  /// [secret] as the code a person writes down: `XXXX-XXXX-…`.
  static String format(List<int> secret) {
    if (secret.length != secretLength) {
      throw ArgumentError.value(secret.length, 'secret', 'Wrong length');
    }
    final characters = StringBuffer();
    var buffer = 0;
    var bits = 0;
    for (final byte in secret) {
      buffer = (buffer << 8) | (byte & 0xff);
      bits += 8;
      while (bits >= 5) {
        bits -= 5;
        characters.write(_alphabet[(buffer >> bits) & 31]);
      }
      buffer &= (1 << bits) - 1;
    }
    final text = characters.toString();
    return [
      for (var i = 0; i < text.length; i += groupLength)
        text.substring(i, i + groupLength),
    ].join('-');
  }

  /// The secret in [code], as [format] wrote it or as a person typed it back:
  /// in any case, with or without spaces and hyphens, and with `O` for zero
  /// and `I` or `L` for one, as Crockford base32 allows. Throws
  /// [FormatException] for anything else. The message never repeats the code.
  static List<int> parse(String code) {
    final buffer = <int>[];
    for (final rune in code.toUpperCase().runes) {
      final character = String.fromCharCode(rune);
      if (character == '-' || character.trim().isEmpty) continue;
      final value = _alphabet.indexOf(switch (character) {
        'O' => '0',
        'I' || 'L' => '1',
        _ => character,
      });
      if (value < 0) {
        throw const FormatException(
          'A recovery code has only the digits 0 to 9 and the letters A to Z, '
          'without U.',
        );
      }
      buffer.add(value);
    }
    if (buffer.length != _characters) {
      throw const FormatException(
        'A recovery code has $_characters letters and digits.',
      );
    }
    final secret = <int>[];
    var bits = 0;
    var value = 0;
    for (final digit in buffer) {
      value = (value << 5) | digit;
      bits += 5;
      if (bits >= 8) {
        bits -= 8;
        secret.add((value >> bits) & 0xff);
        value &= (1 << bits) - 1;
      }
    }
    return secret;
  }
}
