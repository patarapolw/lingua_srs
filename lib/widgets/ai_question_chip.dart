import 'package:material_ui/material_ui.dart';

/// A suggested question chip.
///
/// It looks like an outlined chip, but a long question breaks onto more lines
/// instead of being cut off at the edge of the screen, which is what the label
/// of a Material chip does: it is kept on one line. The lines of a long
/// question are centered.
///
/// A question the learner typed before can be removed, so that it is not
/// offered again: with [onRemove], the chip has a remove button after it.
class AiQuestionChip extends StatelessWidget {
  final String label;

  /// Handles tapping the question. The chip is disabled without it.
  final VoidCallback? onPressed;

  /// Removes the question. Without it there is no remove button.
  final VoidCallback? onRemove;

  /// The remove button's tooltip.
  static const removeTooltip = 'Stop suggesting this question';

  const AiQuestionChip({
    super.key,
    required this.label,
    this.onPressed,
    this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final enabled = onPressed != null;
    final question = InkWell(
      onTap: onPressed,
      child: Padding(
        padding: EdgeInsets.fromLTRB(12, 6, onRemove == null ? 12 : 6, 6),
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
    );
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
        child: onRemove == null
            ? question
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(child: question),
                  Tooltip(
                    message: removeTooltip,
                    child: InkWell(
                      onTap: onRemove,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(0, 6, 8, 6),
                        child: Icon(
                          Icons.close,
                          size: 16,
                          semanticLabel: removeTooltip,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
