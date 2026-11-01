import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class AnswerWorkspace extends StatefulWidget {
  final VoidCallback onSubmit;

  const AnswerWorkspace({super.key, required this.onSubmit});

  @override
  State<AnswerWorkspace> createState() => _AnswerWorkspaceState();
}

enum _AnswerMode { draw, type }

class _AnswerStroke {
  final List<Offset> points;
  final Color color;
  final bool eraser;

  const _AnswerStroke({
    required this.points,
    required this.color,
    required this.eraser,
  });
}

class _AnswerWorkspaceState extends State<AnswerWorkspace> {
  static const _colors = {
    'Black': Colors.black,
    'Blue': Colors.blue,
    'Red': Colors.red,
    'Green': Colors.green,
  };

  final _textController = TextEditingController();
  final _canvasKey = GlobalKey();
  final List<_AnswerStroke> _strokes = [];
  late _AnswerMode _mode = _isDesktop ? _AnswerMode.type : _AnswerMode.draw;
  Color _color = Colors.black;
  bool _eraser = false;
  bool _drawing = false;
  bool _expanded = false;

  bool get _isDesktop => switch (defaultTargetPlatform) {
    TargetPlatform.windows ||
    TargetPlatform.macOS ||
    TargetPlatform.linux => true,
    _ => false,
  };

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  Offset _normalize(Offset point, Size size) => Offset(
    (point.dx / size.width).clamp(0.0, 1.0).toDouble(),
    (point.dy / size.height).clamp(0.0, 1.0).toDouble(),
  );

  Size get _canvasSize {
    final renderBox =
        _canvasKey.currentContext!.findRenderObject() as RenderBox;
    return renderBox.size;
  }

  void _startStroke(DragStartDetails details, StateSetter setDialogState) {
    final size = _canvasSize;
    setDialogState(() {
      _drawing = true;
      _strokes.add(
        _AnswerStroke(
          points: [_normalize(details.localPosition, size)],
          color: _color,
          eraser: _eraser,
        ),
      );
    });
  }

  void _extendStroke(DragUpdateDetails details, StateSetter setDialogState) {
    if (!_drawing || _strokes.isEmpty) return;
    final size = _canvasSize;
    final last = _strokes.last;
    setDialogState(() {
      _strokes[_strokes.length - 1] = _AnswerStroke(
        points: [...last.points, _normalize(details.localPosition, size)],
        color: last.color,
        eraser: last.eraser,
      );
    });
  }

  void _endStroke() {
    _drawing = false;
  }

  KeyEventResult _handleTextKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        HardwareKeyboard.instance.isControlPressed &&
        (event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.numpadEnter)) {
      widget.onSubmit();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    if (!_expanded) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.only(top: 16, bottom: 8),
          child: TextButton.icon(
            icon: const Icon(Icons.edit_note, size: 18),
            label: const Text('Scratchpad'),
            onPressed: () => setState(() => _expanded = true),
          ),
        ),
      );
    }

    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Scratchpad', style: theme.textTheme.labelLarge),
              ),
              IconButton(
                tooltip: 'Draw',
                visualDensity: VisualDensity.compact,
                isSelected: _mode == _AnswerMode.draw,
                icon: const Icon(Icons.draw_outlined),
                onPressed: () {
                  setState(() => _mode = _AnswerMode.draw);
                  _openDrawing();
                },
              ),
              IconButton(
                tooltip: 'Type',
                visualDensity: VisualDensity.compact,
                isSelected: _mode == _AnswerMode.type,
                icon: const Icon(Icons.keyboard_outlined),
                onPressed: () => setState(() => _mode = _AnswerMode.type),
              ),
              IconButton(
                tooltip: 'Hide scratchpad',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.expand_less),
                onPressed: () => setState(() => _expanded = false),
              ),
            ],
          ),
          if (_mode == _AnswerMode.type)
            Focus(
              onKeyEvent: _handleTextKey,
              child: TextField(
                controller: _textController,
                minLines: 1,
                maxLines: 3,
                decoration: InputDecoration(
                  hintText: 'Type your answer…',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    tooltip: 'Clear typed answer',
                    onPressed: _textController.text.isEmpty
                        ? null
                        : () {
                            _textController.clear();
                            setState(() {});
                          },
                    icon: const Icon(Icons.clear),
                  ),
                ),
                onChanged: (_) => setState(() {}),
              ),
            )
          else
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(Icons.fullscreen, size: 18),
                label: Text(
                  _strokes.isEmpty ? 'Open drawing pad' : 'Continue drawing',
                ),
                onPressed: _openDrawing,
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _openDrawing() =>
      showDialog<void>(
        context: context,
        barrierColor: Colors.transparent,
        builder: (context) => StatefulBuilder(
          builder: (context, setDialogState) =>
              _buildDrawingScratchpad(context, setDialogState),
        ),
      ).then((_) {
        if (mounted) setState(() {});
      });

  Widget _buildDrawingScratchpad(
    BuildContext context,
    StateSetter setDialogState,
  ) {
    final theme = Theme.of(context);
    return Dialog.fullscreen(
      backgroundColor: Colors.transparent,
      child: Scaffold(
        backgroundColor: theme.colorScheme.surface.withValues(alpha: 0.6),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              children: [
                Material(
                  elevation: 3,
                  color: theme.colorScheme.surface,
                  borderRadius: BorderRadius.circular(24),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 2,
                      children: [
                        IconButton(
                          tooltip: 'Close scratchpad',
                          icon: const Icon(Icons.close),
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                        for (final entry in _colors.entries)
                          IconButton(
                            tooltip: '${entry.key} pen',
                            visualDensity: VisualDensity.compact,
                            onPressed: () => setDialogState(() {
                              _color = entry.value;
                              _eraser = false;
                            }),
                            icon: Icon(
                              Icons.circle,
                              color: entry.value,
                              size: 20,
                            ),
                            style: IconButton.styleFrom(
                              side: _color == entry.value && !_eraser
                                  ? BorderSide(color: theme.colorScheme.primary)
                                  : BorderSide.none,
                            ),
                          ),
                        IconButton(
                          tooltip: _eraser ? 'Pen' : 'Eraser',
                          visualDensity: VisualDensity.compact,
                          onPressed: () =>
                              setDialogState(() => _eraser = !_eraser),
                          icon: Icon(
                            _eraser ? Icons.edit : Icons.auto_fix_normal,
                          ),
                        ),
                        IconButton(
                          tooltip: 'Clear drawing',
                          visualDensity: VisualDensity.compact,
                          onPressed: _strokes.isEmpty
                              ? null
                              : () => setDialogState(_strokes.clear),
                          icon: const Icon(Icons.delete_outline),
                        ),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: GestureDetector(
                    key: _canvasKey,
                    behavior: HitTestBehavior.opaque,
                    onTap: () {},
                    onPanStart: (details) =>
                        _startStroke(details, setDialogState),
                    onPanUpdate: (details) =>
                        _extendStroke(details, setDialogState),
                    onPanEnd: (_) => _endStroke(),
                    child: CustomPaint(
                      key: const ValueKey('answer-drawing-canvas'),
                      foregroundPainter: _AnswerPainter(
                        List.unmodifiable(_strokes),
                      ),
                      child: Center(
                        child: _strokes.isEmpty
                            ? DecoratedBox(
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.surface.withValues(
                                    alpha: 0.55,
                                  ),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 6,
                                  ),
                                  child: Text(
                                    'Write with your finger or pen',
                                    style: theme.textTheme.bodySmall,
                                  ),
                                ),
                              )
                            : null,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AnswerPainter extends CustomPainter {
  final List<_AnswerStroke> strokes;

  const _AnswerPainter(this.strokes);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.saveLayer(Offset.zero & size, Paint());
    for (final stroke in strokes) {
      final paint = Paint()
        ..color = stroke.color
        ..strokeWidth = stroke.eraser ? 20 : 3
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;
      if (stroke.eraser) paint.blendMode = BlendMode.clear;
      final points = stroke.points
          .map((point) => Offset(point.dx * size.width, point.dy * size.height))
          .toList();
      if (points.length == 1) {
        canvas.drawCircle(points.first, paint.strokeWidth / 2, paint);
      } else {
        final path = Path()..moveTo(points.first.dx, points.first.dy);
        for (final point in points.skip(1)) {
          path.lineTo(point.dx, point.dy);
        }
        canvas.drawPath(path, paint);
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_AnswerPainter oldDelegate) =>
      !identical(strokes, oldDelegate.strokes);
}
