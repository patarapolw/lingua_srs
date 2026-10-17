import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_all/webview_all.dart';

/// Renders a single YouTube video or playlist in a WebView.
/// Only the embed is rendered in the WebView; Markdown is not.
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

  @override
  State<YouTubeEmbed> createState() => _YouTubeEmbedState();
}

class _YouTubeEmbedState extends State<YouTubeEmbed> {
  late final WebViewController _controller;

  // YouTube rejects embeds (Error 153) from pages without a real HTTPS origin,
  // which is what loadHtmlString gives on Windows. Load a harmless
  // youtube-nocookie.com page and inject the iframe so the player gets a valid
  // origin and referrer.
  static const _hostPage = 'https://www.youtube-nocookie.com/robots.txt';
  static const _origin = 'https://www.youtube-nocookie.com';

  @override
  void initState() {
    super.initState();
    final embed = Uri.parse(widget.embedUrl);
    final src = embed
        .replace(
          host: 'www.youtube-nocookie.com',
          queryParameters: {...embed.queryParameters, 'origin': _origin},
        )
        .toString();
    final script =
        '''
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
    var injected = false;
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            if (injected) return;
            injected = true;
            _controller.runJavaScript(script);
          },
        ),
      )
      ..loadRequest(Uri.parse(_hostPage));
  }

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: WebViewWidget(controller: _controller),
      ),
    );
  }
}
