import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/vocab_item.dart';
import '../models/vocab_merge_record.dart';
import '../providers/app_provider.dart';
import '../services/vocab_ai_service.dart';

void showMergeUndoSnackBar(
  ScaffoldMessengerState messenger,
  AppProvider provider,
  List<VocabMergeRecord> records, {
  String? text,
}) {
  if (records.isEmpty) return;
  messenger.showSnackBar(
    SnackBar(
      content: Text(text ?? 'Merged ${records.first.label}'),
      duration: const Duration(seconds: 10),
      action: SnackBarAction(
        label: 'Undo',
        onPressed: () async {
          for (final record in records.reversed) {
            await provider.undoMerge(record.id);
          }
        },
      ),
    ),
  );
}

/// Manual flow: pick the other vocabulary, read the warning, confirm.
Future<void> startManualMerge(BuildContext context, VocabItem vocab) async {
  final provider = context.read<AppProvider>();
  final messenger = ScaffoldMessenger.of(context);
  final groups = provider.vocabGroups;
  final current = groups.firstWhere((g) => g.id == vocab.id);

  final other = await showDialog<VocabGroup>(
    context: context,
    builder: (_) => _PickerDialog(current: current, groups: groups),
  );
  if (other == null || !context.mounted) return;

  final survivorId = await showDialog<String>(
    context: context,
    builder: (_) => _ConfirmMergeDialog(a: current, b: other),
  );
  if (survivorId == null) return;

  final absorbedId = survivorId == current.id ? other.id : current.id;
  final record = await provider.mergeVocab(
    survivorId: survivorId,
    absorbedIds: [absorbedId],
  );
  if (record != null) showMergeUndoSnackBar(messenger, provider, [record]);
}

class _PickerDialog extends StatefulWidget {
  const _PickerDialog({required this.current, required this.groups});
  final VocabGroup current;
  final List<VocabGroup> groups;

  @override
  State<_PickerDialog> createState() => _PickerDialogState();
}

class _PickerDialogState extends State<_PickerDialog> {
  String _query = '';

  int _rank(VocabGroup g) {
    final c = widget.current.entry;
    if (VocabSimilarity.normalizeTarget(g.entry.targetWord) ==
        VocabSimilarity.normalizeTarget(c.targetWord)) {
      return 0;
    }
    if (VocabSimilarity.normalizeTranslation(g.entry.translation) ==
        VocabSimilarity.normalizeTranslation(c.translation)) {
      return 1;
    }
    return 2;
  }

  @override
  Widget build(BuildContext context) {
    final q = _query.toLowerCase();
    final options = widget.groups
        .where((g) => g.id != widget.current.id)
        .where((g) => q.isEmpty || g.label.toLowerCase().contains(q))
        .toList()
      ..sort((a, b) {
        final byRank = _rank(a).compareTo(_rank(b));
        return byRank != 0 ? byRank : a.label.compareTo(b.label);
      });
    return AlertDialog(
      title: Text('Merge "${widget.current.label}" with…'),
      content: SizedBox(
        width: 480,
        height: 420,
        child: Column(
          children: [
            TextField(
              autofocus: true,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search vocabulary',
              ),
              onChanged: (v) => setState(() => _query = v.trim()),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: options.length,
                itemBuilder: (_, i) {
                  final g = options[i];
                  return ListTile(
                    title: Text(g.label),
                    subtitle: Text(
                      '${g.entry.pos} • ${g.lessonTitles.join(', ')} • ${g.reviews} reviews',
                    ),
                    onTap: () => Navigator.pop(context, g),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      ],
    );
  }
}

class _ConfirmMergeDialog extends StatefulWidget {
  const _ConfirmMergeDialog({required this.a, required this.b});
  final VocabGroup a;
  final VocabGroup b;

  @override
  State<_ConfirmMergeDialog> createState() => _ConfirmMergeDialogState();
}

class _ConfirmMergeDialogState extends State<_ConfirmMergeDialog> {
  late String _survivorId =
      widget.b.reviews > widget.a.reviews ? widget.b.id : widget.a.id;
  bool _understood = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget option(VocabGroup g) => RadioListTile<String>(
      value: g.id,
      groupValue: _survivorId,
      onChanged: (v) => setState(() => _survivorId = v!),
      title: Text('Keep progress of ${g.label}'),
      subtitle: Text('${g.reviews} reviews • ${g.lessonTitles.join(', ')}'),
    );
    return AlertDialog(
      icon: Icon(Icons.warning_amber_rounded, color: theme.colorScheme.error),
      title: const Text('Merge these vocabularies?'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'They become one vocabulary in every lesson: shared SRS progress, '
              'audio, notes and front hint. Each lesson keeps its own wording.',
            ),
            const SizedBox(height: 8),
            option(widget.a),
            option(widget.b),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _understood,
              onChanged: (v) => setState(() => _understood = v ?? false),
              title: const Text(
                'I understand the other one’s SRS progress will be discarded '
                '(Undo brings it back).',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: theme.colorScheme.error),
          onPressed: _understood ? () => Navigator.pop(context, _survivorId) : null,
          child: const Text('Merge'),
        ),
      ],
    );
  }
}

Future<void> showAiMergeSuggestions(BuildContext context) =>
    showDialog(context: context, builder: (_) => const _AiMergeDialog());

class _AiMergeDialog extends StatefulWidget {
  const _AiMergeDialog();
  @override
  State<_AiMergeDialog> createState() => _AiMergeDialogState();
}

class _AiMergeDialogState extends State<_AiMergeDialog> {
  List<VocabMergeSuggestion>? _suggestions;
  final _selected = <int>{};
  String? _error;
  bool _merging = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  Future<void> _load() async {
    final provider = context.read<AppProvider>();
    setState(() {
      _suggestions = null;
      _error = null;
      _selected.clear();
    });
    try {
      final result = await provider.suggestVocabMerges();
      if (mounted) setState(() => _suggestions = result);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  Future<void> _mergeSelected() async {
    final provider = context.read<AppProvider>();
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final chosen = [for (final i in _selected.toList()..sort()) _suggestions![i]];
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(Icons.warning_amber_rounded, color: Theme.of(ctx).colorScheme.error),
        title: Text('Merge ${chosen.length} vocabulary group(s)?'),
        content: const Text(
          'Merged words share SRS progress, audio, notes and hint. The progress '
          'of the entries merged away is discarded. You can undo from the merge '
          'history.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Merge ${chosen.length}'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _merging = true);
    final records = <VocabMergeRecord>[];
    for (final s in chosen) {
      final record = await provider.mergeVocab(
        survivorId: s.keepId,
        absorbedIds: s.mergeIds,
        source: 'ai',
        reason: s.reason,
      );
      if (record != null) records.add(record);
    }
    navigator.pop();
    showMergeUndoSnackBar(messenger, provider, records, text: 'Merged ${records.length} group(s).');
  }

  @override
  Widget build(BuildContext context) {
    final byId = {for (final g in context.read<AppProvider>().vocabGroups) g.id: g};
    String label(String id) => byId[id]?.label ?? id;
    final suggestions = _suggestions;

    Widget body;
    if (_error != null) {
      body = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          TextButton(onPressed: _load, child: const Text('Retry')),
        ],
      );
    } else if (suggestions == null) {
      body = const Center(child: CircularProgressIndicator());
    } else if (suggestions.isEmpty) {
      body = const Center(child: Text('No duplicate vocabulary found.'));
    } else {
      body = ListView.builder(
        itemCount: suggestions.length,
        itemBuilder: (_, i) {
          final s = suggestions[i];
          return CheckboxListTile(
            value: _selected.contains(i),
            onChanged: _merging
                ? null
                : (v) => setState(() => v == true ? _selected.add(i) : _selected.remove(i)),
            title: Text('Keep ${label(s.keepId)}'),
            subtitle: Text(
              'Merge: ${s.mergeIds.map(label).join('; ')}'
              '${s.reason.isEmpty ? '' : '\n${s.reason}'}',
            ),
          );
        },
      );
    }

    return AlertDialog(
      title: const Text('AI merge suggestions'),
      content: SizedBox(width: 520, height: 420, child: body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        FilledButton(
          onPressed: _selected.isEmpty || _merging ? null : _mergeSelected,
          child: Text('Merge selected (${_selected.length})'),
        ),
      ],
    );
  }
}

Future<void> showMergeHistory(BuildContext context) =>
    showDialog(context: context, builder: (_) => const _HistoryDialog());

class _HistoryDialog extends StatelessWidget {
  const _HistoryDialog();

  static String _ago(DateTime time) {
    final d = DateTime.now().difference(time);
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes} min ago';
    if (d.inDays < 1) return '${d.inHours} h ago';
    return '${d.inDays} d ago';
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppProvider>(
      builder: (context, provider, _) {
        final history = provider.mergeHistory;
        return AlertDialog(
          title: const Text('Merge history'),
          content: SizedBox(
            width: 520,
            height: 360,
            child: history.isEmpty
                ? const Center(child: Text('Nothing to undo.'))
                : ListView.builder(
                    itemCount: history.length,
                    itemBuilder: (_, i) {
                      final r = history[i];
                      return ListTile(
                        title: Text(r.label),
                        subtitle: Text(
                          '${_ago(r.createdAt)} • ${r.source == 'ai' ? 'AI suggested' : 'manual'}'
                          '${i == 0 ? '' : ' • undo newer merges first'}',
                        ),
                        trailing: TextButton(
                          onPressed: i != 0
                              ? null
                              : () async {
                                  final messenger = ScaffoldMessenger.of(context);
                                  final result = await provider.undoMerge(r.id);
                                  messenger.showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        result.missing == 0
                                            ? 'Merge undone.'
                                            : 'Restored ${result.restored}; '
                                                  '${result.missing} entries were deleted or changed.',
                                      ),
                                    ),
                                  );
                                },
                          child: const Text('Undo'),
                        ),
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
          ],
        );
      },
    );
  }
}