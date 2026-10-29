import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/sentence.dart';
import '../providers/app_provider.dart';
import '../widgets/audio_button.dart';
import '../widgets/emphasis_text.dart';
import '../widgets/markdown_content.dart';
import '../widgets/markdown_text_field.dart';

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

  void _showAddEditDialog({Sentence? sentence}) {
    final targetCtrl = TextEditingController(text: sentence?.targetText ?? '');
    final transCtrl = TextEditingController(
      text: sentence?.translationText ?? '',
    );
    final audioCtrl = TextEditingController(text: sentence?.audioUrl ?? '');
    final notesCtrl = TextEditingController(text: sentence?.notes ?? '');

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          sentence == null ? 'Add Sentence to Pool' : 'Edit Sentence',
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: targetCtrl,
                decoration: const InputDecoration(
                  labelText: 'Target Sentence (Markdown)',
                  hintText: 'e.g. 저는 **아줌마**를 위해 문을 열었어요',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: transCtrl,
                decoration: const InputDecoration(
                  labelText: 'Translation Sentence',
                  hintText: 'e.g. I opened the door for **an older lady**',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: audioCtrl,
                decoration: const InputDecoration(
                  labelText: 'Audio URL (Optional)',
                ),
              ),
              const SizedBox(height: 12),
              MarkdownTextField(
                controller: notesCtrl,
                minLines: 2,
                maxLines: 5,
                decoration: const InputDecoration(
                  labelText: 'Sentence Notes (Markdown)',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              if (targetCtrl.text.trim().isNotEmpty) {
                final provider = context.read<AppProvider>();
                if (sentence == null) {
                  final newSentence = Sentence(
                    targetText: targetCtrl.text.trim(),
                    translationText: transCtrl.text.trim(),
                    audioUrl: audioCtrl.text.trim().isEmpty
                        ? null
                        : audioCtrl.text.trim(),
                    notes: notesCtrl.text.trim(),
                  );
                  await provider.addSentenceToPool(newSentence);
                } else {
                  sentence.targetText = targetCtrl.text.trim();
                  sentence.translationText = transCtrl.text.trim();
                  sentence.audioUrl = audioCtrl.text.trim().isEmpty
                      ? null
                      : audioCtrl.text.trim();
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
      targetCtrl.dispose();
      transCtrl.dispose();
      audioCtrl.dispose();
      notesCtrl.dispose();
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

    // On a narrow screen the count goes under the search box, so the box
    // keeps room for its whole hint.
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
      label: Text('${provider.sentences.length} sentences'),
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
                      const SizedBox(height: 8),
                      countChip,
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

                      // Calculate how many vocabs use this sentence
                      int vocabUsageCount = 0;
                      for (final lesson in provider.lessons) {
                        for (final v in lesson.vocabularies) {
                          if (v.sentenceIds.contains(item.id)) {
                            vocabUsageCount++;
                          }
                        }
                      }

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
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(
                                      child: EmphasisText(
                                        item.targetText,
                                        style: theme.textTheme.titleMedium
                                            ?.copyWith(
                                              fontWeight: FontWeight.w600,
                                            ),
                                      ),
                                    ),
                                    AudioButton(
                                      audioUrl: item.audioUrl,
                                      fallbackText: item.speechText,
                                      compact: true,
                                    ),
                                    IconButton(
                                      icon: const Icon(
                                        Icons.edit_outlined,
                                        size: 20,
                                      ),
                                      tooltip: 'Edit Sentence',
                                      onPressed: () =>
                                          _showAddEditDialog(sentence: item),
                                    ),
                                  ],
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
                                    Text(
                                      'Cloze Preview: ${item.toCloze()}',
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                            fontStyle: FontStyle.italic,
                                            color: theme.colorScheme.outline,
                                          ),
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
