import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
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
    expect(platform.events, ['gesture:false', 'javascript', 'delegate']);
    expect(find.byIcon(Icons.play_circle_fill), findsOneWidget);
  });
}

class _TestWebViewPlatform extends WebViewPlatform {
  bool android = false;
  Completer<void>? autoplayGate;
  final events = <String>[];
  String? html;
  String? baseUrl;

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
