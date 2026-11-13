import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../models/sentence.dart';

/// A sentence field whose `**` emphasis is toggled with a button or with
/// Ctrl+B (⌘B on a Mac) on the selected text, so the markers never have to be
/// typed at both ends.
///
/// While [textEditable] is false the field is read-only: text can be selected
/// and its emphasis toggled, but the sentence itself cannot change.
class EmphasisField extends StatelessWidget {
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

  /// The keyboard shortcut that toggles emphasis, as this platform writes it.
  static String get shortcutLabel => switch (defaultTargetPlatform) {
    TargetPlatform.macOS || TargetPlatform.iOS => '⌘B',
    _ => 'Ctrl+B',
  };

  static String get toggleTooltip =>
      'Emphasize the selection, or take its emphasis away ($shortcutLabel)';

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

  void _toggle() {
    final toggled = toggle(controller.value);
    if (identical(toggled, controller.value)) return;
    controller.value = toggled;
    onChanged?.call(toggled.text);
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyB, control: true): _toggle,
        const SingleActivator(LogicalKeyboardKey.keyB, meta: true): _toggle,
      },
      child: TextField(
        controller: controller,
        readOnly: !textEditable,
        minLines: minLines,
        maxLines: maxLines,
        onChanged: onChanged,
        contextMenuBuilder: (context, editableTextState) =>
            AdaptiveTextSelectionToolbar.buttonItems(
              anchors: editableTextState.contextMenuAnchors,
              buttonItems: [
                ...editableTextState.contextMenuButtonItems,
                ContextMenuButtonItem(
                  label: 'Emphasis',
                  onPressed: () {
                    editableTextState.hideToolbar();
                    _toggle();
                  },
                ),
              ],
            ),
        decoration: decoration.copyWith(
          suffixIcon: IconButton(
            icon: const Icon(Icons.format_bold),
            tooltip: toggleTooltip,
            onPressed: _toggle,
          ),
        ),
      ),
    );
  }
}
