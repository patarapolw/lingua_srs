import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../models/srs_card.dart';
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
  late TextEditingController _disambiguationCtrl;
  late TextEditingController _targetToNativeBackNotesCtrl;
  late TextEditingController _nativeToTargetBackNotesCtrl;
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
    _disambiguationCtrl = TextEditingController(
      text: widget.vocab.disambiguation,
    );
    _targetToNativeBackNotesCtrl = TextEditingController(
      text: widget.vocab.cardTargetToNative.backNotes,
    );
    _nativeToTargetBackNotesCtrl = TextEditingController(
      text: widget.vocab.cardNativeToTarget.backNotes,
    );
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
    _disambiguationCtrl.dispose();
    _targetToNativeBackNotesCtrl.dispose();
    _nativeToTargetBackNotesCtrl.dispose();
    _idCtrl.dispose();
    super.dispose();
  }

  void _save() {
    final provider = context.read<AppProvider>();
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
    provider.rebindVocabId(widget.vocab, _originalId);
    widget.vocab.targetWord = _targetWordCtrl.text.trim();
    widget.vocab.translation = _translationCtrl.text.trim();
    widget.vocab.pos = _posCtrl.text.trim();
    widget.vocab.audioUrl = _audioCtrl.text.trim().isEmpty
        ? null
        : _audioCtrl.text.trim();
    widget.vocab.notes = _notesCtrl.text.trim();
    widget.vocab.disambiguation = _disambiguationCtrl.text.trim();
    widget.vocab.sentenceIds = _sentenceIds;

    widget.vocab.cardTargetToNative.isEnabled = _enableTargetToNative;
    widget.vocab.cardNativeToTarget.isEnabled = _enableNativeToTarget;
    widget.vocab.cardTargetToNative.backNotes = _targetToNativeBackNotesCtrl
        .text
        .trim();
    widget.vocab.cardNativeToTarget.backNotes = _nativeToTargetBackNotesCtrl
        .text
        .trim();

    provider.updateVocab(widget.vocab, previousId: _originalId);
    Navigator.of(context).pop();
  }

  Widget _sideNotesField(String label, TextEditingController controller) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: controller,
        minLines: 2,
        maxLines: 4,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }

  void _openSentencePicker() {
    final provider = context.read<AppProvider>();
    final word = widget.vocab.targetWord.trim();
    final searchCtrl = TextEditingController(
      text: word.length <= 30 ? word : '',
    );
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
                        'Select examples from the pool',
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
                      hintText: 'Search examples',
                      hintMaxLines: 1,
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
                                  if (val == true && !isAttached) {
                                    _editAndLinkSentence(
                                      context: ctx,
                                      sentence: sentence,
                                      setSheetState: setSheetState,
                                    );
                                  } else if (val != true && isAttached) {
                                    setSheetState(() {
                                      _sentenceIds.remove(sentence.id);
                                    });
                                    setState(() {});
                                  }
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
    ).whenComplete(() => _disposeAfterRouteExit([searchCtrl]));
  }

  Future<void> _editAndLinkSentence({
    required BuildContext context,
    required Sentence sentence,
    required StateSetter setSheetState,
  }) async {
    final provider = this.context.read<AppProvider>();
    final targetCtrl = TextEditingController(
      text: _suggestEmphasis(
        sentence.targetText,
        widget.vocab.targetWord,
        korean: true,
      ),
    );
    final translationCtrl = TextEditingController(
      text: _suggestEmphasis(
        sentence.translationText,
        widget.vocab.translation,
      ),
    );
    final shouldLink = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Emphasize vocabulary in sentence'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: targetCtrl,
                  minLines: 2,
                  maxLines: 5,
                  decoration: const InputDecoration(
                    labelText: 'Korean sentence',
                    helperText: 'Edit the suggested **vocabulary** emphasis.',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: translationCtrl,
                  minLines: 2,
                  maxLines: 5,
                  decoration: const InputDecoration(
                    labelText: 'Translation',
                    helperText: 'Edit the suggested **meaning** emphasis.',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Link sentence'),
          ),
        ],
      ),
    );

    if (shouldLink == true && mounted) {
      sentence
        ..targetText = targetCtrl.text.trim()
        ..translationText = translationCtrl.text.trim();
      final canonical = await provider.updateSentenceInPool(sentence);
      if (mounted && context.mounted) {
        setSheetState(() {
          if (!_sentenceIds.contains(canonical.id)) {
            _sentenceIds.add(canonical.id);
          }
        });
        setState(() {});
      }
    }
    _disposeAfterRouteExit([targetCtrl, translationCtrl]);
  }

  static String _suggestEmphasis(
    String text,
    String vocabulary, {
    bool korean = false,
  }) {
    if (text.contains('**')) return text;
    final candidates = korean
        ? [vocabulary.trim()]
        : vocabulary
              .split(RegExp(r'[,;/]'))
              .map((candidate) => candidate.trim())
              .where((candidate) => candidate.isNotEmpty)
              .toList();
    for (final candidate in candidates) {
      if (candidate.isEmpty) continue;
      final exact = RegExp(RegExp.escape(candidate), caseSensitive: false);
      if (exact.hasMatch(text)) {
        return text.replaceFirstMapped(exact, (match) => '**${match[0]}**');
      }
      if (korean) {
        final stem = candidate.endsWith('하다')
            ? candidate.substring(0, candidate.length - 2)
            : candidate.endsWith('다')
            ? candidate.substring(0, candidate.length - 1)
            : candidate;
        if (stem.isEmpty) continue;
        final conjugated = RegExp(
          '${RegExp.escape(stem)}[가-힣]*',
          caseSensitive: false,
        );
        if (conjugated.hasMatch(text)) {
          return text.replaceFirstMapped(
            conjugated,
            (match) => '**${match[0]}**',
          );
        }
      }
    }
    return text;
  }

  void _openCreateSentenceDialog() {
    final targetCtrl = TextEditingController();
    final transCtrl = TextEditingController();
    final audioCtrl = TextEditingController();
    final notesCtrl = TextEditingController();

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
                  labelText: 'Korean sentence',
                  hintText: 'Use **word** for bold/cloze',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: transCtrl,
                decoration: const InputDecoration(
                  labelText: 'English translation',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: audioCtrl,
                decoration: const InputDecoration(labelText: 'Audio URL'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: notesCtrl,
                minLines: 2,
                maxLines: 5,
                decoration: const InputDecoration(
                  labelText: 'Notes (Markdown)',
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
                final newSentence = Sentence(
                  targetText: targetCtrl.text.trim(),
                  translationText: transCtrl.text.trim(),
                  audioUrl: audioCtrl.text.trim().isEmpty
                      ? null
                      : audioCtrl.text.trim(),
                  notes: notesCtrl.text.trim(),
                  lessonId: widget.lessonId,
                );
                final canonical = await context
                    .read<AppProvider>()
                    .addSentenceToPool(newSentence);
                setState(() {
                  if (!_sentenceIds.contains(canonical.id)) {
                    _sentenceIds.add(canonical.id);
                  }
                });
                if (ctx.mounted) Navigator.pop(ctx);
              }
            },
            child: const Text('Create & Link'),
          ),
        ],
      ),
    ).whenComplete(
      () =>
          _disposeAfterRouteExit([targetCtrl, transCtrl, audioCtrl, notesCtrl]),
    );
  }

  // The route's exit animation still builds its text fields after the route
  // future completes, so controllers must outlive it.
  static void _disposeAfterRouteExit(List<TextEditingController> controllers) {
    Future<void>.delayed(const Duration(seconds: 1), () {
      for (final controller in controllers) {
        controller.dispose();
      }
    });
  }

  Widget _duplicateFrontWarning(AppProvider provider, CardDirection direction) {
    final duplicates = provider.getDuplicateFrontVocabularies(
      widget.vocab,
      direction,
    );
    if (duplicates.isEmpty) return const SizedBox.shrink();

    final directionLabel = direction == CardDirection.targetToNative
        ? 'KO ➔ EN card'
        : 'EN ➔ KO card';
    final meanings = duplicates
        .map((vocab) => '${vocab.targetWord} — ${vocab.translation}')
        .join('; ');
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        '$directionLabel has the same front prompt as another enabled card: '
        '$meanings. Add a disambiguation cue below to tell them apart.',
        style: TextStyle(
          color: Theme.of(context).colorScheme.error,
          fontSize: 12,
        ),
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
                      widget.vocab.targetWord,
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
                              labelText: 'Korean *',
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
                              labelText: 'English *',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _disambiguationCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Front hint (optional)',
                        hintText: 'e.g. fruit, vehicle',
                        helperText:
                            'Shown on card fronts to tell duplicates apart.',
                        helperMaxLines: 3,
                        border: OutlineInputBorder(),
                      ),
                    ),
                    _duplicateFrontWarning(
                      provider,
                      CardDirection.targetToNative,
                    ),
                    _duplicateFrontWarning(
                      provider,
                      CardDirection.nativeToTarget,
                    ),
                    const SizedBox(height: 20),

                    // Part of speech / Category & Audio URL
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          flex: 4,
                          child: TextField(
                            controller: _posCtrl,
                            decoration: const InputDecoration(
                              labelText: 'Part of speech',
                              hintText: 'e.g. nouns',
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
                              labelText: 'Audio URL',
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
                        labelText: 'ID (optional)',
                        helperText: 'Same ID shares SRS progress. Blank uses word + meaning.',
                        helperMaxLines: 3,
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
                              'Cards',
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 8),
                            SwitchListTile(
                              title: const Text('KO ➔ EN'),
                              subtitle: const Text(
                                'Off by default for verbs, adjectives',
                              ),
                              value: _enableTargetToNative,
                              onChanged: (val) =>
                                  setState(() => _enableTargetToNative = val),
                            ),
                            SwitchListTile(
                              title: const Text('EN ➔ KO (cloze)'),
                              subtitle: const Text(
                                'Off by default for other cards',
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

                    Text(
                      'Review notes',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    _sideNotesField('KO ➔ EN', _targetToNativeBackNotesCtrl),
                    _sideNotesField('EN ➔ KO', _nativeToTargetBackNotesCtrl),
                    const SizedBox(height: 20),

                    // Notes Section (with Markdown preview toggle)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            'Vocab notes',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        TextButton.icon(
                          icon: Icon(
                            _showNotesPreview ? Icons.edit : Icons.preview,
                            size: 18,
                          ),
                          label: Text(_showNotesPreview ? 'Edit' : 'Preview'),
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
                          hintText: 'Markdown notes, e.g. **bold**, lists',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    const SizedBox(height: 24),

                    // Linked Sentences from Pool
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            'Examples (${_sentenceIds.length})',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        IconButton.outlined(
                          icon: const Icon(Icons.library_add_outlined),
                          tooltip: 'Add from pool',
                          onPressed: _openSentencePicker,
                        ),
                        const SizedBox(width: 4),
                        IconButton.filledTonal(
                          icon: const Icon(Icons.add),
                          tooltip: 'Create new sentence',
                          onPressed: _openCreateSentenceDialog,
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
                          'No examples yet. Add one from the pool or create a new one.',
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
                                selectable: true,
                              ),
                              subtitle: MarkdownContent(
                                content: sentence.translationText,
                                selectable: true,
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
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 12),
                  FilledButton(onPressed: _save, child: const Text('Save')),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
