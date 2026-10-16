import 'package:flutter/material.dart';
import 'package:webview_all/webview_all.dart';
import 'package:markdown/markdown.dart' as md;

class MarkdownWebview extends StatefulWidget {
  final String markdownString;
  const MarkdownWebview({super.key, required this.markdownString});

  @override
  State<MarkdownWebview> createState() => _MarkdownWebviewState();
}

class _MarkdownWebviewState extends State<MarkdownWebview> {
  late final WebViewController _controller;

  @override
  void initState() {
    super.initState();
    
    // Initialize the controller (works for both webview_flutter and webview_win_floating)
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate()
      );

    // Convert Markdown to HTML and load it into the WebView
    final htmlContent = parseMarkdownToHtml(widget.markdownString);
    _controller.loadHtmlString(
      htmlContent,
      baseUrl: 'https://example.com',
    );
  }

  @override
  Widget build(BuildContext context) {
    // The WebViewWidget is provided by the platform implementation
    return WebViewWidget(controller: _controller);
  }
}

String parseMarkdownToHtml(String markdownString) {
  markdownString = markdownString.replaceAllMapped(
      RegExp(
        r'<YouTube\b([^>]*)>([\s\S]*?)</YouTube\s*>|<YouTube\b([^>]*)/?>',
        caseSensitive: false,
      ),
      (match) {
        final attributes = match[1] ?? match[3] ?? '';
        final videoId = RegExp(
          r'''id\s*=\s*["']([^"']+)["']''',
          caseSensitive: false,
        ).firstMatch(attributes)?.group(1) ?? 'videoseries';
        var href = 'https://www.youtube.com/embed/$videoId';

        final params = <String>["origin=https://example.com"];

        final videoPlaylistId = RegExp(
          r'''list\s*=\s*["']([^"']+)["']''',
          caseSensitive: false,
        ).firstMatch(attributes)?.group(1);
        if (videoPlaylistId != null) {
          params.add('list=$videoPlaylistId');
        }

        var title = RegExp(
          r'''title\s*=\s*["']([^"']+)["']''',
          caseSensitive: false,
        ).firstMatch(attributes)?.group(1) ?? '';
        if (title.isNotEmpty) {
          title = 'title="$title"';
        }

        if (params.isNotEmpty) {
          href = '$href?${params.join('&')}';
        }

        return '<div class="yt-container">'
        '<iframe src="$href" $title frameborder="0" allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share" referrerpolicy="strict-origin-when-cross-origin" allowfullscreen></iframe>'
        '</div>';
      },
    );

  // Convert Markdown to HTML using GitHub Flavored Markdown
  final htmlBody = md.markdownToHtml(markdownString);

  // Wrap it in a basic HTML document with viewport settings for mobile
  return '''
    <!DOCTYPE html>
    <html>
      <head>
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <meta name="referrer" content="strict-origin-when-cross-origin">
        <meta name="color-scheme" content="dark light">
        <style>
          :root {
            color-scheme: light dark;
          }
          body {
            font-family: sans-serif;
            padding: 16px;
            margin: 0 auto;
            max-width: 1000px;

            background-color: #ffffff;
            color: #000000;
          }
          a {
            color: #0066cc;
          }

          @media (prefers-color-scheme: dark) {
            body {
              background-color: #121212;
              color: #e0e0e0;
            }
            a {
              color: #8ab4f8;
            }
            code, pre {
              background-color: #1e1e1e;
              color: #e0e0e0;
            }
            blockquote {
              border-left-color: #444;
              color: #a0a0a0;
            }
          }
        </style>
        <style>
          .spoiler:not(:hover) {
            filter: blur(5px);
          }
        </style>
        <style>
          .yt-container {
            padding-bottom: 56.25%;
            position: relative;

            iframe {
              position: absolute;
              top: 0px;
              left: 0px;
              width: 100%;
              height: 100%;
            }
          }
        </style>

      </head>
      <body>$htmlBody</body>
    </html>
  ''';
}