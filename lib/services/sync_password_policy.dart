import 'dart:convert';
import 'dart:math';

import 'package:bip39_mnemonic/bip39_mnemonic.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:password_rules/password_rules.dart';

class SyncPasswordPolicyException implements Exception {
  final String message;

  const SyncPasswordPolicyException(this.message);

  @override
  String toString() => message;
}

class SyncPasswordPolicy {
  static const rules = PasswordRules.nist();
  static const _timeout = Duration(seconds: 10);
  static const _maxPassphraseAttempts = 10;

  /// Six words from a 2048-word list are about 66 bits, which is out of reach
  /// of an offline attack on a stolen key-derivation hash. Even the longest
  /// six words stay inside the preset's 64 character limit.
  static const passphraseWords = 6;

  static Future<String> generatePassphrase({http.Client? client}) async {
    final random = Random.secure();
    final words = Language.english.list;
    final ownsClient = client == null;
    final httpClient = client ?? http.Client();
    try {
      for (var attempt = 0; attempt < _maxPassphraseAttempts; attempt++) {
        final passphrase = List.generate(
          passphraseWords,
          (_) => words[random.nextInt(words.length)],
        ).join(' ');
        if (validateLocally(passphrase) != null) continue;
        if (!await _isBreached(passphrase, httpClient)) return passphrase;
      }
      throw const SyncPasswordPolicyException(
        'Could not generate an unchecked passphrase. Try again.',
      );
    } finally {
      if (ownsClient) httpClient.close();
    }
  }

  static String? validateLocally(String password) {
    final failed = rules.validate(password).failed;
    if (failed.isEmpty) return null;
    return failed
        .map((rule) {
          if (rule is MinLengthRule) {
            return 'Use at least ${rule.count} characters.';
          }
          if (rule is MaxLengthRule) {
            return 'Use at most ${rule.count} characters.';
          }
          if (rule is CommonPasswordsRule) {
            return 'Choose a password that is not one of the most common passwords.';
          }
          return 'Password does not meet the requirements.';
        })
        .join(' ');
  }

  static Future<void> check({
    required String password,
    http.Client? client,
  }) async {
    final localError = validateLocally(password);
    if (localError != null) throw SyncPasswordPolicyException(localError);

    final ownsClient = client == null;
    final httpClient = client ?? http.Client();
    try {
      if (await _isBreached(password, httpClient)) {
        throw const SyncPasswordPolicyException(
          'This password appears in a data breach. Choose another.',
        );
      }
    } on SyncPasswordPolicyException {
      rethrow;
    } finally {
      if (ownsClient) httpClient.close();
    }
  }

  static Future<bool> _isBreached(String password, http.Client client) async {
    final digest = sha1.convert(utf8.encode(password)).toString().toUpperCase();
    final prefix = digest.substring(0, 5);
    final suffix = digest.substring(5);
    try {
      final response = await client
          .get(
            Uri.https('api.pwnedpasswords.com', '/range/$prefix'),
            headers: const {'Add-Padding': 'true'},
          )
          .timeout(_timeout);
      if (response.statusCode != 200) {
        throw const SyncPasswordPolicyException(
          'Could not check the password against the breached-password list.',
        );
      }
      for (final line in const LineSplitter().convert(response.body)) {
        final separator = line.indexOf(':');
        if (separator <= 0) continue;
        if (line.substring(0, separator).trim().toUpperCase() == suffix) {
          final count = int.tryParse(line.substring(separator + 1).trim());
          if (count != null && count > 0) return true;
        }
      }
      return false;
    } on SyncPasswordPolicyException {
      rethrow;
    } catch (error) {
      throw SyncPasswordPolicyException(
        'Could not check the password against the breached-password list: '
        '$error',
      );
    }
  }
}
