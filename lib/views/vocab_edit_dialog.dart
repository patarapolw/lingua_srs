import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../models/vocab_item.dart';
import '../models/sentence.dart';
import '../providers/app_provider.dart';
import '../services/korean_text_search.dart';
import '../widgets/audio_button.dart';
import '../widgets/markdown_content.dart';

class VocabEditDialog extends StatefulWidget {
  final VocabItem vocab;
  final String? lessonId;

  const VocabEditDialog({super.key, required this.vocab, this.lessonId});

  static Future<void> show(
    BuildContext context,
    VocabItem vocab, {
    String? lessonId,
  }) {
    return showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => VocabEditDialog(vocab: vocab, lessonId: lessonId),
    );
  }

  @override
  State<VocabEditDialog> createState() => _VocabEditDialogState();
}

class _VocabEditDialogState extends State<VocabEditDialog>
    with SingleTickerProviderStateMixin {
  late TextEditingController _targetWordCtrl;
  late TextEditingController _translationCtrl;
  late TextEditingController _posCtrl;
  late TextEditingController _audioCtrl;
  late TextEditingController _notesCtrl;
  late TextEditingController _idCtrl;
  late String _originalId;

  late bool _enableTargetToNative;
  late bool _enableNativeToTarget;
  late List<String> _sentenceIds;

  bool _showNotesPreview = false;

  @override
  void initState() {
    super.initState();
    _targetWordCtrl = TextEditingController(text: widget.vocab.targetWord);
    _translationCtrl = TextEditingController(text: widget.vocab.translation);
    _posCtrl = TextEditingController(text: widget.vocab.pos);
    _audioCtrl = TextEditingController(text: widget.vocab.audioUrl ?? '');
    _notesCtrl = TextEditingController(text: widget.vocab.notes);
    _originalId = widget.vocab.id;
    _idCtrl = TextEditingController(
      text: widget.vocab.idIsExplicit ? widget.vocab.id : '',
    );

    _enableTargetToNative = widget.vocab.cardTargetToNative.isEnabled;
    _enableNativeToTarget = widget.vocab.cardNativeToTarget.isEnabled;
    _sentenceIds = List<String>.from(widget.vocab.sentenceIds);
  }

  @override
  void dispose() {
    _targetWordCtrl.dispose();
    _translationCtrl.dispose();
    _posCtrl.dispose();
    _audioCtrl.dispose();
    _notesCtrl.dispose();
    _idCtrl.dispose();
    super.dispose();
  }

  void _save() {
    final provider = context.read<AppProvider>();
    widget.vocab.targetWord = _targetWordCtrl.text.trim();
    widget.vocab.translation = _translationCtrl.text.trim();
    widget.vocab.pos = _posCtrl.text.trim();
    widget.vocab.audioUrl = _audioCtrl.text.trim().isEmpty
        ? null
        : _audioCtrl.text.trim();
    widget.vocab.notes = _notesCtrl.text.trim();
    final explicitId = _idCtrl.text.trim();
    if (explicitId.isNotEmpty) {
      widget.vocab
        ..id = explicitId
        ..idIsExplicit = true;
    } else if (widget.vocab.idIsExplicit) {
      widget.vocab
        ..id = const Uuid().v4()
        ..idIsExplicit = false;
    }
    widget.vocab.sentenceIds = _sentenceIds;

    widget.vocab.cardTargetToNative.isEnabled = _enableTargetToNative;
    widget.vocab.cardNativeToTarget.isEnabled = _enableNativeToTarget;

    provider.updateVocab(widget.vocab, previousId: _originalId);
    Navigator.of(context).pop();
  }

  void _openSentencePicker() {
    final provider = context.read<AppProvider>();
    final searchCtrl = TextEditingController(text: widget.vocab.targetWord);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            final pool = provider.sentences.where((sentence) {
              return KoreanTextSearch.matches(
                query: searchCtrl.text,
                targetText: sentence.targetText,
                translationText: sentence.translationText,
              );
            }).toList();
            return Container(
              height: MediaQuery.of(context).size.height * 0.7,
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Select from Sentence Pool',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                  TextField(
                    controller: searchCtrl,
                    autofocus: true,
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search),
                      hintText: 'Search using ${widget.vocab.targetWord}...',
                      border: const OutlineInputBorder(),
                      suffixIcon: searchCtrl.text.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.clear),
                              onPressed: () {
                                searchCtrl.clear();
                                setSheetState(() {});
                              },
                            ),
                    ),
                    onChanged: (_) => setSheetState(() {}),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${pool.length} matching ${pool.length == 1 ? 'sentence' : 'sentences'}',
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                  const Divider(),
                  if (pool.isEmpty)
                    const Expanded(
                      child: Center(
                        child: Text('No sentences matched this search.'),
                      ),
                    )
                  else
                    Expanded(
                      child: ListView.builder(
                        itemCount: pool.length,
                        itemBuilder: (context, idx) {
                          final sentence = pool[idx];
                          final isAttached = _sentenceIds.contains(sentence.id);
                          return Card(
                            margin: const EdgeInsets.symmetric(vertical: 4),
                            child: ListTile(
                              title: MarkdownContent(
                                content: sentence.targetText,
                              ),
                              subtitle: MarkdownContent(
                                content: sentence.translationText,
                              ),
                              trailing: Checkbox(
                                value: isAttached,
                                onChanged: (val) {
                                  setSheetState(() {
                                    if (val == true) {
                                      _sentenceIds.add(sentence.id);
                                    } else {
                                      _sentenceIds.remove(sentence.id);
                                    }
                                  });
                                  setState(() {});
                                },
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                ],
              ),
            );
          },
        );
      },
    ).whenComplete(searchCtrl.dispose);
  }

  void _openCreateSentenceDialog() {
    final targetCtrl = TextEditingController();
    final transCtrl = TextEditingController();
    final audioCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add New Sentence to Pool'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: targetCtrl,
                decoration: const InputDecoration(
                  labelText: 'Target Sentence (Markdown, e.g. 저는 **단어**를...)',
                  hintText: 'Use **word** for bolding/cloze',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: transCtrl,
                decoration: const InputDecoration(
                  labelText: 'Translation Sentence',
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
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (targetCtrl.text.trim().isNotEmpty) {
                final newSentence = Sentence(
                  targetText: targetCtrl.text.trim(),
                  translationText: transCtrl.text.trim(),
                  audioUrl: audioCtrl.text.trim().isEmpty
                      ? null
                      : audioCtrl.text.trim(),
                  lessonId: widget.lessonId,
                );
                context.read<AppProvider>().addSentenceToPool(newSentence);
                setState(() {
                  _sentenceIds.add(newSentence.id);
                });
                Navigator.pop(ctx);
              }
            },
            child: const Text('Create & Link'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.watch<AppProvider>();

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: 680,
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.9,
        ),
        child: Column(
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 20, 12),
              child: Row(
                children: [
                  const Icon(Icons.edit_note_rounded, size: 28),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Edit Vocabulary: ${widget.vocab.targetWord}',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),

            // Form Content
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 16,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Target Word and Translation
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          flex: 5,
                          child: TextField(
                            controller: _targetWordCtrl,
                            decoration: const InputDecoration(
                              labelText: 'Target Word / Term *',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          flex: 5,
                          child: TextField(
                            controller: _translationCtrl,
                            decoration: const InputDecoration(
                              labelText: 'Translation / Native *',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    // Part of speech / Category & Audio URL
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          flex: 4,
                          child: TextField(
                            controller: _posCtrl,
                            decoration: const InputDecoration(
                              labelText: 'Part of Speech / Category',
                              hintText: 'e.g. nouns, verbs, adjectives',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          flex: 6,
                          child: TextField(
                            controller: _audioCtrl,
                            decoration: InputDecoration(
                              labelText: 'Vocab Audio URL or Path',
                              border: const OutlineInputBorder(),
                              suffixIcon: AudioButton(
                                audioUrl: _audioCtrl.text,
                                compact: true,
                              ),
                            ),
                            onChanged: (_) => setState(() {}),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    TextField(
                      controller: _idCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Vocabulary ID (optional)',
                        hintText: 'Set an ID to share or separate SRS progress',
                        helperText:
                            'The same ID shares SRS progress across sections. '
                            'Leave blank to use the word and meaning.',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 20),

                    // SRS Direction Toggles
                    Card(
                      elevation: 0,
                      color: theme.colorScheme.surfaceContainerHighest
                          .withValues(alpha: 0.5),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(
                          color: theme.colorScheme.outlineVariant,
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'SRS Flashcard Directions',
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 8),
                            SwitchListTile(
                              title: const Text(
                                'Target ➔ Native (KO ➔ EN) Card',
                              ),
                              subtitle: const Text(
                                'Hidden by default for verbs and adjectives',
                              ),
                              value: _enableTargetToNative,
                              onChanged: (val) =>
                                  setState(() => _enableTargetToNative = val),
                            ),
                            SwitchListTile(
                              title: const Text(
                                'Native ➔ Target (EN ➔ KO) Card [with Cloze]',
                              ),
                              subtitle: const Text(
                                'Hidden by default for other cards',
                              ),
                              value: _enableNativeToTarget,
                              onChanged: (val) =>
                                  setState(() => _enableNativeToTarget = val),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),

                    // Notes Section (with Markdown preview toggle)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Notes (Markdown / HTML)',
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        TextButton.icon(
                          icon: Icon(
                            _showNotesPreview ? Icons.edit : Icons.preview,
                          ),
                          label: Text(
                            _showNotesPreview
                                ? 'Edit Notes'
                                : 'Preview Markdown',
                          ),
                          onPressed: () => setState(
                            () => _showNotesPreview = !_showNotesPreview,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    if (_showNotesPreview)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest
                              .withValues(alpha: 0.3),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: theme.colorScheme.outlineVariant,
                          ),
                        ),
                        constraints: const BoxConstraints(minHeight: 120),
                        child: _notesCtrl.text.isEmpty
                            ? const Text(
                                'No notes entered yet.',
                                style: TextStyle(color: Colors.grey),
                              )
                            : MarkdownContent(content: _notesCtrl.text),
                      )
                    else
                      TextField(
                        controller: _notesCtrl,
                        maxLines: 5,
                        decoration: const InputDecoration(
                          hintText: 'Enter notes in markdown or HTML (<p>, **bold**, etc.)...',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    const SizedBox(height: 24),

                    // Linked Sentences from Pool
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Linked Sentences (${_sentenceIds.length})',
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Wrap(
                          spacing: 8,
                          children: [
                            OutlinedButton.icon(
                              icon: const Icon(Icons.add, size: 18),
                              label: const Text('From Pool'),
                              onPressed: _openSentencePicker,
                            ),
                            FilledButton.tonalIcon(
                              icon: const Icon(
                                Icons.add_circle_outline,
                                size: 18,
                              ),
                              label: const Text('Create New'),
                              onPressed: _openCreateSentenceDialog,
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (_sentenceIds.isEmpty)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(vertical: 20),
                        alignment: Alignment.center,
                        child: Text(
                          'No sentences linked yet. Add one from the pool or create a new sentence.',
                          style: TextStyle(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      )
                    else
                      ListView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: _sentenceIds.length,
                        itemBuilder: (ctx, i) {
                          final sentence = provider.getSentenceById(
                            _sentenceIds[i],
                          );
                          if (sentence == null) return const SizedBox.shrink();

                          return Card(
                            margin: const EdgeInsets.symmetric(vertical: 4),
                            child: ListTile(
                              title: MarkdownContent(
                                content: sentence.targetText,
                              ),
                              subtitle: MarkdownContent(
                                content: sentence.translationText,
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (sentence.audioUrl != null)
                                    AudioButton(
                                      audioUrl: sentence.audioUrl,
                                      compact: true,
                                    ),
                                  IconButton(
                                    icon: const Icon(
                                      Icons.delete_outline,
                                      color: Colors.red,
                                    ),
                                    tooltip: 'Unlink from word',
                                    onPressed: () {
                                      setState(() {
                                        _sentenceIds.removeAt(i);
                                      });
                                    },
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                  ],
                ),
              ),
            ),

            // Footer Actions
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 12),
                  FilledButton(
                    onPressed: _save,
                    child: const Text('Save Changes'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
