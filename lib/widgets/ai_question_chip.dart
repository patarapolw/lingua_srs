import 'package:flutter/material.dart';

/// A suggested question chip.
///
/// It looks like an outlined chip, but a long question breaks onto more lines
/// instead of being cut off at the edge of the screen, which is what the label
/// of a Material chip does: it is kept on one line. The lines of a long
/// question are centered.
class AiQuestionChip extends StatelessWidget {
  final String label;

  /// Handles tapping the question. The chip is disabled without it.
  final VoidCallback? onPressed;

  const AiQuestionChip({super.key, required this.label, this.onPressed});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final enabled = onPressed != null;
    return Semantics(
      button: true,
      enabled: enabled,
      child: Material(
        color: Colors.transparent,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(
            color: enabled
                ? colors.outlineVariant
                : colors.onSurface.withValues(alpha: 0.12),
          ),
        ),
        child: InkWell(
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: theme.textTheme.labelLarge?.copyWith(
                color: enabled
                    ? colors.onSurfaceVariant
                    : colors.onSurface.withValues(alpha: 0.38),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
