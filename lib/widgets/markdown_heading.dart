import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

/// Renders `h1`–`h6` as one paragraph styled by the heading.
///
/// flutter_markdown_plus wraps a heading with mixed inline styles (such as
/// `# Mnemonics for **강**`) in a span without a style, and then forces the
/// line height of body text on it. Lines of large heading text overlap. This
/// builder keeps the heading style on the whole paragraph, and its inline
/// styles add only weight, color or decoration, never a smaller size.
class MarkdownHeadingBuilder extends MarkdownElementBuilder {
  final MarkdownStyleSheet styleSheet;
  final EdgeInsets padding;
  final bool selectable;
  final void Function(String href) onLink;
  final MarkdownImageBuilder imageBuilder;

  MarkdownHeadingBuilder({
    required this.styleSheet,
    required this.padding,
    required this.selectable,
    required this.onLink,
    required this.imageBuilder,
  });

  @override
  bool isBlockElement() => true;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    return Padding(
      padding: padding,
      child: MarkdownHeadingText(
        element: element,
        style: preferredStyle,
        styleSheet: styleSheet,
        selectable: selectable,
        onLink: onLink,
        imageBuilder: imageBuilder,
      ),
    );
  }
}

class MarkdownHeadingText extends StatefulWidget {
  final md.Element element;
  final TextStyle? style;
  final MarkdownStyleSheet styleSheet;
  final bool selectable;
  final void Function(String href) onLink;
  final MarkdownImageBuilder imageBuilder;

  const MarkdownHeadingText({
    super.key,
    required this.element,
    required this.style,
    required this.styleSheet,
    required this.selectable,
    required this.onLink,
    required this.imageBuilder,
  });

  @override
  State<MarkdownHeadingText> createState() => _MarkdownHeadingTextState();
}

class _MarkdownHeadingTextState extends State<MarkdownHeadingText> {
  final _recognizers = <TapGestureRecognizer>[];
  var _hasWidgets = false;

  void _disposeRecognizers() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  /// Inline styles without a font size or line height, so text inside a
  /// heading keeps the heading's size.
  TextStyle? _inlineStyle(String tag) {
    final sheet = widget.styleSheet;
    final style = switch (tag) {
      'strong' || 'b' => sheet.strong,
      'em' || 'i' => sheet.em,
      'del' || 's' => sheet.del,
      'code' => sheet.code,
      'a' => sheet.a,
      _ => sheet.styles[tag],
    };
    if (style == null) return null;
    return TextStyle(
      color: style.color,
      backgroundColor: style.backgroundColor,
      fontWeight: style.fontWeight,
      fontStyle: style.fontStyle,
      fontFamily: style.fontFamily,
      decoration: style.decoration,
      fontFeatures: style.fontFeatures,
    );
  }

  List<InlineSpan> _spans(List<md.Node>? nodes, String? href) => [
    for (final node in nodes ?? const <md.Node>[]) ?_span(node, href),
  ];

  InlineSpan? _span(md.Node node, String? href) {
    if (node is md.Text) {
      final text = node.text.replaceAll('\n', ' ');
      if (href == null) return TextSpan(text: text);
      final recognizer = TapGestureRecognizer()
        ..onTap = () => widget.onLink(href);
      _recognizers.add(recognizer);
      return TextSpan(text: text, recognizer: recognizer);
    }
    if (node is! md.Element) return null;
    if (node.tag == 'br') return const TextSpan(text: '\n');
    if (node.tag == 'img') {
      final uri = Uri.tryParse(node.attributes['src'] ?? '');
      if (uri == null) return null;
      _hasWidgets = true;
      return WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: widget.imageBuilder(
          uri,
          node.attributes['title'],
          node.attributes['alt'],
        ),
      );
    }
    final link = node.tag == 'a' ? node.attributes['href'] : href;
    return TextSpan(
      style: _inlineStyle(node.tag),
      children: _spans(node.children, link),
    );
  }

  @override
  Widget build(BuildContext context) {
    _disposeRecognizers();
    _hasWidgets = false;
    final span = TextSpan(
      style: widget.style,
      children: _spans(widget.element.children, null),
    );
    final strut = widget.style == null
        ? null
        : StrutStyle.fromTextStyle(widget.style!);
    return SizedBox(
      width: double.infinity,
      // SelectableText can't lay out widgets such as audio buttons.
      child: widget.selectable && !_hasWidgets
          ? SelectableText.rich(span, strutStyle: strut)
          : Text.rich(span, strutStyle: strut),
    );
  }
}
