import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/widgets/youtube_embed.dart';
import 'package:url_launcher/url_launcher.dart';

void main() {
  group('YouTubeEmbed urls', () {
    test('thumbnail and watch urls for a video', () {
      const embed = 'https://www.youtube.com/embed/abc123?enablejsapi=1';

      expect(YouTubeEmbed.videoIdFromEmbedUrl(embed), 'abc123');
      expect(
        YouTubeEmbed.thumbnailUrl(embed),
        'https://img.youtube.com/vi/abc123/hqdefault.jpg',
      );
      expect(
        YouTubeEmbed.watchUrl(embed),
        'https://www.youtube.com/watch?v=abc123',
      );
      expect(
        YouTubeEmbed.oEmbedUrl(embed).toString(),
        'https://www.youtube.com/oembed'
        '?url=https%3A%2F%2Fwww.youtube.com%2Fwatch%3Fv%3Dabc123&format=json',
      );
      expect(
        YouTubeEmbed.autoplayUrl(embed),
        'https://www.youtube.com/embed/abc123?enablejsapi=1&autoplay=1',
      );
      expect(
        YouTubeEmbed.titleFromOEmbedJson('{"title":"A video title"}'),
        'A video title',
      );
    });

    test('watch url keeps the playlist of a video', () {
      const embed = 'https://www.youtube.com/embed/abc123?list=PL1';

      expect(
        YouTubeEmbed.watchUrl(embed),
        'https://www.youtube.com/watch?v=abc123&list=PL1',
      );
    });

    test('playlist-only embeds have no thumbnail but a playlist page', () {
      const embed = 'https://www.youtube.com/embed/videoseries?list=PL1';

      expect(YouTubeEmbed.videoIdFromEmbedUrl(embed), isNull);
      expect(YouTubeEmbed.thumbnailUrl(embed), isNull);
      expect(YouTubeEmbed.oEmbedUrl(embed), isNull);
      expect(
        YouTubeEmbed.watchUrl(embed),
        'https://www.youtube.com/playlist?list=PL1',
      );
    });

    test('invalid embed urls give nothing', () {
      expect(YouTubeEmbed.thumbnailUrl(''), isNull);
      expect(YouTubeEmbed.watchUrl(''), isNull);
    });
  });

  group('YouTubeEmbed player', () {
    const embed = 'https://www.youtube.com/embed/abc123?enablejsapi=1';

    test('plays the nocookie embed with autoplay and a real origin', () {
      final src = Uri.parse(YouTubeEmbed.playerSrc(embed));
      expect(src.host, 'www.youtube-nocookie.com');
      expect(src.path, '/embed/abc123');
      expect(src.queryParameters['autoplay'], '1');
      expect(src.queryParameters['origin'], YouTubeEmbed.playerOrigin);
      expect(src.queryParameters['playsinline'], '1');
      expect(src.queryParameters['enablejsapi'], '1');
    });

    test('player page holds the iframe without fetching a host page', () {
      final html = YouTubeEmbed.playerHtml(embed);
      expect(html, contains('<iframe src="'));
      expect(html, contains('www.youtube-nocookie.com'));
      expect(html, isNot(contains('robots.txt')));
    });

    test('links out of the player open outside the app', () {
      expect(
        YouTubeEmbed.leavesPlayer('https://www.youtube.com/watch?v=abc123'),
        isTrue,
      );
      expect(
        YouTubeEmbed.leavesPlayer('https://m.youtube.com/watch?v=abc123'),
        isTrue,
      );
      expect(YouTubeEmbed.leavesPlayer('https://youtu.be/abc123'), isTrue);
      expect(
        YouTubeEmbed.leavesPlayer(
          'intent://www.youtube.com/watch?v=x#Intent;end',
        ),
        isTrue,
      );
      expect(YouTubeEmbed.leavesPlayer(YouTubeEmbed.playerSrc(embed)), isFalse);
      expect(YouTubeEmbed.leavesPlayer('about:blank'), isFalse);
      expect(
        YouTubeEmbed.leavesPlayer('https://www.youtube-nocookie.com/'),
        isFalse,
      );
    });
  });

  group('YouTubeEmbed.openExternally', () {
    final url = Uri.parse('https://www.youtube.com/watch?v=abc123');

    test('stops at the first mode that opens', () async {
      final tried = <LaunchMode>[];
      final opened = await YouTubeEmbed.openExternally(url, (_, mode) async {
        tried.add(mode);
        return true;
      });
      expect(opened, isTrue);
      expect(tried, [LaunchMode.externalNonBrowserApplication]);
    });

    test('falls back when a mode fails or throws', () async {
      final tried = <LaunchMode>[];
      final opened = await YouTubeEmbed.openExternally(url, (_, mode) async {
        tried.add(mode);
        if (mode == LaunchMode.externalNonBrowserApplication) {
          throw Exception('ACTIVITY_NOT_FOUND');
        }
        return mode == LaunchMode.inAppBrowserView;
      });
      expect(opened, isTrue);
      expect(tried, YouTubeEmbed.openModes);
    });

    test('reports failure when no mode opens', () async {
      final opened = await YouTubeEmbed.openExternally(
        url,
        (_, _) async => false,
      );
      expect(opened, isFalse);
    });
  });
}
