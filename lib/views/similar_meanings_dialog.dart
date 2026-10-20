import 'package:flutter/material.dart';

import '../models/vocab_merge_record.dart';
import '../models/srs_card.dart';
import '../models/vocab_item.dart';
import '../providers/app_provider.dart';
import '../services/vocab_ai_service.dart';

class SimilarMeaningsChoice {
  const SimilarMeaningsChoice({this.targetHint, this.otherHints = const {}});
  final String? targetHint;
  final Map<String, String> otherHints; // vocab id -> hint
}

Future<SimilarMeaningsChoice?> showSimilarMeanings(
  BuildContext context, {
  required AppProvider provider,
  required SimilarMeaningResult result,
  required CardDirection direction,
}) {
  final byId = {for (final g in provider.vocabGroups) g.id: g};
  return showDialog<SimilarMeaningsChoice>(
    context: context,
    builder: (_) => _SimilarMeaningsDialog(result: result, byId: byId, direction: direction),
  );
}

class _SimilarMeaningsDialog extends StatefulWidget {
  const _SimilarMeaningsDialog({required this.result, required this.byId, required this.direction});
  final SimilarMeaningResult result;
  final Map<String, VocabGroup> byId;
  final CardDirection direction;

  @override
  State<_SimilarMeaningsDialog> createState() => _SimilarMeaningsDialogState();
}

class _SimilarMeaningsDialogState extends State<_SimilarMeaningsDialog> {
  late bool _useTarget = widget.result.hint.isNotEmpty;
  late final Set<String> _checked = {
    for (final s in widget.result.similar)
      if (_canApply(s)) s.id,
  };

  String _currentHint(VocabItem v) => (widget.direction == CardDirection.targetToNative
          ? v.cardTargetToNative
          : v.cardNativeToTarget)
      .frontHint;

  bool _canApply(SimilarVocabHint s) =>
      s.hint.isNotEmpty &&
      (widget.byId[s.id] != null && _currentHint(widget.byId[s.id]!.entry).trim().isEmpty);

  @override
  Widget build(BuildContext context) {
    final result = widget.result;
    final nothing = result.hint.isEmpty && result.similar.isEmpty;
    return AlertDialog(
      title: Text(
          widget.direction == CardDirection.targetToNative
            ? 'KO ➔ EN: same Korean, different meaning'
            : 'EN ➔ KO: similar meanings'
        ),
      content: SizedBox(
        width: 520,
        child: nothing
            ? Text(
              widget.direction == CardDirection.targetToNative
                ? 'No other vocabulary shares this Korean spelling.'
                : 'No confusable vocabulary found among words of the same type.'
              )
            : ListView(
                shrinkWrap: true,
                children: [
                  if (result.hint.isNotEmpty)
                    CheckboxListTile(
                      value: _useTarget,
                      onChanged: (v) => setState(() => _useTarget = v ?? false),
                      title: Text('Hint for this word: ${result.hint}'),
                    ),
                  if (result.similar.isNotEmpty) ...[
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Text('Easy to confuse with (hints are applied only to words without one):'),
                    ),
                    for (final s in result.similar)
                      CheckboxListTile(
                        value: _checked.contains(s.id),
                        onChanged: _canApply(s)
                            ? (v) => setState(() => v == true ? _checked.add(s.id) : _checked.remove(s.id))
                            : null,
                        title: Text(widget.byId[s.id]?.label ?? s.id),
                        subtitle: Text(
                          _canApply(s)
                              ? 'Hint: ${s.hint}'
                              : s.hint.isEmpty
                                  ? 'No hint suggested'
                                  : 'Already has hint: ${_currentHint(widget.byId[s.id]!.entry)}',
                        ),
                      ),
                  ],
                ],
              ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        if (!nothing)
          FilledButton(
            onPressed: () => Navigator.pop(
              context,
              SimilarMeaningsChoice(
                targetHint: _useTarget ? result.hint : null,
                otherHints: {
                  for (final s in result.similar)
                    if (_checked.contains(s.id)) s.id: s.hint,
                },
              ),
            ),
            child: const Text('Use selected'),
          ),
      ],
    );
  }
}