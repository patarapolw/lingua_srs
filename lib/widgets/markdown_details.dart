import 'package:material_ui/material_ui.dart';

/// A piece of Markdown text: plain Markdown, or one `<details>` block.
class MarkdownDetailsPart {
  /// The Markdown of this piece: for a `<details>` block, what is inside it,
  /// without its `<summary>`.
  final String text;

  /// The text of the block's `<summary>`; null for plain Markdown.
  final String? summary;

  /// Whether the block has the `open` attribute, and so starts expanded.
  final bool open;

  const MarkdownDetailsPart(this.text, {this.summary, this.open = false});

  bool get isDetails => summary != null;

  /// The summary shown for a block without a `<summary>`, as browsers do.
  static const defaultSummary = 'Details';

  // Code first, so that tags in it are skipped: a fenced block, then an
  // inline code span, then the tags.
  static final _token = RegExp(
    r'(^```[\s\S]*?^```[ \t]*$|^~~~[\s\S]*?^~~~[ \t]*$)'
    r'|(`+)[^\n]*?\2'
    r'|<details\b([^>]*)>'
    r'|</details\s*>',
    multiLine: true,
    caseSensitive: false,
  );
  static final _summary = RegExp(
    r'^\s*<summary\b[^>]*>([\s\S]*?)</summary\s*>',
    caseSensitive: false,
  );
  static final _openAttribute = RegExp(
    r'(^|\s)open(\s|=|$)',
    caseSensitive: false,
  );

  /// Cuts [input] at its outermost `<details>` blocks, or returns null when
  /// it has none. A block inside another stays in the outer block's text.
  ///
  /// A block that is never closed runs to the end. Tags in code are text.
  static List<MarkdownDetailsPart>? split(String input) {
    if (!input.toLowerCase().contains('<details')) return null;

    final parts = <MarkdownDetailsPart>[];
    var depth = 0;
    var plainStart = 0;
    var innerStart = 0;
    var attributes = '';

    void addDetails(int innerEnd) {
      var inner = input.substring(innerStart, innerEnd);
      var summary = defaultSummary;
      final match = _summary.firstMatch(inner);
      if (match != null) {
        final text = match[1]!.trim();
        if (text.isNotEmpty) summary = text;
        inner = inner.substring(match.end);
      }
      parts.add(
        MarkdownDetailsPart(
          inner.trim(),
          summary: summary,
          open: _openAttribute.hasMatch(attributes),
        ),
      );
    }

    for (final match in _token.allMatches(input)) {
      final tag = match[0]!.toLowerCase();
      if (tag.startsWith('<details')) {
        if (depth == 0) {
          final plain = input.substring(plainStart, match.start).trim();
          if (plain.isNotEmpty) parts.add(MarkdownDetailsPart(plain));
          innerStart = match.end;
          attributes = match[3] ?? '';
        }
        depth++;
      } else if (tag.startsWith('</details') && depth > 0) {
        depth--;
        if (depth == 0) {
          addDetails(match.start);
          plainStart = match.end;
        }
      }
    }
    if (depth > 0) {
      addDetails(input.length);
    } else {
      final plain = input.substring(plainStart).trim();
      if (plain.isNotEmpty) parts.add(MarkdownDetailsPart(plain));
    }
    return parts.any((part) => part.isDetails) ? parts : null;
  }
}

/// A `<details>` block: its [summary], which shows and hides [child] when
/// tapped.
class MarkdownDetails extends StatefulWidget {
  final Widget summary;
  final Widget child;
  final bool initiallyOpen;

  const MarkdownDetails({
    super.key,
    required this.summary,
    required this.child,
    this.initiallyOpen = false,
  });

  @override
  State<MarkdownDetails> createState() => _MarkdownDetailsState();
}

class _MarkdownDetailsState extends State<MarkdownDetails>
    with AutomaticKeepAliveClientMixin {
  late bool _open = widget.initiallyOpen;

  // A block that was opened or closed by hand stays so when the lesson is
  // scrolled away from it and back.
  @override
  bool get wantKeepAlive => _open != widget.initiallyOpen;

  void _toggle() {
    setState(() => _open = !_open);
    updateKeepAlive();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            button: true,
            expanded: _open,
            child: InkWell(
              onTap: _toggle,
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      _open ? Icons.arrow_drop_down : Icons.arrow_right,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                    Flexible(child: widget.summary),
                  ],
                ),
              ),
            ),
          ),
          if (_open)
            Container(
              margin: const EdgeInsets.only(left: 11, top: 4),
              padding: const EdgeInsets.only(left: 16),
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(color: theme.dividerColor, width: 2),
                ),
              ),
              child: widget.child,
            ),
        ],
      ),
    );
  }
}
