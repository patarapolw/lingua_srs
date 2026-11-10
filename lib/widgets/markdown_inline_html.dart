import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

/// The inline HTML that lesson Markdown may use, as Markdown elements.
///
/// The Markdown renderer shows HTML it does not know as typed, tags
/// included. These syntaxes turn the few tags lessons use into elements it
/// can style: see [inlineHtmlStyles].
List<md.InlineSyntax> inlineHtmlSyntaxes() => [
  HtmlBreakSyntax(),
  HtmlSpanSyntax(),
];

/// `<br>`, `<br/>` and `<br />` as a line break: in a paragraph, a list item,
/// a heading or a table cell.
class HtmlBreakSyntax extends md.InlineSyntax {
  HtmlBreakSyntax() : super(r'<br\s*/?>', caseSensitive: false);

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(md.Element.empty('br'));
    return true;
  }
}

/// `<ins>`, `<mark>`, `<sup>` and other paired inline tags, with the
/// Markdown inside them parsed too.
class HtmlSpanSyntax extends md.InlineSyntax {
  /// The element each HTML tag becomes.
  static const tags = {
    'ins': 'ins',
    'u': 'ins',
    'mark': 'mark',
    'sup': 'sup',
    'sub': 'sub',
    'em': 'em',
    'i': 'em',
    'strong': 'strong',
    'b': 'strong',
    's': 'del',
  };

  HtmlSpanSyntax()
    : super(
        '<(${tags.keys.join('|')})(?:\\s[^>]*)?>([\\s\\S]*?)</\\1\\s*>',
        caseSensitive: false,
      );

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(
      md.Element(
        tags[match[1]!.toLowerCase()]!,
        parser.document.parseInline(match[2]!),
      ),
    );
    return true;
  }
}

/// Styles of the elements [HtmlSpanSyntax] makes that Markdown itself has
/// no style for. They leave out the font size and line height, so the text
/// keeps the size of the block it is in.
Map<String, TextStyle> inlineHtmlStyles(ThemeData theme) => {
  'ins': const TextStyle(decoration: TextDecoration.underline),
  'mark': TextStyle(
    color: theme.colorScheme.onTertiaryContainer,
    backgroundColor: theme.colorScheme.tertiaryContainer,
  ),
  'sup': const TextStyle(fontFeatures: [FontFeature.superscripts()]),
  'sub': const TextStyle(fontFeatures: [FontFeature.subscripts()]),
};

/// Builds an element of [HtmlSpanSyntax] that the renderer has no style
/// for, as text that flows with the paragraph around it.
class InlineHtmlBuilder extends MarkdownElementBuilder {
  final ThemeData theme;

  InlineHtmlBuilder(this.theme);

  /// One builder for each tag in [inlineHtmlStyles] that needs one. The
  /// renderer styles `sup` by itself.
  static Map<String, MarkdownElementBuilder> all(ThemeData theme) => {
    for (final tag in const ['ins', 'mark', 'sub'])
      tag: InlineHtmlBuilder(theme),
  };

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) => Text.rich(
    TextSpan(
      children: _spans(
        element.children,
        theme,
        (parentStyle ?? const TextStyle()).merge(
          inlineHtmlStyles(theme)[element.tag],
        ),
      ),
    ),
  );
}

/// The text of [nodes] as spans, each styled from [base].
List<InlineSpan> _spans(
  List<md.Node>? nodes,
  ThemeData theme, [
  TextStyle? base,
]) {
  final styles = <String, TextStyle>{
    'strong': TextStyle(
      fontWeight: FontWeight.bold,
      color: theme.colorScheme.primary,
    ),
    'em': const TextStyle(fontStyle: FontStyle.italic),
    'del': const TextStyle(decoration: TextDecoration.lineThrough),
    'code': const TextStyle(fontFamily: 'monospace'),
    ...inlineHtmlStyles(theme),
  };

  // One span per run of text, each with its whole style: when the renderer
  // joins inline text it keeps only the first level of a span's children,
  // and not the style of the span they are in.
  final spans = <InlineSpan>[];
  void add(md.Node node, TextStyle? style) {
    if (node is! md.Element) {
      spans.add(TextSpan(text: node.textContent, style: style));
    } else if (node.tag == 'br') {
      spans.add(TextSpan(text: '\n', style: style));
    } else {
      final own = styles[node.tag];
      final merged = style == null ? own : style.merge(own);
      for (final child in node.children ?? const <md.Node>[]) {
        add(child, merged);
      }
    }
  }

  for (final node in nodes ?? const <md.Node>[]) {
    add(node, base);
  }
  return spans;
}

/// Inline Markdown (with the HTML above) as text spans, for text shown
/// outside the Markdown renderer.
List<InlineSpan> inlineMarkdownSpans(String text, ThemeData theme) {
  final document = md.Document(
    inlineSyntaxes: inlineHtmlSyntaxes(),
    extensionSet: md.ExtensionSet.gitHubFlavored,
    encodeHtml: false,
  );
  return _spans(document.parseInline(text), theme);
}
