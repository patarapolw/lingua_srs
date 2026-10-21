import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/app_provider.dart';

/// Romanization / IPA toggles for vocabulary and for sentences, for the review
/// screen. Wraps onto two lines on narrow phones.
class PronunciationToggles extends StatelessWidget {
  const PronunciationToggles({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppProvider>();
    final labelStyle = Theme.of(context).textTheme.labelMedium;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 16,
        runSpacing: 8,
        children: [
          for (final target in PronunciationTarget.values)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(target.label, style: labelStyle),
                const SizedBox(width: 8),
                ToggleButtons(
                  isSelected: [
                    provider.showRomanization(target),
                    provider.showIpa(target),
                  ],
                  onPressed: (index) => index == 0
                      ? provider.toggleRomanization(target)
                      : provider.toggleIpa(target),
                  borderRadius: BorderRadius.circular(8),
                  constraints: const BoxConstraints(
                    minHeight: 40,
                    minWidth: 56,
                  ),
                  children: [
                    Text(
                      'Rom',
                      key: ValueKey(
                        'pronunciation-${target.name}-romanization',
                      ),
                    ),
                    Text(
                      'IPA',
                      key: ValueKey('pronunciation-${target.name}-ipa'),
                    ),
                  ],
                ),
              ],
            ),
        ],
      ),
    );
  }
}
