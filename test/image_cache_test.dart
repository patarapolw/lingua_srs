import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lingua_srs/services/image_cache_service.dart';
import 'package:lingua_srs/widgets/cached_markdown_image.dart';
import 'package:lingua_srs/widgets/markdown_content.dart';

/// A 1x1 PNG.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

class _Server {
  int requests = 0;
  int status = 200;
  String? contentType = 'image/png';
  List<int> body = _png;
  Duration delay = Duration.zero;

  MockClient get client => MockClient((request) async {
    requests++;
    await Future<void>.delayed(delay);
    return http.Response.bytes(
      body,
      status,
      headers: {'content-type': ?contentType},
    );
  });
}

void main() {
  late Directory directory;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('lingua_srs_image_cache_');
  });
  tearDown(() => directory.deleteSync(recursive: true));

  ImageCacheService cacheFor(_Server server) => ImageCacheService(
    client: server.client,
    directory: () async => Directory('${directory.path}/images'),
  );

  group('ImageCacheService', () {
    const url = 'https://example.com/a.png';

    test('downloads once and then serves the saved copy', () async {
      final server = _Server();
      final cache = cacheFor(server);

      final first = await cache.fetch(url);
      final second = await cache.fetch(url);

      expect(first, isNotNull);
      expect(await first!.readAsBytes(), _png);
      expect(second!.path, first.path);
      expect(server.requests, 1);
    });

    test('keeps images across restarts', () async {
      await cacheFor(_Server()).fetch(url);

      final later = _Server();
      final file = await cacheFor(later).fetch(url);

      expect(file, isNotNull);
      expect(later.requests, 0);
    });

    test('images asked for at once are downloaded once', () async {
      final server = _Server()..delay = const Duration(milliseconds: 30);
      final cache = cacheFor(server);

      final files = await Future.wait([
        cache.fetch(url),
        cache.fetch(url),
        cache.fetch(url),
      ]);

      expect(server.requests, 1);
      expect(files.every((file) => file != null), isTrue);
    });

    test('a failed download is not remembered', () async {
      final server = _Server()..status = 404;
      final cache = cacheFor(server);

      expect(await cache.fetch(url), isNull);
      server.status = 200;
      expect(await cache.fetch(url), isNotNull);
      expect(server.requests, 2);
    });

    test('pages, JSON, SVG and empty bodies are not kept', () async {
      for (final type in ['text/html; charset=utf-8', 'application/json']) {
        final server = _Server()..contentType = type;
        expect(
          await cacheFor(server).fetch('https://example.com/$type'),
          isNull,
        );
      }
      final svg = _Server()..contentType = 'image/svg+xml';
      expect(await cacheFor(svg).fetch('https://example.com/a.svg'), isNull);
      final empty = _Server()..body = [];
      expect(await cacheFor(empty).fetch('https://example.com/empty'), isNull);
    });

    test('a missing or generic content type is trusted', () async {
      for (final type in [null, 'application/octet-stream', 'image/jpeg']) {
        final server = _Server()..contentType = type;
        expect(
          await cacheFor(server).fetch('https://example.com/$type'),
          isNotNull,
          reason: '$type',
        );
      }
    });

    test('only http and https images are cached', () async {
      final server = _Server();
      final cache = cacheFor(server);

      expect(
        ImageCacheService.isCacheable('https://example.com/a.png'),
        isTrue,
      );
      expect(ImageCacheService.isCacheable('http://example.com/a.png'), isTrue);
      for (final other in [
        'data:image/png;base64,AAAA',
        'a.png',
        'file:///a',
      ]) {
        expect(ImageCacheService.isCacheable(other), isFalse, reason: other);
        expect(await cache.fetch(other), isNull);
      }
      expect(server.requests, 0);
    });

    test('evict and clear make the next fetch download again', () async {
      final server = _Server();
      final cache = cacheFor(server);

      await cache.fetch(url);
      await cache.evict(url);
      await cache.fetch(url);
      expect(server.requests, 2);

      await cache.clear();
      await cache.fetch(url);
      expect(server.requests, 3);
    });
  });

  group('Markdown images', () {
    late ImageCacheService original;
    setUp(() => original = ImageCacheService.instance);
    tearDown(() => ImageCacheService.instance = original);

    Future<void> pumpImage(WidgetTester tester, String url) =>
        tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: CachedMarkdownImage(url: url)),
          ),
        );

    testWidgets('shows the saved copy from disk', (tester) async {
      final file = File('${directory.path}/saved.png')..writeAsBytesSync(_png);
      ImageCacheService.instance = _FixedCache(file);

      await pumpImage(tester, 'https://example.com/a.png');
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.pump();

      final image = tester.widget<Image>(find.byType(Image));
      expect(image.image, isA<FileImage>());
      expect((image.image as FileImage).file.path, file.path);
    });

    testWidgets('falls back to the network when it cannot be saved', (
      tester,
    ) async {
      ImageCacheService.instance = _FixedCache(null);

      await pumpImage(tester, 'https://example.com/a.png');
      await tester.pump();

      expect(
        tester.widget<Image>(find.byType(Image)).image,
        isA<NetworkImage>(),
      );
    });

    testWidgets('a URL the cache does not handle is not looked up', (
      tester,
    ) async {
      final cache = _FixedCache(null);
      ImageCacheService.instance = cache;

      await pumpImage(tester, 'assets/a.png');

      expect(cache.asked, isEmpty);
    });

    testWidgets('Markdown images go through the cache', (tester) async {
      final cache = _FixedCache(null);
      ImageCacheService.instance = cache;

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: MarkdownContent(
              content: '![pear](https://example.com/p.png)',
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(CachedMarkdownImage), findsOneWidget);
      expect(cache.asked, ['https://example.com/p.png']);
    });
  });
}

class _FixedCache extends ImageCacheService {
  _FixedCache(this.file);

  final File? file;
  final List<String> asked = [];

  @override
  Future<File?> fetch(String url) async {
    asked.add(url);
    return file;
  }
}
