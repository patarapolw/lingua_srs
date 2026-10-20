import 'package:flutter/material.dart';

import '../models/vocab_item.dart';
import '../models/vocab_merge_record.dart';
import '../providers/app_provider.dart';
import '../services/english_text_search.dart';
import '../services/vocab_ai_service.dart';
import 'similar_meanings_dialog.dart';

Future<SimilarMeaningsChoice?> showEnKoSearch(
  BuildContext context, {
  required AppProvider provider,
  required VocabItem draft,
  String initialHint = '',
}) {
  return showDialog<SimilarMeaningsChoice>(
    context: context,
    builder: (_) => _EnKoSearchDialog(
      groups: provider.vocabGroups,
      draft: draft,
      initialHint: initialHint,
    ),
  );
}

class _EnKoSearchDialog extends StatefulWidget {
  const _EnKoSearchDialog({
    required this.groups,
    required this.draft,
    required this.initialHint,
  });
  final List<VocabGroup> groups;
  final VocabItem draft;
  final String initialHint;

  @override
  State<_EnKoSearchDialog> createState() => _EnKoSearchDialogState();
}

class _EnKoSearchDialogState extends State<_EnKoSearchDialog> {
  late final TextEditingController _query = TextEditingController(
    text: VocabSimilarity.normalizeTranslation(widget.draft.translation),
  );
  late final TextEditingController _hint = TextEditingController(
    text: widget.initialHint,
  );
  final Map<String, TextEditingController> _rowHints = {};
  final Set<String> _checked = {};
  bool _sameType = true;

  @override
  void dispose() {
    _query.dispose();
    _hint.dispose();
    for (final c in _rowHints.values) {
      c.dispose();
    }
    super.dispose();
  }

  bool _canApply(VocabGroup g) =>
      g.entry.cardNativeToTarget.frontHint.trim().isEmpty;

  void _submit() {
    final hint = _hint.text.trim();
    Navigator.pop(
      context,
      SimilarMeaningsChoice(
        targetHint: hint.isEmpty ? null : hint,
        otherHints: {
          for (final id in _checked)
            if ((_rowHints[id]?.text.trim() ?? '').isNotEmpty)
              id: _rowHints[id]!.text.trim(),
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pos = widget.draft.pos.trim();
    final form = VocabSimilarity.normalizeTarget(widget.draft.targetWord);
    final hits =
        EnglishTextSearch.search(
              _query.text,
              widget.groups,
              pos: _sameType && pos.isNotEmpty ? pos : null,
              excludeId: widget.draft.id,
            )
            .where(
              (h) =>
                  VocabSimilarity.normalizeTarget(h.group.entry.targetWord) !=
                  form,
            )
            .toList();

    return AlertDialog(
      title: const Text('Find similar English meanings'),
      content: SizedBox(
        width: 520,
        height: 460,
        child: Column(
          children: [
            TextField(
              controller: _query,
              autofocus: true,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search English meanings',
              ),
              onChanged: (_) => setState(() {}),
            ),
            if (pos.isNotEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: FilterChip(
                  label: Text('Same type only ($pos)'),
                  selected: _sameType,
                  onSelected: (v) => setState(() => _sameType = v),
                ),
              ),
            const SizedBox(height: 4),
            TextField(
              controller: _hint,
              decoration: const InputDecoration(
                labelText: 'Hint for this word',
                hintText: 'e.g. general size',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: hits.isEmpty
                  ? Center(
                      child: Text(
                        _query.text.trim().isEmpty
                            ? 'Type an English word.'
                            : 'No matching vocabulary.',
                      ),
                    )
                  : ListView.builder(
                      itemCount: hits.length,
                      itemBuilder: (_, i) {
                        final g = hits[i].group;
                        final canApply = _canApply(g);
                        final checked = _checked.contains(g.id);
                        return Column(
                          children: [
                            CheckboxListTile(
                              value: checked,
                              onChanged: canApply
                                  ? (v) => setState(
                                      () => v == true
                                          ? _checked.add(g.id)
                                          : _checked.remove(g.id),
                                    )
                                  : null,
                              title: Text(g.label),
                              subtitle: Text(
                                '${g.entry.pos} • ${g.lessonTitles.join(', ')}'
                                '${canApply ? '' : ' • hint: ${g.entry.cardNativeToTarget.frontHint.trim()}'}',
                              ),
                            ),
                            if (checked)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  16,
                                  0,
                                  16,
                                  8,
                                ),
                                child: TextField(
                                  controller: _rowHints.putIfAbsent(
                                    g.id,
                                    () => TextEditingController(),
                                  ),
                                  decoration: InputDecoration(
                                    labelText:
                                        'EN ➔ KO hint for ${g.entry.targetWord}',
                                    border: const OutlineInputBorder(),
                                  ),
                                ),
                              ),
                          ],
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Use selected')),
      ],
    );
  }
}
