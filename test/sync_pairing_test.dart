import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/services/sync_pairing.dart';

import 'odd_text.dart';

const _email = 'reader@example.com';
const _password = 'correct horse battery staple';
final _server = Uri.parse('https://sync.example.com');

/// An email of random awkward characters, apart from the few the format rules
/// out (whitespace, `@` and `:`). It is put in NFKC first, because that turns
/// some characters into spaces (for example the Greek tonos), which are then
/// ruled out too.
final _usable = RegExp(r'^[^\s@:]+@[^\s@:]+\.[^\s@:]+$');

String _oddEmail(Random random) {
  final local = SyncPairing.normalizeEmail(
    oddText(random),
  ).replaceAll(RegExp(r'[\s@:]'), 'x');
  final label = SyncPairing.normalizeEmail(
    oddText(random, maxLength: 8),
  ).replaceAll(RegExp(r'[\s@:.]'), 'x');
  return '$local@$label.example';
}

String _link({
  String? endpoint,
  String? email = _email,
  String? password = _password,
  String host = 'sync',
}) => Uri(
  scheme: 'linguasrs',
  host: host,
  queryParameters: {
    'endpoint': ?endpoint,
    'email': ?email,
    'password': ?password,
  },
).toString();

void main() {
  setUp(() => SyncPairing.defaultEndpoint = _server);
  tearDown(() => SyncPairing.defaultEndpoint = null);

  group('SyncPairing', () {
    test('uses the built-in server and leaves it out of the link', () {
      final pairing = SyncPairing(email: _email, password: _password);

      expect(pairing.endpoint, _server);
      expect(pairing.link, startsWith('linguasrs://sync?'));
      expect(pairing.link, isNot(contains('endpoint')));
      expect(SyncPairing.parse(pairing.link), pairing);
    });

    test('a link to another server keeps that server', () {
      final pairing = SyncPairing(
        endpoint: Uri.parse('http://localhost:8787'),
        email: _email,
        password: _password,
      );

      expect(pairing.link, contains('endpoint='));
      expect(SyncPairing.parse(pairing.link), pairing);
    });

    test('keeps a path prefix and drops trailing slashes', () {
      final pairing = SyncPairing.parse(
        _link(endpoint: 'https://example.com/sync/'),
      );

      expect(pairing.endpoint.toString(), 'https://example.com/sync');
      expect(SyncPairing.parse(pairing.link), pairing);
    });

    test('the email is trimmed and lowercased', () {
      final pairing = SyncPairing(
        email: '  Reader@Example.COM\n',
        password: _password,
      );

      expect(pairing.email, 'reader@example.com');
    });

    test('the password is kept exactly as typed', () {
      const password = ' spaced value+&=é! ';
      final pairing = SyncPairing(email: _email, password: password);

      expect(pairing.password, password);
      expect(SyncPairing.parse(pairing.link).password, password);
    });

    test('there is no maximum password length', () {
      final password = 'long passphrase ' * 100;

      expect(SyncPairing(email: _email, password: password).password, password);
    });

    test('sign-in accepts a short password from an older policy', () {
      expect(SyncPairing(email: _email, password: 'old1').password, 'old1');
    });

    test('parses a link pasted with surrounding whitespace', () {
      final pairing = SyncPairing.parse('  ${_link()}\n');

      expect(pairing.email, _email);
      expect(pairing.password, _password);
    });

    test('allows plain http only for a local Worker', () {
      expect(
        SyncPairing.parse(_link(endpoint: 'http://localhost:8787')).endpoint,
        Uri.parse('http://localhost:8787'),
      );
      expect(
        () => SyncPairing.parse(_link(endpoint: 'http://example.com')),
        throwsFormatException,
      );
    });

    test('rejects links that are not LinguaSRS sync links', () {
      expect(() => SyncPairing.parse(''), throwsFormatException);
      expect(
        () => SyncPairing.parse('https://example.com'),
        throwsFormatException,
      );
      expect(
        () => SyncPairing.parse(_link(host: 'import')),
        throwsFormatException,
      );
    });

    test('rejects an unusable email, password or server', () {
      for (final email in [null, '', 'reader', 'a@b', 'a b@example.com']) {
        expect(
          () => SyncPairing.parse(_link(email: email)),
          throwsFormatException,
          reason: 'email: $email',
        );
      }
      expect(
        () => SyncPairing.parse(_link(password: null)),
        throwsFormatException,
      );
      expect(
        () => SyncPairing.parse(_link(password: '   ')),
        throwsFormatException,
      );
      expect(
        () => SyncPairing.parse(_link(endpoint: 'ftp://example.com')),
        throwsFormatException,
      );
      expect(
        () => SyncPairing.parse(_link(endpoint: 'https://example.com?a=b')),
        throwsFormatException,
      );
    });

    test('a build without a sync server cannot sign in', () {
      SyncPairing.defaultEndpoint = null;

      expect(
        () => SyncPairing(email: _email, password: _password),
        throwsFormatException,
      );
      expect(
        SyncPairing.parse(_link(endpoint: 'http://localhost:8787')).email,
        _email,
      );
    });

    test('a password of any characters is kept exactly as typed', () {
      var blank = 0;
      for (var seed = 0; seed < 300; seed++) {
        final password = oddText(Random(seed));
        final reason = 'seed $seed, code points ${hex(password)}';

        if (password.trim().isEmpty) {
          blank++;
          expect(
            () => SyncPairing(email: _email, password: password),
            throwsFormatException,
            reason: reason,
          );
          continue;
        }
        final pairing = SyncPairing(email: _email, password: password);
        expect(pairing.password, password, reason: reason);
        final parsed = SyncPairing.parse(pairing.link);
        expect(parsed.password, password, reason: reason);
        expect(parsed, pairing, reason: reason);
        // Safe to put in a QR code, the clipboard and secure storage.
        expect(
          pairing.link.codeUnits.every((unit) => unit < 128),
          isTrue,
          reason: reason,
        );
      }
      expect(blank, lessThan(30), reason: 'the generator is mostly blank');
    });

    test('spaces and other whitespace around a password are kept', () {
      const padding = [' ', '\t', '\u00a0', '\u3000', '\n', '\r\n'];
      for (var seed = 0; seed < 100; seed++) {
        final random = Random(seed);
        final core = oddText(random, maxLength: 10);
        if (core.trim().isEmpty) continue;
        final password =
            padding[random.nextInt(padding.length)] +
            core +
            padding[random.nextInt(padding.length)];
        final reason = 'seed $seed, code points ${hex(password)}';

        final pairing = SyncPairing(email: _email, password: password);

        expect(pairing.password, password, reason: reason);
        expect(SyncPairing.parse(pairing.link).password, password);
      }
    });

    test('an email of any characters is normalized, once and for all', () {
      var rejected = 0;
      for (var seed = 0; seed < 300; seed++) {
        final email = _oddEmail(Random(seed));
        final typed = ' $email\t';
        final expected = SyncPairing.normalizeEmail(typed);
        final reason = 'seed $seed, code points ${hex(typed)}';

        // The pattern is the one the app uses: a name, an @ and a domain with
        // a dot, none of them holding whitespace, @ or a colon. Trimming can
        // remove more than the generator expects (for example a name made of
        // only U+0085), so what is accepted is decided by the normalized text.
        if (!_usable.hasMatch(expected)) {
          rejected++;
          expect(
            () => SyncPairing(email: typed, password: _password),
            throwsFormatException,
            reason: reason,
          );
          continue;
        }
        final pairing = SyncPairing(email: typed, password: _password);
        expect(pairing.email, expected, reason: reason);
        expect(
          SyncPairing.normalizeEmail(pairing.email),
          pairing.email,
          reason: 'normalizing twice changes it, $reason',
        );
        expect(SyncPairing.parse(pairing.link), pairing, reason: reason);
      }
      expect(rejected, lessThan(30));
    });

    test('a password that starts with a byte order mark is kept', () {
      for (final password in ['\ufeffsecret', '\ufeff\ufeffa b']) {
        final pairing = SyncPairing(email: _email, password: password);

        expect(
          SyncPairing.parse(pairing.link).password,
          password,
          reason: hex(password),
        );
      }
    });

    test('a link written by hand reads encoded and plain characters', () {
      final parsed = SyncPairing.parse(
        'linguasrs://sync?email=reader%40example.com'
        '&password=%EF%BB%BFa+b%20%F0%9F%8E%8E%25&endpoint=https://sync.example.com',
      );

      expect(parsed.email, 'reader@example.com');
      expect(parsed.password, '\ufeffa b \u{1F38E}%');
      expect(parsed.endpoint, Uri.parse(_server.toString()));
    });

    test('equivalent spellings of an email are the same account', () {
      // An accent as one character or as a letter and a combining mark, and
      // full-width letters, which different keyboards and platforms produce.
      final spellings = [
        'caf\u00e9@example.com',
        'cafe\u0301@example.com',
        'CAFE\u0301@Example.COM',
        '\uff43\uff41\uff46\u00e9@example.com',
        ' caf\u00e9@example.com\n',
      ];

      final emails = {
        for (final spelling in spellings)
          SyncPairing(email: spelling, password: _password).email,
      };

      expect(emails, {'caf\u00e9@example.com'});
    });

    test('half of a surrogate pair cannot be kept, so it is refused', () {
      final high = String.fromCharCode(0xD83D);
      final low = String.fromCharCode(0xDE00);
      for (final bad in ['a${high}b', 'a${low}b', 'a$low${high}b', high, low]) {
        expect(
          () => SyncPairing(email: _email, password: bad),
          throwsFormatException,
          reason: 'password ${hex(bad)}',
        );
        expect(
          () => SyncPairing(email: '$bad@example.com', password: _password),
          throwsFormatException,
          reason: 'email ${hex(bad)}',
        );
      }

      // Both halves together are one character (an emoji) and are fine.
      final emoji = 'a$high${low}b';
      expect(SyncPairing(email: _email, password: emoji).password, emoji);
      expect(
        SyncPairing.parse(
          SyncPairing(email: _email, password: emoji).link,
        ).password,
        emoji,
      );
    });

    test('normalizeServer checks and tidies a server address', () {
      expect(
        SyncPairing.normalizeServer(Uri.parse('https://example.com/sync/')),
        Uri.parse('https://example.com/sync'),
      );
      expect(
        SyncPairing.normalizeServer(Uri.parse('http://localhost:8787')),
        Uri.parse('http://localhost:8787'),
      );
      for (final bad in [
        'http://example.com',
        'ftp://example.com',
        'https://example.com?a=b',
        'https://user:pw@example.com',
        'example.com',
      ]) {
        expect(
          () => SyncPairing.normalizeServer(Uri.parse(bad)),
          throwsFormatException,
          reason: bad,
        );
      }
    });

    test('toString does not reveal the password', () {
      final pairing = SyncPairing(email: _email, password: _password);

      expect(pairing.toString(), isNot(contains(_password)));
    });
  });
}
