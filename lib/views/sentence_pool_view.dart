import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/sentence.dart';
import '../providers/app_provider.dart';
import '../widgets/audio_edit_fields.dart';
import '../widgets/emphasis_text.dart';
import '../widgets/markdown_content.dart';
import '../widgets/markdown_notes_field.dart';

const _emphasisError =
    'Emphasis is set per word. Mark it in the word\'s own editor.';

class SentencePoolView extends StatefulWidget {
  const SentencePoolView({super.key});

  @override
  State<SentencePoolView> createState() => _SentencePoolViewState();
}

class _SentencePoolViewState extends State<SentencePoolView> {
  final TextEditingController _searchCtrl = TextEditingController();
  String _filter = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  /// How many words list [sentence] as an example.
  int _usageCount(AppProvider provider, Sentence sentence) => provider.lessons
      .expand((lesson) => lesson.vocabularies)
      .where((vocab) => vocab.sentenceIds.contains(sentence.id))
      .length;

  void _showAddEditDialog({Sentence? sentence}) {
    final usage = sentence == null
        ? 0
        : _usageCount(context.read<AppProvider>(), sentence);
    final targetCtrl = TextEditingController(
      text: Sentence.stripEmphasis(sentence?.targetText ?? ''),
    );
    final transCtrl = TextEditingController(
      text: Sentence.stripEmphasis(sentence?.translationText ?? ''),
    );
    final audioCtrl = TextEditingController(text: sentence?.audioUrl ?? '');
    final ttsCtrl = TextEditingController(text: sentence?.ttsText ?? '');
    var useAudio = sentence?.useAudio ?? true;
    final notesCtrl = TextEditingController(text: sentence?.notes ?? '');

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          sentence == null ? 'Add Sentence to Pool' : 'Edit Sentence',
        ),
        content: StatefulBuilder(
          builder: (ctx, setDialogState) => SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Plain text: the `**` emphasis belongs to each word that
                // uses the sentence and is edited from that word.
                TextField(
                  controller: targetCtrl,
                  onChanged: (_) => setDialogState(() {}),
                  decoration: InputDecoration(
                    labelText: 'Target Sentence',
                    hintText: 'e.g. 저는 아줌마를 위해 문을 열었어요',
                    errorText: targetCtrl.text.contains('**')
                        ? _emphasisError
                        : null,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: transCtrl,
                  onChanged: (_) => setDialogState(() {}),
                  decoration: InputDecoration(
                    labelText: 'Translation',
                    hintText: 'e.g. I opened the door for an older lady',
                    errorText: transCtrl.text.contains('**')
                        ? _emphasisError
                        : null,
                  ),
                ),
                if (usage > 0) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Used by $usage ${usage == 1 ? 'word' : 'words'}. '
                    'Changing the text changes it for all of them.',
                    style: Theme.of(ctx).textTheme.bodySmall
                        ?.copyWith(color: Theme.of(ctx).colorScheme.error),
                  ),
                ],
                const SizedBox(height: 12),
                AudioEditFields(
                  audioUrl: audioCtrl,
                  audioUrlLabel: 'Audio URL (Optional)',
                  useAudio: useAudio,
                  onUseAudioChanged: (value) =>
                      setDialogState(() => useAudio = value),
                  ttsText: ttsCtrl,
                  spokenFallback: targetCtrl,
                ),
                const SizedBox(height: 8),
                MarkdownNotesField(
                  label: 'Sentence notes',
                  addLabel: 'Add sentence note',
                  controller: notesCtrl,
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              if (targetCtrl.text.contains('**') ||
                  transCtrl.text.contains('**')) {
                return;
              }
              if (targetCtrl.text.trim().isNotEmpty) {
                final provider = context.read<AppProvider>();
                if (sentence == null) {
                  final newSentence = Sentence(
                    targetText: targetCtrl.text.trim(),
                    translationText: transCtrl.text.trim(),
                    audioUrl: audioCtrl.text.trim().isEmpty
                        ? null
                        : audioCtrl.text.trim(),
                    useAudio: useAudio,
                    ttsText: ttsCtrl.text.trim().isEmpty
                        ? null
                        : ttsCtrl.text.trim(),
                    notes: notesCtrl.text.trim(),
                  );
                  await provider.addSentenceToPool(newSentence);
                } else {
                  sentence.targetText = targetCtrl.text.trim();
                  sentence.translationText = transCtrl.text.trim();
                  sentence.audioUrl = audioCtrl.text.trim().isEmpty
                      ? null
                      : audioCtrl.text.trim();
                  sentence.useAudio = useAudio;
                  sentence.ttsText = ttsCtrl.text.trim().isEmpty
                      ? null
                      : ttsCtrl.text.trim();
                  sentence.notes = notesCtrl.text.trim();
                  await provider.updateSentenceInPool(sentence);
                }
                if (!ctx.mounted) return;
                Navigator.pop(ctx);
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    ).whenComplete(() {
      // The route's exit animation still rebuilds the fields after the future
      // completes, so the controllers must outlive it.
      Future<void>.delayed(const Duration(seconds: 1), () {
        targetCtrl.dispose();
        transCtrl.dispose();
        audioCtrl.dispose();
        ttsCtrl.dispose();
        notesCtrl.dispose();
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppProvider>();
    final theme = Theme.of(context);

    final filtered = provider.sentences.where((s) {
      if (_filter.isEmpty) return true;
      final query = _filter.toLowerCase();
      return s.targetText.toLowerCase().contains(query) ||
          s.translationText.toLowerCase().contains(query) ||
          s.notes.toLowerCase().contains(query);
    }).toList();

    // On a narrow screen the search box takes the whole width, so its hint is
    // never cut, and the count becomes a caption line under it.
    final count = provider.sentences.length;
    final countLabel = '$count ${count == 1 ? 'sentence' : 'sentences'}';
    final narrow = MediaQuery.sizeOf(context).width < 700;
    final searchField = TextField(
      controller: _searchCtrl,
      decoration: InputDecoration(
        prefixIcon: const Icon(Icons.search),
        hintText: 'Search sentences',
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 10,
        ),
        suffixIcon: _filter.isNotEmpty
            ? IconButton(
                icon: const Icon(Icons.clear),
                tooltip: 'Clear search',
                onPressed: () {
                  _searchCtrl.clear();
                  setState(() => _filter = '');
                },
              )
            : null,
      ),
      onChanged: (val) => setState(() => _filter = val.trim()),
    );
    final countChip = Chip(
      avatar: const Icon(Icons.format_quote_rounded, size: 18),
      label: Text(countLabel),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Sentence Pool'),
        actions: [
          if (MediaQuery.sizeOf(context).width < 700)
            IconButton(
              icon: const Icon(Icons.add_comment_outlined),
              tooltip: 'Add Sentence',
              onPressed: () => _showAddEditDialog(),
            )
          else
            FilledButton.icon(
              icon: const Icon(Icons.add),
              label: const Text('Add Sentence'),
              onPressed: () => _showAddEditDialog(),
            ),
          SizedBox(width: MediaQuery.sizeOf(context).width < 700 ? 8 : 16),
        ],
      ),
      body: Column(
        children: [
          // Search & stats header
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: narrow
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      searchField,
                      Padding(
                        padding: const EdgeInsets.only(top: 6, left: 4),
                        child: Text(
                          countLabel,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.outline,
                          ),
                        ),
                      ),
                    ],
                  )
                : Row(
                    children: [
                      Expanded(child: searchField),
                      const SizedBox(width: 16),
                      countChip,
                    ],
                  ),
          ),
          const Divider(),

          // Sentence List
          Expanded(
            child: filtered.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.format_quote_outlined,
                          size: 64,
                          color: theme.colorScheme.outline,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          _filter.isEmpty
                              ? 'The Sentence Pool is currently empty.'
                              : 'No sentences matched your query.',
                          style: theme.textTheme.titleMedium,
                        ),
                        const SizedBox(height: 12),
                        if (_filter.isEmpty)
                          FilledButton.tonal(
                            onPressed: () => _showAddEditDialog(),
                            child: const Text('Add the first sentence'),
                          ),
                      ],
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    itemCount: filtered.length,
                    separatorBuilder: (context, index) =>
                        const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final item = filtered[index];

                      final vocabUsageCount = _usageCount(provider, item);

                      return Card(
                        elevation: 1,
                        clipBehavior: Clip.antiAlias,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: InkWell(
                          onTap: () => _showAddEditDialog(sentence: item),
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                EmphasisText(
                                  item.targetText,
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                EmphasisText(
                                  item.translationText,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                                if (item.notes.trim().isNotEmpty) ...[
                                  const SizedBox(height: 8),
                                  DecoratedBox(
                                    decoration: BoxDecoration(
                                      color: theme
                                          .colorScheme
                                          .secondaryContainer
                                          .withValues(alpha: 0.3),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Padding(
                                      padding: const EdgeInsets.all(10),
                                      child: MarkdownContent(
                                        content: item.notes,
                                        style: theme.textTheme.bodySmall,
                                      ),
                                    ),
                                  ),
                                ],
                                const SizedBox(height: 8),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 4,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    Badge(
                                      label: Text('$vocabUsageCount vocabs'),
                                      backgroundColor:
                                          theme.colorScheme.secondaryContainer,
                                      textColor: theme
                                          .colorScheme
                                          .onSecondaryContainer,
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
