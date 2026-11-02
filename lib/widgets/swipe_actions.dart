import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

enum SwipeActionKind { destructive, caution }

/// One button of the panel a [SwipeActions] tile reveals.
class SwipeAction {
  const SwipeAction({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.kind = SwipeActionKind.destructive,
    this.semanticLabel,
  });

  final String label;
  final IconData icon;
  final SwipeActionKind kind;

  /// Announced to screen readers instead of [label], e.g. "Delete discussion".
  final String? semanticLabel;

  /// Called when the button is pressed. It should confirm with the user; the
  /// tile closes when the future completes.
  final Future<void> Function() onPressed;
}

/// Reveals a panel of [actions] when the child is swiped from end to start.
///
/// Unlike [Dismissible], the child follows the finger only as far as the panel
/// is wide, so it never leaves the screen. Releasing past [triggerFraction] of
/// that width (or flinging) leaves the panel open; otherwise the child springs
/// back. Nothing is asked until an action is pressed. Tapping the open child
/// closes the panel again, and only one tile stays open at a time.
class SwipeActions extends StatefulWidget {
  const SwipeActions({
    super.key,
    required this.child,
    required this.actions,
    this.margin = EdgeInsets.zero,
    this.actionWidth = 96,
    this.triggerFraction = 0.4,
  }) : assert(actions.length > 0);

  final Widget child;
  final List<SwipeAction> actions;

  /// The child's margin, so the panel lines up with it.
  final EdgeInsets margin;
  final double actionWidth;
  final double triggerFraction;

  @override
  State<SwipeActions> createState() => _SwipeActionsState();
}

class _SwipeActionsState extends State<SwipeActions> {
  double _offset = 0;
  bool _dragging = false;
  bool _busy = false;

  // The tile currently showing its actions; only one stays open.
  static _SwipeActionsState? _openTile;

  double get _revealWidth => widget.actionWidth * widget.actions.length;
  bool get _open => _offset != 0;

  @override
  void dispose() {
    if (_openTile == this) _openTile = null;
    super.dispose();
  }

  void _closeOtherTile(PointerDownEvent _) {
    final other = _openTile;
    if (other != null && other != this && other.mounted && !other._busy) {
      other._close();
    }
  }

  void _onDragUpdate(DragUpdateDetails details) {
    if (_busy) return;
    setState(() {
      _dragging = true;
      _offset = (_offset + details.delta.dx).clamp(-_revealWidth, 0);
    });
  }

  void _onDragEnd(DragEndDetails details) {
    if (_busy) return;
    final velocity = details.velocity.pixelsPerSecond.dx;
    final past = -_offset >= _revealWidth * widget.triggerFraction;
    final open = velocity < -700 || (velocity <= 700 && past);
    setState(() {
      _dragging = false;
      _offset = open ? -_revealWidth : 0;
    });
    if (open) {
      _openTile = this;
    } else if (_openTile == this) {
      _openTile = null;
    }
  }

  void _close() {
    if (_openTile == this) _openTile = null;
    setState(() {
      _dragging = false;
      _offset = 0;
    });
  }

  Future<void> _run(SwipeAction action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _dragging = false;
      _offset = -_revealWidth;
    });
    try {
      await action.onPressed();
    } finally {
      if (_openTile == this) _openTile = null;
      if (mounted) {
        setState(() {
          _busy = false;
          _offset = 0;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(12);
    return Semantics(
      customSemanticsActions: {
        for (final action in widget.actions)
          CustomSemanticsAction(
            label: action.semanticLabel ?? action.label,
          ): () =>
              _run(action),
      },
      child: Listener(
        onPointerDown: _closeOtherTile,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragUpdate: _onDragUpdate,
          onHorizontalDragEnd: _onDragEnd,
          onHorizontalDragCancel: () {
            if (!_busy) _close();
          },
          child: Stack(
            children: [
              if (_open)
                Positioned(
                  top: widget.margin.top,
                  bottom: widget.margin.bottom,
                  right: widget.margin.right,
                  width: _revealWidth,
                  child: ClipRRect(
                    borderRadius: radius,
                    child: Row(
                      children: [
                        for (final action in widget.actions)
                          Expanded(
                            child: Material(
                              color: switch (action.kind) {
                                SwipeActionKind.destructive =>
                                  colors.errorContainer,
                                SwipeActionKind.caution =>
                                  colors.tertiaryContainer,
                              },
                              child: InkWell(
                                onTap: () => _run(action),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      action.icon,
                                      color: switch (action.kind) {
                                        SwipeActionKind.destructive =>
                                          colors.onErrorContainer,
                                        SwipeActionKind.caution =>
                                          colors.onTertiaryContainer,
                                      },
                                    ),
                                    Text(
                                      action.label,
                                      style: TextStyle(
                                        color: switch (action.kind) {
                                          SwipeActionKind.destructive =>
                                            colors.onErrorContainer,
                                          SwipeActionKind.caution =>
                                            colors.onTertiaryContainer,
                                        },
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              AnimatedContainer(
                duration: _dragging
                    ? Duration.zero
                    : const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                transform: Matrix4.translationValues(_offset, 0, 0),
                child: _open
                    ? GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _busy ? null : _close,
                        child: AbsorbPointer(child: widget.child),
                      )
                    : widget.child,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
