import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

/// Reveals a "Delete" panel when the child is swiped from end to start.
///
/// Unlike [Dismissible], the child follows the finger only as far as the panel
/// is wide, so it never leaves the screen. Releasing past [triggerFraction] of
/// that width (or flinging) leaves the panel open; otherwise the child springs
/// back. Nothing is asked until the panel itself is pressed, which calls
/// [onDelete]. Tapping the open child closes the panel again.
class SwipeToDelete extends StatefulWidget {
  const SwipeToDelete({
    super.key,
    required this.child,
    required this.onDelete,
    this.semanticLabel = 'Delete',
    this.margin = EdgeInsets.zero,
    this.revealWidth = 96,
    this.triggerFraction = 0.4,
  });

  final Widget child;

  /// Called when the revealed panel is pressed. It should confirm with the
  /// user; the child closes when the future completes.
  final Future<void> Function() onDelete;
  final String semanticLabel;

  /// The child's margin, so the panel lines up with it.
  final EdgeInsets margin;
  final double revealWidth;
  final double triggerFraction;

  @override
  State<SwipeToDelete> createState() => _SwipeToDeleteState();
}

class _SwipeToDeleteState extends State<SwipeToDelete> {
  double _offset = 0;
  bool _dragging = false;
  bool _busy = false;

  // The tile currently showing its Delete button; only one stays open.
  static _SwipeToDeleteState? _openTile;

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
      _offset = (_offset + details.delta.dx).clamp(-widget.revealWidth, 0);
    });
  }

  void _onDragEnd(DragEndDetails details) {
    if (_busy) return;
    final velocity = details.velocity.pixelsPerSecond.dx;
    final past = -_offset >= widget.revealWidth * widget.triggerFraction;
    final open = velocity < -700 || (velocity <= 700 && past);
    setState(() {
      _dragging = false;
      _offset = open ? -widget.revealWidth : 0;
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

  Future<void> _delete() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _dragging = false;
      _offset = -widget.revealWidth;
    });
    try {
      await widget.onDelete();
    } finally {
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
    return Semantics(
      customSemanticsActions: {
        CustomSemanticsAction(label: widget.semanticLabel): _delete,
      },
      child: Listener(
        onPointerDown: _closeOtherTile,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragUpdate: _onDragUpdate,
          onHorizontalDragEnd: _onDragEnd,
          onHorizontalDragCancel: () => setState(() {
            _dragging = false;
            if (!_busy) _offset = 0;
          }),
          child: Stack(
            children: [
              if (_offset != 0)
                Positioned(
                  top: widget.margin.top,
                  bottom: widget.margin.bottom,
                  right: widget.margin.right,
                  width: widget.revealWidth,
                  child: Material(
                    color: colors.errorContainer,
                    borderRadius: BorderRadius.circular(12),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: _delete,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.delete_outline,
                            color: colors.onErrorContainer,
                          ),
                          Text(
                            'Delete',
                            style: TextStyle(color: colors.onErrorContainer),
                          ),
                        ],
                      ),
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
