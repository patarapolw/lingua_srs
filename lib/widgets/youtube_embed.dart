import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_all/webview_all.dart';

import 'cached_markdown_image.dart';

/// Shows a single YouTube video or playlist as a cached thumbnail, and only
/// starts a WebView when it is tapped. If the embed cannot play (the WebView
/// errors, or YouTube forbids the iframe), the regular YouTube link can be
/// opened in a real browser or the YouTube app instead.
class YouTubeEmbed extends StatefulWidget {
  final String embedUrl;

  const YouTubeEmbed({super.key, required this.embedUrl});

  /// Builds an embed URL from `<YouTube id="..." list="..." src="...">` attributes.
  static String? embedUrlFromAttributes(String attributes) {
    String? attr(String name) {
      final m = RegExp(
        '(?:^|\\s)$name\\s*=\\s*(?:"([^"]*)"|\'([^\']*)\'|([^\\s"\'>/]+))',
        caseSensitive: false,
      ).firstMatch(attributes);
      final value = m?.group(1) ?? m?.group(2) ?? m?.group(3);
      return value == null || value.isEmpty ? null : value;
    }

    var videoId = attr('id') ?? attr('video-id') ?? attr('video_id');
    var playlistId = attr('list');

    final src = attr('src');
    if (src != null) {
      final uri = Uri.tryParse(src);
      if (uri != null && uri.hasScheme) {
        playlistId ??= uri.queryParameters['list'];
        if (uri.host.contains('youtu.be') && uri.pathSegments.isNotEmpty) {
          videoId ??= uri.pathSegments.first;
        } else if (uri.pathSegments.length >= 2 &&
            uri.pathSegments.first == 'embed') {
          videoId ??= uri.pathSegments[1];
        } else {
          videoId ??= uri.queryParameters['v'];
        }
      } else {
        videoId ??= src;
      }
    }

    if (videoId == 'videoseries') videoId = null;
    if (videoId == null && playlistId == null) return null;

    final base = 'https://www.youtube.com/embed/${videoId ?? 'videoseries'}';
    final queryParameters = {'enablejsapi': '1', 'list': ?playlistId};
    return Uri.parse(base).replace(queryParameters: queryParameters).toString();
  }

  /// The video id of an embed URL, or null for a playlist-only embed.
  static String? videoIdFromEmbedUrl(String embedUrl) {
    final uri = Uri.tryParse(embedUrl);
    if (uri == null || uri.pathSegments.length < 2) return null;
    final id = uri.pathSegments[1];
    return uri.pathSegments.first == 'embed' && id != 'videoseries' ? id : null;
  }

  /// A thumbnail for the video; null for a playlist-only embed.
  static String? thumbnailUrl(String embedUrl) {
    final id = videoIdFromEmbedUrl(embedUrl);
    return id == null ? null : 'https://img.youtube.com/vi/$id/hqdefault.jpg';
  }

  /// The YouTube oEmbed endpoint used to retrieve a video's title.
  static Uri? oEmbedUrl(String embedUrl) {
    final watchUrl = YouTubeEmbed.watchUrl(embedUrl);
    if (videoIdFromEmbedUrl(embedUrl) == null || watchUrl == null) return null;
    return Uri.https('www.youtube.com', '/oembed', {
      'url': watchUrl,
      'format': 'json',
    });
  }

  /// Adds the autoplay request used after the thumbnail is tapped.
  static String autoplayUrl(String embedUrl) {
    final uri = Uri.parse(embedUrl);
    return uri
        .replace(queryParameters: {...uri.queryParameters, 'autoplay': '1'})
        .toString();
  }

  static String? titleFromOEmbedJson(String body) {
    final json = jsonDecode(body);
    if (json is! Map<String, dynamic>) return null;
    final title = json['title'];
    return title is String && title.trim().isNotEmpty ? title : null;
  }

  /// The regular YouTube link of the embed, for a browser or the YouTube app.
  static String? watchUrl(String embedUrl) {
    final uri = Uri.tryParse(embedUrl);
    if (uri == null) return null;
    final id = videoIdFromEmbedUrl(embedUrl);
    final list = uri.queryParameters['list'];
    if (id == null && list == null) return null;
    if (id == null) {
      return Uri.https('www.youtube.com', '/playlist', {
        'list': list,
      }).toString();
    }
    return Uri.https('www.youtube.com', '/watch', {
      'v': id,
      'list': ?list,
    }).toString();
  }

  @override
  State<YouTubeEmbed> createState() => _YouTubeEmbedState();
}

class _YouTubeEmbedState extends State<YouTubeEmbed> {
  WebViewController? _controller;
  bool _failed = false;
  late Future<String?> _titleFuture;

  // YouTube rejects embeds (Error 153) from pages without a real HTTPS origin,
  // which is what loadHtmlString gives on Windows. Load a harmless
  // youtube-nocookie.com page and inject the iframe so the player gets a valid
  // origin and referrer.
  static const _hostPage = 'https://www.youtube-nocookie.com/robots.txt';
  static const _origin = 'https://www.youtube-nocookie.com';

  @override
  void initState() {
    super.initState();
    _titleFuture = _loadTitle();
  }

  @override
  void didUpdateWidget(YouTubeEmbed oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.embedUrl != widget.embedUrl) {
      _controller = null;
      _failed = false;
      _titleFuture = _loadTitle();
    }
  }

  /// Titles by video id, so rebuilt embeds in a lazy list don't refetch.
  /// Failed requests are dropped so they can be retried.
  static final Map<String, Future<String?>> _titleCache = {};

  Future<String?> _loadTitle() {
    final url = YouTubeEmbed.oEmbedUrl(widget.embedUrl);
    final id = YouTubeEmbed.videoIdFromEmbedUrl(widget.embedUrl);
    if (url == null || id == null) return Future.value(null);
    return _titleCache.putIfAbsent(id, () {
      final future = _fetchTitle(url);
      future.catchError((Object _) {
        _titleCache.remove(id);
        return null;
      });
      return future;
    });
  }

  static Future<String?> _fetchTitle(Uri url) async {
    final response = await http.get(url).timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      throw StateError('YouTube title request failed: ${response.statusCode}');
    }
    return YouTubeEmbed.titleFromOEmbedJson(response.body);
  }

  String get _embedScript {
    final embed = Uri.parse(YouTubeEmbed.autoplayUrl(widget.embedUrl));
    final src = embed
        .replace(
          host: 'www.youtube-nocookie.com',
          queryParameters: {...embed.queryParameters, 'origin': _origin},
        )
        .toString();
    return '''
document.documentElement.innerHTML =
  '<head><meta name="viewport" content="width=device-width, initial-scale=1"></head>' +
  '<body style="margin:0;height:100vh;background:#000"></body>';
var f = document.createElement('iframe');
f.src = ${jsonEncode(src)};
f.allow = 'accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share; fullscreen';
f.referrerPolicy = 'strict-origin-when-cross-origin';
f.allowFullscreen = true;
f.style.cssText = 'position:absolute;inset:0;width:100%;height:100%;border:0';
document.body.appendChild(f);
''';
  }

  void _start() {
    var injected = false;
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onWebResourceError: (error) {
            if (!mounted || error.isForMainFrame == false) return;
            setState(() => _failed = true);
          },
          onPageFinished: (_) {
            if (injected) return;
            injected = true;
            _controller?.runJavaScript(_embedScript);
          },
        ),
      )
      ..loadRequest(Uri.parse(_hostPage));
    setState(() {
      _controller = controller;
      _failed = false;
    });
  }

  /// Opens the regular YouTube link outside the app, where the video plays
  /// even when YouTube forbids the iframe.
  Future<void> _openOnYouTube() async {
    final url = YouTubeEmbed.watchUrl(widget.embedUrl);
    if (url == null) return;
    var opened = false;
    try {
      opened = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {}
    if (!opened && mounted) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(const SnackBar(content: Text('Could not open YouTube.')));
    }
  }

  Widget _thumbnail(BuildContext context) {
    final thumbnail = YouTubeEmbed.thumbnailUrl(widget.embedUrl);
    return Material(
      color: Colors.black,
      child: InkWell(
        onTap: _start,
        child: Stack(
          alignment: Alignment.center,
          fit: StackFit.expand,
          children: [
            if (thumbnail != null)
              Positioned.fill(
                child: CachedMarkdownImage(url: thumbnail, fit: BoxFit.cover),
              ),
            if (thumbnail != null)
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                child: DecoratedBox(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.black87, Colors.transparent],
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
                    child: FutureBuilder<String?>(
                      future: _titleFuture,
                      builder: (context, snapshot) {
                        final title = snapshot.hasError || snapshot.hasData
                            ? snapshot.data ?? 'Video title unavailable'
                            : 'Loading video title…';
                        return Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            const Icon(Icons.play_circle_fill, size: 64, color: Colors.white70),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final Widget player;
    if (controller == null) {
      player = _thumbnail(context);
    } else if (_failed) {
      player = Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton.icon(
              onPressed: _start,
              icon: const Icon(Icons.refresh),
              label: const Text('Could not load the video. Retry'),
            ),
            TextButton.icon(
              onPressed: _openOnYouTube,
              icon: const Icon(Icons.open_in_new),
              label: const Text('Open on YouTube'),
            ),
          ],
        ),
      );
    } else {
      player = WebViewWidget(controller: controller);
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        AspectRatio(
          aspectRatio: 16 / 9,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: player,
          ),
        ),
        if (controller != null && !_failed)
          TextButton(
            onPressed: _openOnYouTube,
            child: const Text('Video not playing? Open on YouTube'),
          ),
      ],
    );
  }
}
