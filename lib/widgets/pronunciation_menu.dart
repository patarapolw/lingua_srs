import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/app_provider.dart';

const _prefix = 'pron:';

/// Four checkable entries: romanization and IPA for vocabulary, then for
/// sentences. Shared by the toolbar button and the narrow-screen "More" menu.
List<PopupMenuEntry<String>> pronunciationMenuEntries(AppProvider provider) => [
  for (final target in PronunciationTarget.values) ...[
    if (target.index > 0) const PopupMenuDivider(),
    CheckedPopupMenuItem<String>(
      value: '$_prefix${target.name}:romanization',
      checked: provider.showRomanization(target),
      child: Text('${target.label} romanization'),
    ),
    CheckedPopupMenuItem<String>(
      value: '$_prefix${target.name}:ipa',
      checked: provider.showIpa(target),
      child: Text('${target.label} IPA'),
    ),
  ],
];

/// Applies a value produced by [pronunciationMenuEntries]. Returns false when
/// [value] is not a pronunciation entry.
bool handlePronunciationSelection(AppProvider provider, String value) {
  if (!value.startsWith(_prefix)) return false;
  final parts = value.substring(_prefix.length).split(':');
  final target = PronunciationTarget.values.byName(parts[0]);
  if (parts[1] == 'ipa') {
    provider.toggleIpa(target);
  } else {
    provider.toggleRomanization(target);
  }
  return true;
}

/// Review-toolbar button for the wide layout.
class PronunciationMenuButton extends StatelessWidget {
  const PronunciationMenuButton({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppProvider>();
    return PopupMenuButton<String>(
      tooltip: 'Romanization / IPA',
      icon: const Icon(Icons.translate),
      onSelected: (value) => handlePronunciationSelection(provider, value),
      itemBuilder: (_) => pronunciationMenuEntries(provider),
    );
  }
}
