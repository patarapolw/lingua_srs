import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/widgets/youtube_embed.dart';

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
        'https://m.youtube.com/watch?v=abc123',
      );
    });

    test('watch url keeps the playlist of a video', () {
      const embed = 'https://www.youtube.com/embed/abc123?list=PL1';

      expect(
        YouTubeEmbed.watchUrl(embed),
        'https://m.youtube.com/watch?v=abc123&list=PL1',
      );
    });

    test('playlist-only embeds have no thumbnail but a playlist page', () {
      const embed = 'https://www.youtube.com/embed/videoseries?list=PL1';

      expect(YouTubeEmbed.videoIdFromEmbedUrl(embed), isNull);
      expect(YouTubeEmbed.thumbnailUrl(embed), isNull);
      expect(
        YouTubeEmbed.watchUrl(embed),
        'https://m.youtube.com/playlist?list=PL1',
      );
    });

    test('invalid embed urls give nothing', () {
      expect(YouTubeEmbed.thumbnailUrl(''), isNull);
      expect(YouTubeEmbed.watchUrl(''), isNull);
    });
  });
}
