import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:webview_all_android/webview_all_android.dart';
import 'package:webview_platform_interface/webview_platform_interface.dart';

/// A WebView platform that loads nothing: it records the page, the scripts
/// run in it and the callbacks the app registered, and lets a test send what
/// the page would (`controller.send`) or finish loading (`controller.finish`).
class FakeWebViewPlatform extends WebViewPlatform {
  final controllers = <FakeWebViewController>[];
  bool android = false;

  /// The controller of the most recently created WebView.
  FakeWebViewController get controller => controllers.last;

  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) {
    final controller = android
        ? FakeAndroidWebViewController(params)
        : FakeWebViewController(params);
    controllers.add(controller);
    return controller;
  }

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) => FakeNavigationDelegate(params);

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) => _FakeWebViewWidget(params);
}

class FakeAndroidWebViewController extends FakeWebViewController
    implements AndroidWebViewController {
  FakeAndroidWebViewController(super.params);

  OnShowCustomWidgetCallback? onShowCustomWidget;
  OnHideCustomWidgetCallback? onHideCustomWidget;

  @override
  Future<void> setMediaPlaybackRequiresUserGesture(bool require) async {}

  @override
  Future<void> setCustomWidgetCallbacks({
    required OnShowCustomWidgetCallback? onShowCustomWidget,
    required OnHideCustomWidgetCallback? onHideCustomWidget,
  }) async {
    this.onShowCustomWidget = onShowCustomWidget;
    this.onHideCustomWidget = onHideCustomWidget;
  }

  @override
  Future<WebViewNavigationHistory> getNavigationHistory() =>
      throw UnsupportedError('Navigation history is not used by this test');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeWebViewController extends PlatformWebViewController {
  FakeWebViewController(super.params) : super.implementation();

  String? html;
  String? baseUrl;
  String? flutterAsset;
  Uri? requested;
  final scripts = <String>[];
  final _channels = <String, void Function(JavaScriptMessage)>{};
  FakeNavigationDelegate? delegate;

  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async {}

  @override
  Future<void> setBackgroundColor(Color color) async {}

  @override
  Future<void> addJavaScriptChannel(
    JavaScriptChannelParams javaScriptChannelParams,
  ) async {
    _channels[javaScriptChannelParams.name] =
        javaScriptChannelParams.onMessageReceived;
  }

  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate handler,
  ) async {
    delegate = handler as FakeNavigationDelegate;
  }

  @override
  Future<void> loadHtmlString(String html, {String? baseUrl}) async {
    this.html = html;
    this.baseUrl = baseUrl;
  }

  @override
  Future<void> loadFlutterAsset(String key) async {
    flutterAsset = key;
  }

  @override
  Future<void> loadRequest(LoadRequestParams params) async {
    requested = params.uri;
  }

  @override
  Future<void> runJavaScript(String javaScript) async {
    scripts.add(javaScript);
  }

  /// What the page sends through the `Lingua` channel.
  void send(Map<String, Object?> message) =>
      _channels['Lingua']!(JavaScriptMessage(message: jsonEncode(message)));

  /// The page has loaded.
  void finish() => delegate!.onPageFinished?.call('about:blank');
}

class FakeNavigationDelegate extends PlatformNavigationDelegate {
  FakeNavigationDelegate(super.params) : super.implementation();

  NavigationRequestCallback? onNavigationRequest;
  PageEventCallback? onPageFinished;

  @override
  Future<void> setOnNavigationRequest(
    NavigationRequestCallback onNavigationRequest,
  ) async => this.onNavigationRequest = onNavigationRequest;

  @override
  Future<void> setOnPageFinished(PageEventCallback onPageFinished) async =>
      this.onPageFinished = onPageFinished;
}

class _FakeWebViewWidget extends PlatformWebViewWidget {
  _FakeWebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}
