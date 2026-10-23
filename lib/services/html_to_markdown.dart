import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:html2md/html2md.dart' as html2md;

/// Tags that carry formatting worth keeping. HTML without any of them (code
/// copied from an editor, say, which is only styled spans and divs) is better
/// pasted as plain text.
const _formattingSelector =
    'b,strong,i,em,a,ul,ol,li,h1,h2,h3,h4,h5,h6,pre,code,blockquote,table,'
    'img,del,s,strike,hr';

final _boldStyle = RegExp(
  r'font-weight\s*:\s*(bold|bolder|[6-9]00)',
  caseSensitive: false,
);
final _normalWeightStyle = RegExp(
  r'font-weight\s*:\s*(normal|[1-4]00)',
  caseSensitive: false,
);
final _italicStyle = RegExp(r'font-style\s*:\s*italic', caseSensitive: false);
final _strikeStyle = RegExp(
  r'text-decoration[^;]*line-through',
  caseSensitive: false,
);

/// Converts clipboard [html] to Markdown, or returns null when it has no
/// formatting worth converting (so the caller pastes the plain text).
String? htmlToMarkdown(String html) {
  final body = html_parser.parse(_fragmentOf(html)).body;
  if (body == null) return null;

  _unwrapNormalWeightBold(body);
  _applyInlineStyles(body);
  if (body.querySelector(_formattingSelector) == null) return null;

  final markdown = html2md.convert(
    body.innerHtml,
    styleOptions: {
      'headingStyle': 'atx',
      'bulletListMarker': '-',
      // `_` does not emphasize inside Korean text (`_배_를`), `*` does.
      'emDelimiter': '*',
      'codeBlockStyle': 'fenced',
    },
    ignore: ['script', 'style'],
  );
  final tidy = _tidy(markdown);
  return tidy.isEmpty ? null : tidy;
}

/// Windows and some browsers wrap the copied part in fragment markers.
String _fragmentOf(String html) {
  final match = RegExp(
    r'<!--\s*StartFragment\s*-->(.*?)<!--\s*EndFragment\s*-->',
    dotAll: true,
    caseSensitive: false,
  ).firstMatch(html);
  return match?.group(1) ?? html;
}

/// Google Docs wraps everything in `<b style="font-weight:normal">`, which is
/// not bold at all.
void _unwrapNormalWeightBold(Element root) {
  for (final element in root.querySelectorAll('b,strong')) {
    final style = element.attributes['style'] ?? '';
    if (!_normalWeightStyle.hasMatch(style) || _boldStyle.hasMatch(style)) {
      continue;
    }
    final parent = element.parentNode;
    if (parent == null) continue;
    for (final node in element.nodes.toList()) {
      node.remove();
      parent.insertBefore(node, element);
    }
    element.remove();
  }
}

/// Word and Google Docs mark bold, italic and strikethrough with inline styles
/// on spans instead of tags.
void _applyInlineStyles(Element root) {
  for (final span in root.querySelectorAll('span')) {
    final style = span.attributes['style'] ?? '';
    if (style.isEmpty) continue;
    if (_strikeStyle.hasMatch(style)) _wrapContents(span, 'del');
    if (_italicStyle.hasMatch(style)) _wrapContents(span, 'em');
    if (_boldStyle.hasMatch(style)) _wrapContents(span, 'strong');
  }
}

void _wrapContents(Element element, String tag) {
  final wrapper = Element.tag(tag);
  for (final node in element.nodes.toList()) {
    node.remove();
    wrapper.append(node);
  }
  element.append(wrapper);
}

/// html2md pads list markers (`-   item`); make them `- item`.
String _tidy(String markdown) {
  final lines = markdown
      .replaceAll('\r\n', '\n')
      .replaceAll('\u00A0', ' ')
      .split('\n');
  final out = <String>[];
  var inFence = false;
  for (final line in lines) {
    if (line.trimLeft().startsWith('```')) {
      inFence = !inFence;
      out.add(line);
    } else if (inFence) {
      out.add(line);
    } else {
      out.add(
        line
            .replaceFirstMapped(
              RegExp(r'^(\s*)([-*+])\s{2,}(?=\S)'),
              (m) => '${m[1]}${m[2]} ',
            )
            .replaceFirstMapped(
              RegExp(r'^(\s*)(\d+\.)\s{2,}(?=\S)'),
              (m) => '${m[1]}${m[2]} ',
            ),
      );
    }
  }
  return out.join('\n').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
}
