import 'dart:convert';

import 'package:bip39_mnemonic/bip39_mnemonic.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lingua_srs/services/sync_password_policy.dart';
import 'package:password_rules/password_rules.dart';

void main() {
  group('SyncPasswordPolicy', () {
    test('uses the package Unicode-aware minimum-length rule', () {
      const familyEmoji = '👨‍👩‍👧‍👦';
      final underMinimumPassword =
          String.fromCharCodes(List.generate(13, (index) => 97 + index)) +
          familyEmoji;
      final minimumPassword =
          String.fromCharCodes(List.generate(14, (index) => 97 + index)) +
          familyEmoji;

      expect(
        SyncPasswordPolicy.validateLocally(underMinimumPassword),
        contains('Use at least 15 characters.'),
      );
      expect(SyncPasswordPolicy.validateLocally(minimumPassword), isNull);
    });

    test('uses the package common-password rule', () {
      expect(
        SyncPasswordPolicy.rules.custom.single,
        isA<CommonPasswordsRule>(),
      );
    });

    test('enforces the package NIST preset 64-character maximum', () {
      expect(SyncPasswordPolicy.validateLocally('x' * 64), isNull);
      expect(
        SyncPasswordPolicy.validateLocally('x' * 65),
        contains('Use at most 64 characters.'),
      );
      expect(SyncPasswordPolicy.rules, const PasswordRules.nist());
    });

    test('creates a six-word passphrase that passes HIBP checks', () async {
      var checks = 0;
      final client = MockClient((_) async {
        checks++;
        return http.Response('', 200);
      });
      final passphrase = await SyncPasswordPolicy.generatePassphrase(
        client: client,
      );

      expect(passphrase.split(' '), hasLength(6));
      expect(SyncPasswordPolicy.validateLocally(passphrase), isNull);
      expect(checks, greaterThan(0));
    });

    test('accepts a six-word generated passphrase under the local policy', () {
      expect(
        SyncPasswordPolicy.validateLocally(
          'tongue glide bleak ancient chase orbit',
        ),
        isNull,
      );
    });

    test('every possible six-word passphrase fits the length limits', () {
      final lengths = Language.english.list.map((word) => word.length);
      final longest = lengths.reduce((a, b) => a > b ? a : b);
      final shortest = lengths.reduce((a, b) => a < b ? a : b);
      const words = SyncPasswordPolicy.passphraseWords;

      expect(words, 6);
      // The words plus the spaces between them.
      expect(longest * words + (words - 1), lessThanOrEqualTo(64));
      expect(shortest * words + (words - 1), greaterThanOrEqualTo(15));
    });

    test('sends only the first five SHA-1 characters to HIBP', () async {
      final password = await SyncPasswordPolicy.generatePassphrase(
        client: MockClient((_) async => http.Response('', 200)),
      );
      final digest = sha1
          .convert(utf8.encode(password))
          .toString()
          .toUpperCase();
      late http.Request request;
      final client = MockClient((seen) async {
        request = seen;
        return http.Response('${digest.substring(5)}:1\n', 200);
      });

      await expectLater(
        SyncPasswordPolicy.check(password: password, client: client),
        throwsA(
          isA<SyncPasswordPolicyException>().having(
            (error) => error.message,
            'message',
            contains('data breach'),
          ),
        ),
      );
      expect(request.url.path, '/range/${digest.substring(0, 5)}');
      expect(request.headers['Add-Padding'], 'true');
      expect(request.url.toString(), isNot(contains(password)));
    });

    test(
      'reports HIBP availability errors instead of skipping the check',
      () async {
        final client = MockClient(
          (_) async => http.Response('unavailable', 503),
        );

        await expectLater(
          SyncPasswordPolicy.check(
            password: 'tongue glide bleak ancient chase',
            client: client,
          ),
          throwsA(isA<SyncPasswordPolicyException>()),
        );
      },
    );
  });
}
