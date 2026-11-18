import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

/// Saves an edit dialog on Ctrl+Enter or Ctrl+S (Cmd on macOS), wherever
/// the focus is inside [child].
///
/// While [onSave] runs, the keys do nothing more, so holding them or pressing
/// them twice saves once.
class DialogSaveShortcuts extends StatefulWidget {
  const DialogSaveShortcuts({
    super.key,
    required this.onSave,
    required this.child,
    this.autofocus = true,
  });

  final Future<void> Function() onSave;
  final Widget child;

  /// Whether to take the focus when the dialog opens, so the keys work before
  /// anything in it is clicked. Pass false when a field autofocuses instead.
  final bool autofocus;

  /// The key combinations that save.
  static const activators = [
    SingleActivator(LogicalKeyboardKey.enter, control: true),
    SingleActivator(LogicalKeyboardKey.enter, meta: true),
    SingleActivator(LogicalKeyboardKey.numpadEnter, control: true),
    SingleActivator(LogicalKeyboardKey.numpadEnter, meta: true),
    SingleActivator(LogicalKeyboardKey.keyS, control: true),
    SingleActivator(LogicalKeyboardKey.keyS, meta: true),
  ];

  @override
  State<DialogSaveShortcuts> createState() => _DialogSaveShortcutsState();
}

class _DialogSaveShortcutsState extends State<DialogSaveShortcuts> {
  bool _saving = false;

  Future<void> _save() async {
    if (_saving) return;
    _saving = true;
    try {
      await widget.onSave();
    } finally {
      _saving = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        for (final activator in DialogSaveShortcuts.activators)
          activator: _save,
      },
      // Holds the focus when no field has it; Tab skips it.
      child: Focus(
        autofocus: widget.autofocus,
        skipTraversal: true,
        child: widget.child,
      ),
    );
  }
}
