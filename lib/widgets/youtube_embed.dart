import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_all/webview_all.dart';
import 'package:webview_all_android/webview_all_android.dart';

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

  /// Launch modes tried in turn to open the YouTube link outside the player:
  /// the YouTube app, then any browser, then an in-app browser tab. A single
  /// mode can fail on Android (no app takes the link, or YouTube is blocked
  /// for the default handler), and the next one may still work.
  static const openModes = [
    LaunchMode.externalNonBrowserApplication,
    LaunchMode.externalApplication,
    LaunchMode.inAppBrowserView,
  ];

  /// Opens [url] with the first of [openModes] that [launch] reports as
  /// opened. A mode that throws counts as failed.
  static Future<bool> openExternally(
    Uri url,
    Future<bool> Function(Uri url, LaunchMode mode) launch,
  ) async {
    for (final mode in openModes) {
      try {
        if (await launch(url, mode)) return true;
      } catch (_) {}
    }
    return false;
  }

  /// Whether a navigation inside the player leaves the embed, e.g. the
  /// YouTube logo or "Watch on YouTube", which the WebView can't show
  /// (`intent:` links on Android) and which should open outside the app.
  static bool leavesPlayer(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    if (uri.scheme == 'intent' || uri.scheme == 'vnd.youtube') return true;
    if (uri.scheme != 'http' && uri.scheme != 'https') return false;
    final host = uri.host.toLowerCase();
    final isYouTube =
        host == 'youtu.be' ||
        host == 'youtube.com' ||
        host.endsWith('.youtube.com');
    final path = uri.path;
    return isYouTube &&
        (path == '/watch' ||
            path.startsWith('/shorts/') ||
            path == '/playlist' ||
            host == 'youtu.be');
  }

  /// The page the WebView shows to play [embedUrl]: an iframe of the player
  /// on youtube-nocookie.com, which needs a real HTTPS origin and referrer
  /// (else Error 153).
  static String playerHtml(String embedUrl) =>
      '<!DOCTYPE html><html><head>'
      '<meta name="viewport" content="width=device-width, initial-scale=1">'
      '<style>html,body{margin:0;height:100%;background:#000}'
      'iframe{position:absolute;inset:0;width:100%;height:100%;border:0}'
      '</style></head><body>'
      '<iframe src="${const HtmlEscape().convert(playerSrc(embedUrl))}" '
      'allow="accelerometer; autoplay; clipboard-write; encrypted-media; '
      'gyroscope; picture-in-picture; web-share; fullscreen" '
      'referrerpolicy="strict-origin-when-cross-origin" allowfullscreen>'
      '</iframe></body></html>';

  /// The origin the player page claims; see [playerHtml].
  static const playerOrigin = 'https://www.youtube-nocookie.com';

  /// The iframe URL of the player: the embed on youtube-nocookie.com with
  /// autoplay and [playerOrigin].
  static String playerSrc(String embedUrl) {
    final embed = Uri.parse(autoplayUrl(embedUrl));
    return embed
        .replace(
          host: 'www.youtube-nocookie.com',
          queryParameters: {
            ...embed.queryParameters,
            'origin': playerOrigin,
            'playsinline': '1',
          },
        )
        .toString();
  }

  @override
  State<YouTubeEmbed> createState() => _YouTubeEmbedState();
}

class _YouTubeEmbedState extends State<YouTubeEmbed> {
  WebViewController? _controller;
  final _playerKey = GlobalKey();
  bool _failed = false;
  bool _starting = false;
  bool _orientationFullscreen = false;
  bool _landscapeFullscreenDismissed = false;
  int _generation = 0;
  Orientation? _lastOrientation;
  Route<void>? _orientationFullscreenRoute;
  Route<void>? _customFullscreenRoute;
  VoidCallback? _exitCustomFullscreen;
  NavigatorState? _fullscreenNavigator;
  late Future<String?> _titleFuture;

  // On Windows, loadHtmlString's base URL does not give the document a real
  // HTTPS origin. WebView2 serves this bundled asset from a local HTTPS origin.
  static const _windowsHostAsset = 'assets/webview_host.html';

  @override
  void initState() {
    super.initState();
    _titleFuture = _loadTitle();
  }

  @override
  void didUpdateWidget(YouTubeEmbed oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.embedUrl != widget.embedUrl) {
      _generation++;
      _controller = null;
      _failed = false;
      _starting = false;
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
    final src = YouTubeEmbed.playerSrc(widget.embedUrl);
    return '''
document.documentElement.innerHTML =
  '<head><meta name="viewport" content="width=device-width, initial-scale=1"></head>' +
  '<body style="margin:0;height:100vh;background:#000"></body>';
var f = document.createElement('iframe');
var src = new URL(${jsonEncode(src)});
if (location.origin !== 'null') {
  src.searchParams.set('origin', location.origin);
}
f.src = src.toString();
f.allow = 'accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share; fullscreen';
f.referrerPolicy = 'strict-origin-when-cross-origin';
f.allowFullscreen = true;
f.style.cssText = 'position:absolute;inset:0;width:100%;height:100%;border:0';
document.body.appendChild(f);
''';
  }

  Future<void> _start() async {
    if (_starting) return;
    final generation = ++_generation;
    setState(() {
      _starting = true;
      _failed = false;
    });
    final useWindowsHostAsset =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
    var injected = false;
    try {
      final controller = WebViewController();
      final platform = controller.platform;
      if (platform is AndroidWebViewController) {
        // The thumbnail tap occurs outside the WebView, so it is not a
        // WebView gesture capable of authorizing autoplay.
        await platform.setMediaPlaybackRequiresUserGesture(false);
        await platform.setCustomWidgetCallbacks(
          onShowCustomWidget: _showCustomFullscreenWidget,
          onHideCustomWidget: _hideCustomFullscreenWidget,
        );
      }
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      await controller.setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            if (!mounted || generation != _generation) {
              return NavigationDecision.prevent;
            }
            if (!YouTubeEmbed.leavesPlayer(request.url)) {
              return NavigationDecision.navigate;
            }
            _openOnYouTube();
            return NavigationDecision.prevent;
          },
          onWebResourceError: (error) {
            if (!mounted ||
                generation != _generation ||
                error.isForMainFrame == false) {
              return;
            }
            setState(() => _failed = true);
          },
          onPageFinished: (_) {
            if (!mounted ||
                generation != _generation ||
                !useWindowsHostAsset ||
                injected) {
              return;
            }
            injected = true;
            controller.runJavaScript(_embedScript);
          },
        ),
      );
      if (!mounted || generation != _generation) return;
      if (useWindowsHostAsset) {
        await controller.loadFlutterAsset(_windowsHostAsset);
      } else {
        await controller.loadHtmlString(
          YouTubeEmbed.playerHtml(widget.embedUrl),
          baseUrl: '${YouTubeEmbed.playerOrigin}/',
        );
      }
      if (!mounted || generation != _generation) return;
      setState(() {
        _controller = controller;
        _starting = false;
      });
    } catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'YouTube embed',
          context: ErrorDescription('while starting the video player'),
        ),
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _starting = false;
        _failed = true;
      });
    }
  }

  /// Opens the regular YouTube link outside the app, where the video plays
  /// even when YouTube forbids the iframe.
  Future<void> _openOnYouTube() async {
    final url = YouTubeEmbed.watchUrl(widget.embedUrl);
    if (url == null) return;
    final opened = await YouTubeEmbed.openExternally(
      Uri.parse(url),
      (url, mode) => launchUrl(url, mode: mode),
    );
    if (!opened && mounted) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(const SnackBar(content: Text('Could not open YouTube.')));
    }
  }

  bool get _supportsOrientationFullscreen =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  void _updateFullscreenForOrientation(Orientation orientation) {
    final previous = _lastOrientation;
    _lastOrientation = orientation;
    if (orientation == Orientation.portrait) {
      _landscapeFullscreenDismissed = false;
      if (previous == Orientation.landscape) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted ||
              MediaQuery.orientationOf(context) != Orientation.portrait) {
            return;
          }
          _exitCustomFullscreen?.call();
          _exitOrientationFullscreen();
        });
      }
    } else if (previous == Orientation.portrait &&
        _supportsOrientationFullscreen &&
        _controller != null &&
        !_landscapeFullscreenDismissed &&
        _customFullscreenRoute == null &&
        _orientationFullscreenRoute == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _enterOrientationFullscreen();
      });
    }
  }

  Route<void> _fullscreenRoute(Widget child) => PageRouteBuilder<void>(
    opaque: true,
    pageBuilder: (context, _, _) =>
        Scaffold(backgroundColor: Colors.black, body: child),
    transitionDuration: Duration.zero,
    reverseTransitionDuration: Duration.zero,
  );

  void _updateFullscreenSystemUi() {
    final fullscreen =
        _orientationFullscreenRoute != null || _customFullscreenRoute != null;
    unawaited(
      SystemChrome.setEnabledSystemUIMode(
        fullscreen ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
      ),
    );
  }

  void _enterOrientationFullscreen() {
    final controller = _controller;
    if (!mounted ||
        controller == null ||
        _orientationFullscreenRoute != null ||
        _customFullscreenRoute != null ||
        _landscapeFullscreenDismissed) {
      return;
    }
    final navigator = Navigator.of(context);
    final route = _fullscreenRoute(
      Semantics(
        label: 'YouTube fullscreen video',
        key: const ValueKey('youtube-fullscreen-player'),
        child: WebViewWidget(key: _playerKey, controller: controller),
      ),
    );
    _fullscreenNavigator = navigator;
    _orientationFullscreenRoute = route;
    setState(() => _orientationFullscreen = true);
    _updateFullscreenSystemUi();
    unawaited(
      navigator.push(route).whenComplete(() {
        if (!identical(_orientationFullscreenRoute, route)) return;
        _orientationFullscreenRoute = null;
        if (_customFullscreenRoute == null) _fullscreenNavigator = null;
        _orientationFullscreen = false;
        _landscapeFullscreenDismissed = true;
        _updateFullscreenSystemUi();
        if (mounted) setState(() {});
      }),
    );
  }

  void _exitOrientationFullscreen() {
    final route = _orientationFullscreenRoute;
    if (route == null) return;
    _orientationFullscreenRoute = null;
    _orientationFullscreen = false;
    _fullscreenNavigator?.removeRoute(route);
    if (_customFullscreenRoute == null) _fullscreenNavigator = null;
    _updateFullscreenSystemUi();
    if (mounted) setState(() {});
  }

  void _showCustomFullscreenWidget(
    Widget widget,
    VoidCallback onCustomWidgetHidden,
  ) {
    if (!mounted) {
      onCustomWidgetHidden();
      return;
    }
    final navigator = Navigator.of(context);
    final route = _fullscreenRoute(widget);
    _customFullscreenRoute = route;
    _exitCustomFullscreen = onCustomWidgetHidden;
    _fullscreenNavigator = navigator;
    _updateFullscreenSystemUi();
    unawaited(
      navigator.push(route).whenComplete(() {
        if (!identical(_customFullscreenRoute, route)) return;
        _customFullscreenRoute = null;
        _exitCustomFullscreen = null;
        if (_orientationFullscreenRoute == null) _fullscreenNavigator = null;
        onCustomWidgetHidden();
        _updateFullscreenSystemUi();
      }),
    );
  }

  void _hideCustomFullscreenWidget() {
    final route = _customFullscreenRoute;
    _customFullscreenRoute = null;
    _exitCustomFullscreen = null;
    if (route != null && route.isActive) {
      _fullscreenNavigator?.removeRoute(route);
    }
    if (_orientationFullscreenRoute == null) _fullscreenNavigator = null;
    _updateFullscreenSystemUi();
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
    _updateFullscreenForOrientation(MediaQuery.orientationOf(context));
    final controller = _controller;
    final Widget player;
    if (_failed) {
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
    } else if (_starting) {
      player = const Center(child: CircularProgressIndicator());
    } else if (_orientationFullscreen) {
      player = const SizedBox.shrink();
    } else if (controller == null) {
      player = _thumbnail(context);
    } else {
      player = WebViewWidget(key: _playerKey, controller: controller);
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
        if (controller != null && !_failed && !_orientationFullscreen)
          TextButton(
            onPressed: _openOnYouTube,
            child: const Text('Video not playing? Open on YouTube'),
          ),
      ],
    );
  }
}
