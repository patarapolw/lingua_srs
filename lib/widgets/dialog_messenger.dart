import 'package:material_ui/material_ui.dart';

/// Gives a dialog its own [ScaffoldMessenger], so a snackbar shown from
/// inside it appears on top of the dialog instead of under its barrier.
///
/// Without it, `ScaffoldMessenger.of(context)` in a dialog finds the app's
/// messenger, whose [Scaffold] is on the page below every dialog route, and
/// the dimmed barrier covers the snackbar (#246).
///
/// It fills the dialog route with a transparent [Scaffold] that shows the
/// snackbars. That Scaffold covers the route's barrier, so a tap outside
/// [child] closes the dialog here when [dismissible], as the barrier would.
///
/// A snackbar meant to outlive the dialog, such as one shown right before it
/// closes, goes to [parentOf] instead: the messenger the dialog was opened
/// over.
class DialogMessenger extends StatefulWidget {
  final Widget child;

  /// Whether a tap outside [child] closes the dialog. Match the
  /// `barrierDismissible` the dialog was shown with.
  final bool dismissible;

  const DialogMessenger({
    super.key,
    required this.child,
    this.dismissible = true,
  });

  /// The messenger outside the nearest [DialogMessenger], for snackbars that
  /// should stay after the dialog closes. Falls back to the nearest messenger.
  static ScaffoldMessengerState parentOf(BuildContext context) {
    final scope = context
        .getInheritedWidgetOfExactType<_DialogMessengerScope>();
    return scope?.parent ?? ScaffoldMessenger.of(context);
  }

  @override
  State<DialogMessenger> createState() => _DialogMessengerState();
}

class _DialogMessengerState extends State<DialogMessenger> {
  @override
  Widget build(BuildContext context) {
    return _DialogMessengerScope(
      parent: ScaffoldMessenger.maybeOf(context),
      child: ScaffoldMessenger(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          // The dialog moves out of the keyboard's way by itself.
          resizeToAvoidBottomInset: false,
          body: Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  excludeFromSemantics: true,
                  onTap: widget.dismissible
                      ? () => Navigator.of(context).maybePop()
                      : null,
                ),
              ),
              widget.child,
            ],
          ),
        ),
      ),
    );
  }
}

class _DialogMessengerScope extends InheritedWidget {
  final ScaffoldMessengerState? parent;

  const _DialogMessengerScope({required this.parent, required super.child});

  @override
  bool updateShouldNotify(_DialogMessengerScope oldWidget) =>
      parent != oldWidget.parent;
}
