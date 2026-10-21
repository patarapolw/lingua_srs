import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/app_provider.dart';

/// Popup-menu entry holding the pronunciation toggles. Tapping a toggle does
/// not close the menu, so several can be flipped in one visit.
class PronunciationToggleMenuEntry extends PopupMenuEntry<String> {
  const PronunciationToggleMenuEntry({super.key, required this.enabled});

  final bool enabled;

  @override
  double get height => 120;

  @override
  bool represents(String? value) => false;

  @override
  State<PronunciationToggleMenuEntry> createState() =>
      _PronunciationToggleMenuEntryState();
}

class _PronunciationToggleMenuEntryState
    extends State<PronunciationToggleMenuEntry> {
  @override
  Widget build(BuildContext context) {
    return PronunciationToggles(enabled: widget.enabled);
  }
}

/// One row per target: label plus [RR] [IPA] toggle buttons.
class PronunciationToggles extends StatelessWidget {
  const PronunciationToggles({super.key, required this.enabled});

  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppProvider>();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Pronunciation',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          for (final target in PronunciationTarget.values) ...[
            if (target.index > 0) const SizedBox(height: 8),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 84,
                  child: Text(target.label, style: theme.textTheme.labelMedium),
                ),
                ToggleButtons(
                  isSelected: [
                    provider.showRomanization(target),
                    provider.showIpa(target),
                  ],
                  onPressed: enabled
                      ? (index) => index == 0
                            ? provider.toggleRomanization(target)
                            : provider.toggleIpa(target)
                      : null,
                  borderRadius: BorderRadius.circular(8),
                  constraints: const BoxConstraints(
                    minHeight: 36,
                    minWidth: 52,
                  ),
                  children: [
                    Tooltip(
                      message: 'Revised Romanization',
                      child: Text(
                        'RR',
                        key: ValueKey(
                          'pronunciation-${target.name}-romanization',
                        ),
                      ),
                    ),
                    Tooltip(
                      message: 'International Phonetic Alphabet',
                      child: Text(
                        'IPA',
                        key: ValueKey('pronunciation-${target.name}-ipa'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
