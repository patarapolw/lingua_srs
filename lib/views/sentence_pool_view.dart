import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/sentence.dart';
import '../providers/app_provider.dart';
import '../widgets/audio_button.dart';
import '../widgets/markdown_content.dart';

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
    final transCtrl = TextEditingController(text: sentence?.translationText ?? '');
    final audioCtrl = TextEditingController(text: sentence?.audioUrl ?? '');

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(sentence == null ? 'Add Sentence to Pool' : 'Edit Sentence'),
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
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              if (targetCtrl.text.trim().isNotEmpty) {
                final provider = context.read<AppProvider>();
                if (sentence == null) {
                  final newSentence = Sentence(
                    targetText: targetCtrl.text.trim(),
                    translationText: transCtrl.text.trim(),
                    audioUrl: audioCtrl.text.trim().isEmpty ? null : audioCtrl.text.trim(),
                  );
                  provider.addSentenceToPool(newSentence);
                } else {
                  sentence.targetText = targetCtrl.text.trim();
                  sentence.translationText = transCtrl.text.trim();
                  sentence.audioUrl = audioCtrl.text.trim().isEmpty ? null : audioCtrl.text.trim();
                  provider.saveState();
                }
                Navigator.pop(ctx);
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppProvider>();
    final theme = Theme.of(context);

    final filtered = provider.sentences.where((s) {
      if (_filter.isEmpty) return true;
      final query = _filter.toLowerCase();
      return s.targetText.toLowerCase().contains(query) ||
          s.translationText.toLowerCase().contains(query);
    }).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Sentence Pool'),
        actions: [
          FilledButton.icon(
            icon: const Icon(Icons.add),
            label: const Text('Add Sentence'),
            onPressed: () => _showAddEditDialog(),
          ),
          const SizedBox(width: 16),
        ],
      ),
      body: Column(
        children: [
          // Search & stats header
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchCtrl,
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search),
                      hintText: 'Search sentences by target or translation...',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
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
                  ),
                ),
                const SizedBox(width: 16),
                Chip(
                  avatar: const Icon(Icons.format_quote_rounded, size: 18),
                  label: Text('${provider.sentences.length} Total Sentences'),
                ),
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
                        Icon(Icons.format_quote_outlined, size: 64, color: theme.colorScheme.outline),
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
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    itemCount: filtered.length,
                    separatorBuilder: (context, index) => const SizedBox(height: 8),
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
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    child: MarkdownContent(
                                      content: item.targetText,
                                      style: theme.textTheme.titleMedium?.copyWith(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  AudioButton(
                                    audioUrl: item.audioUrl,
                                    fallbackText: item.targetText,
                                    compact: true,
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.edit_outlined, size: 20),
                                    tooltip: 'Edit Sentence',
                                    onPressed: () => _showAddEditDialog(sentence: item),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Text(
                                item.translationText,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  Badge(
                                    label: Text('$vocabUsageCount vocabs'),
                                    backgroundColor: theme.colorScheme.secondaryContainer,
                                    textColor: theme.colorScheme.onSecondaryContainer,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    'Cloze Preview: ${item.toCloze()}',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      fontStyle: FontStyle.italic,
                                      color: theme.colorScheme.outline,
                                    ),
                                  ),
                                ],
                              ),
                            ],
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
