import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The desktop runners are native code, which these tests cannot run, so
/// they check its source instead. Each window has a minimum size of 360 × 480
/// logical pixels for the Flutter content, so no screen is laid out narrower
/// than the phone widths it was designed for (#184). Dragging the window as
/// small as it goes is checked by hand on each platform.
void main() {
  test('Linux: the Flutter view requests the minimum size', () {
    final source = File('linux/runner/my_application.cc').readAsStringSync();

    expect(source, contains('kMinimumWidth = 360;'));
    expect(source, contains('kMinimumHeight = 480;'));
    expect(
      source,
      contains(
        'gtk_widget_set_size_request(GTK_WIDGET(view), kMinimumWidth, '
        'kMinimumHeight);',
      ),
    );
  });

  test('macOS: the window has a minimum content size', () {
    final source = File('macos/Runner/MainFlutterWindow.swift')
        .readAsStringSync();

    expect(
      source,
      contains('self.contentMinSize = NSSize(width: 360, height: 480)'),
    );
  });

  test('Windows: WM_GETMINMAXINFO sets the minimum, scaled by DPI', () {
    final source = File('windows/runner/win32_window.cpp').readAsStringSync();

    expect(source, contains('kMinimumClientWidth = 360;'));
    expect(source, contains('kMinimumClientHeight = 480;'));

    final handler = source.indexOf('case WM_GETMINMAXINFO:');
    expect(handler, isNot(-1));
    final end = source.indexOf('case ', handler + 1);
    final body = source.substring(handler, end);

    expect(body, contains('FlutterDesktopGetDpiForHWND(hwnd)'));
    expect(body, contains('ptMinTrackSize.x'));
    expect(body, contains('ptMinTrackSize.y'));
    expect(body, contains('Scale(kMinimumClientWidth, scale_factor)'));
    expect(body, contains('Scale(kMinimumClientHeight, scale_factor)'));
  });
}
