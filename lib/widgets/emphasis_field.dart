import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../models/sentence.dart';

/// A sentence field whose `**` emphasis is toggled on the selected text, so
/// the markers never have to be typed at both ends.
///
/// While text is selected, an *Emphasize* (or *Remove emphasis*) button shows
/// under the field. On a computer, Ctrl+B (⌘B on a Mac) does the same, and
/// with nothing selected toggles the word at the cursor.
///
/// While [textEditable] is false the field is read-only: text can be selected
/// and its emphasis toggled, but the sentence itself cannot change.
class EmphasisField extends StatefulWidget {
  final TextEditingController controller;
  final InputDecoration decoration;
  final bool textEditable;
  final ValueChanged<String>? onChanged;
  final int? minLines;
  final int? maxLines;

  const EmphasisField({
    super.key,
    required this.controller,
    this.decoration = const InputDecoration(),
    this.textEditable = true,
    this.onChanged,
    this.minLines,
    this.maxLines = 1,
  });

  /// Whether this platform has a keyboard shortcut worth mentioning.
  static bool get hasShortcut => switch (defaultTargetPlatform) {
    TargetPlatform.macOS ||
    TargetPlatform.windows ||
    TargetPlatform.linux => true,
    _ => false,
  };

  /// The keyboard shortcut that toggles emphasis, as this platform writes it.
  static String get shortcutLabel =>
      defaultTargetPlatform == TargetPlatform.macOS ? '⌘B' : 'Ctrl+B';

  /// How to emphasize a part, for helper text: `Select a part and choose
  /// Emphasize`, with the shortcut on a computer.
  static String howTo(String part) =>
      'Select $part and choose Emphasize'
      '${hasShortcut ? ' (or press $shortcutLabel)' : ''}';

  /// [value] with the emphasis of its selection toggled, as
  /// [Sentence.toggleEmphasis] describes. A value with no selection, or no
  /// change, is returned as it is.
  static TextEditingValue toggle(TextEditingValue value) {
    final selection = value.selection;
    if (!selection.isValid) return value;
    final toggled = Sentence.toggleEmphasis(
      value.text,
      selection.start,
      selection.end,
    );
    if (toggled.text == value.text) return value;
    return TextEditingValue(
      text: toggled.text,
      selection: TextSelection(
        baseOffset: toggled.start,
        extentOffset: toggled.end,
      ),
    );
  }

  @override
  State<EmphasisField> createState() => _EmphasisFieldState();
}

class _EmphasisFieldState extends State<EmphasisField> {
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_refresh);
    _focusNode.addListener(_refresh);
  }

  @override
  void didUpdateWidget(EmphasisField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_refresh);
      widget.controller.addListener(_refresh);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_refresh);
    _focusNode.dispose();
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  void _toggle() {
    final value = widget.controller.value;
    final toggled = EmphasisField.toggle(value);
    if (identical(toggled, value)) return;
    widget.controller.value = toggled;
    widget.onChanged?.call(toggled.text);
  }

  @override
  Widget build(BuildContext context) {
    final selection = widget.controller.selection;
    final selecting =
        _focusNode.hasFocus && selection.isValid && !selection.isCollapsed;
    // The button counts as part of the field, so tapping it neither takes
    // the focus away nor clears the selection it acts on.
    return TextFieldTapRegion(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.keyB, control: true):
                  _toggle,
              const SingleActivator(LogicalKeyboardKey.keyB, meta: true):
                  _toggle,
            },
            child: TextField(
              controller: widget.controller,
              focusNode: _focusNode,
              readOnly: !widget.textEditable,
              minLines: widget.minLines,
              maxLines: widget.maxLines,
              onChanged: widget.onChanged,
              decoration: widget.decoration,
            ),
          ),
          if (selecting)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _toggle,
                child: Text(
                  Sentence.isEmphasized(
                        widget.controller.text,
                        selection.start,
                        selection.end,
                      )
                      ? 'Remove emphasis'
                      : 'Emphasize',
                ),
              ),
            ),
        ],
      ),
    );
  }
}
