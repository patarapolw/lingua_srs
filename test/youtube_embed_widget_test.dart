import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:lingua_srs/widgets/youtube_embed.dart';
import 'package:webview_all_android/webview_all_android.dart';
import 'package:webview_platform_interface/webview_platform_interface.dart';

void main() {
  const playlist = 'https://www.youtube.com/embed/videoseries?list=PL1';
  late _TestWebViewPlatform platform;

  setUp(() {
    platform = _TestWebViewPlatform();
    WebViewPlatform.instance = platform;
  });

  testWidgets('Android enables autoplay before loading the player', (
    tester,
  ) async {
    platform.android = true;
    final gate = Completer<void>();
    platform.autoplayGate = gate;
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: YouTubeEmbed(embedUrl: playlist)),
      ),
    );

    await tester.tap(find.byIcon(Icons.play_circle_fill));
    await tester.pump();
    expect(platform.events, ['gesture:false']);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    gate.complete();
    await tester.pump();
    expect(platform.events, [
      'gesture:false',
      'fullscreen',
      'javascript',
      'delegate',
      'html',
    ]);
    expect(platform.html, contains('autoplay=1'));
    expect(platform.baseUrl, '${YouTubeEmbed.playerOrigin}/');
    expect(find.text('Video not playing? Open on YouTube'), findsOneWidget);
  });

  testWidgets('other platforms load without Android settings', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: YouTubeEmbed(embedUrl: playlist)),
      ),
    );
    await tester.tap(find.byIcon(Icons.play_circle_fill));
    await tester.pump();
    expect(platform.events, ['javascript', 'delegate', 'html']);
  });

  testWidgets('rotation moves the active player fullscreen and back', (
    tester,
  ) async {
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    platform.android = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

    Widget app(Size size) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(size: size),
        child: const Scaffold(body: YouTubeEmbed(embedUrl: playlist)),
      ),
    );

    await tester.pumpWidget(app(const Size(400, 800)));
    await tester.tap(find.byIcon(Icons.play_circle_fill));
    await tester.pumpAndSettle();
    expect(find.byType(WebViewWidget), findsOneWidget);

    await tester.pumpWidget(app(const Size(800, 400)));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('youtube-fullscreen-player')),
      findsOneWidget,
    );
    expect(find.byType(WebViewWidget), findsOneWidget);

    await tester.pumpWidget(app(const Size(400, 800)));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('youtube-fullscreen-player')),
      findsNothing,
    );
    expect(find.byType(WebViewWidget), findsOneWidget);
  });

  testWidgets('iframe fullscreen returns inline after rotating to portrait', (
    tester,
  ) async {
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    platform.android = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

    Widget app(Size size) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(size: size),
        child: const Scaffold(body: YouTubeEmbed(embedUrl: playlist)),
      ),
    );

    await tester.pumpWidget(app(const Size(400, 800)));
    await tester.tap(find.byIcon(Icons.play_circle_fill));
    await tester.pumpAndSettle();

    var exited = false;
    platform.onShowCustomWidget!(const Text('native fullscreen video'), () {
      exited = true;
      platform.onHideCustomWidget!();
    });
    await tester.pumpAndSettle();
    expect(find.text('native fullscreen video'), findsOneWidget);

    await tester.pumpWidget(app(const Size(800, 400)));
    await tester.pumpAndSettle();
    await tester.pumpWidget(app(const Size(400, 800)));
    await tester.pumpAndSettle();

    expect(exited, isTrue);
    expect(find.text('native fullscreen video'), findsNothing);
    expect(find.byType(WebViewWidget), findsOneWidget);
  });

  testWidgets('Windows loads a packaged HTTPS host asset', (tester) async {
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: YouTubeEmbed(embedUrl: playlist)),
      ),
    );
    await tester.tap(find.byIcon(Icons.play_circle_fill));
    await tester.pump();

    expect(platform.events, ['javascript', 'delegate', 'asset']);
    expect(platform.asset, 'assets/webview_host.html');
  });

  testWidgets('a startup error offers retry and the YouTube link', (
    tester,
  ) async {
    platform.android = true;
    platform.autoplayGate = Completer<void>();
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: YouTubeEmbed(embedUrl: playlist)),
      ),
    );
    await tester.tap(find.byIcon(Icons.play_circle_fill));
    await tester.pump();
    platform.autoplayGate!.completeError(StateError('WebView setup failed'));
    await tester.pump();
    expect(tester.takeException(), isA<StateError>());
    expect(find.text('Could not load the video. Retry'), findsOneWidget);
    expect(find.text('Open on YouTube'), findsOneWidget);

    platform.autoplayGate = null;
    await tester.tap(find.text('Could not load the video. Retry'));
    await tester.pump();
    expect(platform.events.last, 'html');
    expect(find.text('Video not playing? Open on YouTube'), findsOneWidget);
  });

  testWidgets('an obsolete startup cannot replace a new embed', (tester) async {
    platform.android = true;
    final gate = Completer<void>();
    platform.autoplayGate = gate;
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: YouTubeEmbed(embedUrl: playlist)),
      ),
    );
    await tester.tap(find.byIcon(Icons.play_circle_fill));
    await tester.pump();
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: YouTubeEmbed(
            embedUrl: 'https://www.youtube.com/embed/videoseries?list=PL2',
          ),
        ),
      ),
    );
    gate.complete();
    await tester.pump();
    expect(platform.events, [
      'gesture:false',
      'fullscreen',
      'javascript',
      'delegate',
    ]);
    expect(find.byIcon(Icons.play_circle_fill), findsOneWidget);
  });
}

class _TestWebViewPlatform extends WebViewPlatform {
  bool android = false;
  Completer<void>? autoplayGate;
  final events = <String>[];
  void Function(Widget, VoidCallback)? onShowCustomWidget;
  VoidCallback? onHideCustomWidget;
  String? html;
  String? baseUrl;
  String? asset;

  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) => android
      ? _TestAndroidController(params, this)
      : _TestController(params, this);

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) => _TestNavigationDelegate(params);

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) => _TestWebViewWidget(params);
}

class _TestController extends PlatformWebViewController {
  _TestController(super.params, this.owner) : super.implementation();

  final _TestWebViewPlatform owner;

  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async {
    owner.events.add('javascript');
  }

  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate handler,
  ) async {
    owner.events.add('delegate');
  }

  @override
  Future<void> loadHtmlString(String html, {String? baseUrl}) async {
    owner.events.add('html');
    owner.html = html;
    owner.baseUrl = baseUrl;
  }

  @override
  Future<void> loadFlutterAsset(String key) async {
    owner.events.add('asset');
    owner.asset = key;
  }
}

class _TestAndroidController extends _TestController
    implements AndroidWebViewController {
  _TestAndroidController(super.params, super.owner);

  @override
  Future<void> setMediaPlaybackRequiresUserGesture(bool require) async {
    owner.events.add('gesture:$require');
    await owner.autoplayGate?.future;
  }

  @override
  Future<void> setCustomWidgetCallbacks({
    required OnShowCustomWidgetCallback? onShowCustomWidget,
    required OnHideCustomWidgetCallback? onHideCustomWidget,
  }) async {
    owner.events.add('fullscreen');
    owner.onShowCustomWidget = onShowCustomWidget;
    owner.onHideCustomWidget = onHideCustomWidget;
  }

  @override
  Future<WebViewNavigationHistory> getNavigationHistory() =>
      throw UnsupportedError('Navigation history is not used by this test');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TestNavigationDelegate extends PlatformNavigationDelegate {
  _TestNavigationDelegate(super.params) : super.implementation();

  @override
  Future<void> setOnNavigationRequest(
    NavigationRequestCallback callback,
  ) async {}

  @override
  Future<void> setOnWebResourceError(WebResourceErrorCallback callback) async {}

  @override
  Future<void> setOnPageFinished(PageEventCallback callback) async {}
}

class _TestWebViewWidget extends PlatformWebViewWidget {
  _TestWebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}
