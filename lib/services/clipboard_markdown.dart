import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:super_clipboard/super_clipboard.dart';

import 'html_to_markdown.dart';

/// Reads the HTML flavor of the system clipboard, if it has one.
typedef ClipboardHtmlReader = Future<String?> Function();

Future<String?> _readSystemClipboardHtml() async {
  final clipboard = SystemClipboard.instance;
  if (clipboard == null) return null;
  final reader = await clipboard.read();
  if (!reader.canProvide(Formats.htmlText)) return null;
  return reader.readValue(Formats.htmlText);
}

/// Replaced in tests, which have no native clipboard.
@visibleForTesting
ClipboardHtmlReader clipboardHtmlReader = _readSystemClipboardHtml;

/// The clipboard as Markdown: converted from HTML when it has formatting,
/// otherwise the plain text. Null when the clipboard has no text.
Future<String?> readClipboardAsMarkdown() async {
  try {
    final html = await clipboardHtmlReader();
    if (html != null && html.trim().isNotEmpty) {
      final markdown = htmlToMarkdown(html);
      if (markdown != null) return markdown;
    }
  } catch (_) {
    // No native clipboard here, or the HTML could not be read: fall back to
    // the plain text below.
  }
  final data = await Clipboard.getData(Clipboard.kTextPlain);
  final text = data?.text;
  return text == null || text.isEmpty ? null : text;
}
