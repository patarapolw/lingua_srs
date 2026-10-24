import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/clipboard_markdown.dart';

class _PasteMarkdownIntent extends Intent {
  const _PasteMarkdownIntent();
}

/// A [TextField] for Markdown. Pasting (shortcut or context menu) converts
/// copied HTML, such as a web page or a Google Docs selection, to Markdown;
/// anything without formatting pastes as plain text.
class MarkdownTextField extends StatelessWidget {
  final TextEditingController controller;
  final InputDecoration decoration;
  final int? minLines;
  final int? maxLines;
  final bool expands;
  final bool enabled;
  final bool autofocus;
  final TextStyle? style;
  final StrutStyle? strutStyle;
  final TextAlignVertical? textAlignVertical;
  final TextInputType? keyboardType;
  final ValueChanged<String>? onChanged;

  const MarkdownTextField({
    super.key,
    required this.controller,
    this.decoration = const InputDecoration(),
    this.minLines,
    this.maxLines = 1,
    this.expands = false,
    this.enabled = true,
    this.autofocus = false,
    this.style,
    this.strutStyle,
    this.textAlignVertical,
    this.keyboardType,
    this.onChanged,
  });

  Future<void> _paste() async {
    final markdown = await readClipboardAsMarkdown();
    if (markdown == null) return;
    final value = controller.value;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : value.text.length;
    final end = selection.isValid ? selection.end : value.text.length;
    controller.value = value.copyWith(
      text: value.text.replaceRange(start, end, markdown),
      selection: TextSelection.collapsed(offset: start + markdown.length),
      composing: TextRange.empty,
    );
    onChanged?.call(controller.text);
  }

  Widget _contextMenu(BuildContext context, EditableTextState state) {
    final items = [
      for (final item in state.contextMenuButtonItems)
        if (item.type == ContextMenuButtonType.paste)
          item.copyWith(
            onPressed: () {
              state.hideToolbar();
              _paste();
            },
          )
        else
          item,
    ];
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: state.contextMenuAnchors,
      buttonItems: items,
    );
  }

  @override
  Widget build(BuildContext context) {
    // A Shortcuts closer to the field than the default text shortcuts, with an
    // intent of our own: EditableText always handles PasteTextIntent itself.
    return Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        const SingleActivator(LogicalKeyboardKey.keyV, control: true):
            const _PasteMarkdownIntent(),
        const SingleActivator(LogicalKeyboardKey.keyV, meta: true):
            const _PasteMarkdownIntent(),
        const SingleActivator(LogicalKeyboardKey.insert, shift: true):
            const _PasteMarkdownIntent(),
      },
      child: Actions(
        actions: {
          _PasteMarkdownIntent: CallbackAction<_PasteMarkdownIntent>(
            onInvoke: (_) => _paste(),
          ),
        },
        child: TextField(
          controller: controller,
          decoration: decoration,
          minLines: minLines,
          maxLines: maxLines,
          expands: expands,
          enabled: enabled,
          autofocus: autofocus,
          style: style,
          strutStyle: strutStyle,
          textAlignVertical: textAlignVertical,
          keyboardType: keyboardType,
          onChanged: onChanged,
          contextMenuBuilder: _contextMenu,
        ),
      ),
    );
  }
}
