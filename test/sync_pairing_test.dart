import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/services/sync_pairing.dart';

const _email = 'reader@example.com';
const _password = 'correct horse battery staple';
final _server = Uri.parse('https://sync.example.com');

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
