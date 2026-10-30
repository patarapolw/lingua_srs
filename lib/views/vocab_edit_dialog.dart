import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../models/sentence.dart';
import '../models/srs_card.dart';
import '../models/vocab_item.dart';
import '../providers/app_provider.dart';
import '../services/korean_text_search.dart';
import '../widgets/audio_button.dart';
import '../widgets/audio_edit_fields.dart';
import '../widgets/emphasis_text.dart';
import '../widgets/markdown_content.dart';
import '../widgets/markdown_notes_field.dart';
import '../widgets/markdown_text_field.dart';
import 'similar_meanings_dialog.dart';
import 'similar_search_dialog.dart';
import 'vocab_merge_dialogs.dart';

class VocabEditDialog extends StatefulWidget {
  final VocabItem vocab;
  final String? lessonId;

  /// True when [vocab] is a blank draft being added: shows only the required
  /// fields. Everything else is available by editing the word afterwards.
  final bool isNew;

  const VocabEditDialog({
    super.key,
    required this.vocab,
    this.lessonId,
    this.isNew = false,
  });

  @override
  State<VocabEditDialog> createState() => _VocabEditDialogState();

  static Future<void> show(
    BuildContext context,
    VocabItem vocab, {
    String? lessonId,
    bool isNew = false,
  }) {
    return showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) =>
          VocabEditDialog(vocab: vocab, lessonId: lessonId, isNew: isNew),
    );
  }
}

class _VocabEditDialogState extends State<VocabEditDialog>
    with SingleTickerProviderStateMixin {
  late TextEditingController _targetWordCtrl;
  late TextEditingController _translationCtrl;
  late TextEditingController _posCtrl;
  late TextEditingController _audioCtrl;
  late bool _useAudio;
  late TextEditingController _ttsCtrl;
  late TextEditingController _notesCtrl;
  late TextEditingController _disambiguationCtrl;
  late TextEditingController _targetToNativeHintCtrl;
  late TextEditingController _nativeToTargetHintCtrl;
  CardDirection? _suggestingDirection;
  final Map<CardDirection, Map<String, String>> _pendingHints = {
    CardDirection.targetToNative: {},
    CardDirection.nativeToTarget: {},
  };
  late TextEditingController _targetToNativeBackNotesCtrl;
  late TextEditingController _nativeToTargetBackNotesCtrl;
  late TextEditingController _idCtrl;
  late String _originalId;

  late bool _enableTargetToNative;
  late bool _enableNativeToTarget;
  late List<String> _sentenceIds;

  /// Examples typed while adding a word. Like a YAML import, they join the
  /// sentence pool and get linked only when the word is saved.
  final List<Sentence> _draftSentences = [];

  /// Emphasis edits to pool sentences, applied on Save so cancelling leaves
  /// the pool untouched.
  final Map<String, ({String target, String translation})> _pendingEmphasis =
      {};

  /// Recording-or-TTS choices for pool sentences, applied on Save like
  /// [_pendingEmphasis]. Sentences without an entry keep their own setting.
  final Map<String, bool> _pendingUseAudio = {};

  bool _showNotesPreview = false;
  String? _targetError;
  String? _translationError;
  String? _posError;

  /// Only a vocab that is already saved can be merged.
  late final bool _isSaved = context.read<AppProvider>().lessons.any(
    (lesson) => lesson.vocabularies.any((v) => identical(v, widget.vocab)),
  );

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
                  Icon(
                    widget.isNew
                        ? Icons.add_circle_outline
                        : Icons.edit_note_rounded,
                    size: 28,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      widget.isNew ? 'Add vocabulary' : widget.vocab.targetWord,
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
                            decoration: InputDecoration(
                              labelText: 'Korean *',
                              errorText: _targetError,
                              border: const OutlineInputBorder(),
                            ),
                            // Also refreshes the suggested examples.
                            onChanged: (_) =>
                                setState(() => _targetError = null),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          flex: 5,
                          child: TextField(
                            controller: _translationCtrl,
                            decoration: InputDecoration(
                              labelText: 'English *',
                              errorText: _translationError,
                              border: const OutlineInputBorder(),
                            ),
                            onChanged: (_) {
                              if (_translationError != null) {
                                setState(() => _translationError = null);
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    TtsTextField(
                      controller: _ttsCtrl,
                      spokenFallback: _targetWordCtrl,
                      hintText: 'e.g. 세 개 for 3개',
                      helperText: 'Spoken instead of the Korean word when there is no recording.',
                    ),
                    if (!widget.isNew) ...[
                      const SizedBox(height: 16),
                      _duplicateFrontWarning(
                        provider,
                        CardDirection.targetToNative,
                      ),
                      _duplicateFrontWarning(
                        provider,
                        CardDirection.nativeToTarget,
                      ),
                      // Collapsed unless this word needs telling apart from
                      // another card with the same front.
                      Theme(
                        data: theme.copyWith(dividerColor: Colors.transparent),
                        child: ExpansionTile(
                          initiallyExpanded: CardDirection.values.any(
                            (direction) => provider
                                .getDuplicateFrontVocabularies(
                                  widget.vocab,
                                  direction,
                                )
                                .isNotEmpty,
                          ),
                          maintainState: true,
                          tilePadding: EdgeInsets.zero,
                          childrenPadding: const EdgeInsets.only(top: 8),
                          title: Text(
                            'Hints',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          subtitle: Text(
                            'Tell apart cards with the same front.',
                            style: theme.textTheme.bodySmall,
                          ),
                          children: [
                            TextField(
                              controller: _disambiguationCtrl,
                              decoration: const InputDecoration(
                                labelText:
                                    'Front hint, both directions (optional)',
                                hintText: 'e.g. fruit, vehicle',
                                helperText: 'Shown on card fronts unless a direction-specific hint below is set.',
                                helperMaxLines: 3,
                                border: OutlineInputBorder(),
                              ),
                            ),
                            _hintField(provider, CardDirection.targetToNative),
                            _hintField(provider, CardDirection.nativeToTarget),
                          ],
                        ),
                      ),
                      _mergeSection(provider),
                    ],
                    const SizedBox(height: 20),

                    // Part of speech / Category & Audio URL
                    TextField(
                      controller: _posCtrl,
                      decoration: InputDecoration(
                        labelText: widget.isNew
                            ? 'Part of speech *'
                            : 'Part of speech',
                        hintText: 'e.g. nouns, verbs',
                        errorText: _posError,
                        border: const OutlineInputBorder(),
                      ),
                      onChanged: (_) {
                        if (_posError != null) {
                          setState(() => _posError = null);
                        }
                      },
                    ),
                    const SizedBox(height: 16),
                    AudioUrlField(
                      controller: _audioCtrl,
                      useAudio: _useAudio,
                      onUseAudioChanged: (value) =>
                          setState(() => _useAudio = value),
                    ),
                    if (!widget.isNew) ...[
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

                      // Collapsed: these are usually edited from the back of the
                      // card while reviewing.
                      Theme(
                        data: theme.copyWith(dividerColor: Colors.transparent),
                        child: ExpansionTile(
                          maintainState: true,
                          tilePadding: EdgeInsets.zero,
                          childrenPadding: const EdgeInsets.only(top: 8),
                          title: Text(
                            'Review notes',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          subtitle: Text(
                            'Per card. Also editable on the back of the card '
                            'while reviewing.',
                            style: theme.textTheme.bodySmall,
                          ),
                          children: [
                            MarkdownNotesField(
                              key: const ValueKey('review-notes-ko-en'),
                              label: 'KO ➔ EN',
                              controller: _targetToNativeBackNotesCtrl,
                            ),
                            MarkdownNotesField(
                              key: const ValueKey('review-notes-en-ko'),
                              label: 'EN ➔ KO',
                              controller: _nativeToTargetBackNotesCtrl,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),
                    ],

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
                      MarkdownTextField(
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
                            'Examples (${_sentenceIds.length + _draftSentences.length})',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        // Choosing from the pool is the default; a new sentence
                        // has to be checked for duplicates first.
                        if (widget.isNew) ...[
                          IconButton.filledTonal(
                            icon: const Icon(Icons.library_add_outlined),
                            tooltip: 'Add from pool',
                            onPressed: _openSentencePicker,
                          ),
                          const SizedBox(width: 4),
                          IconButton.outlined(
                            icon: const Icon(Icons.add),
                            tooltip: 'Create new sentence',
                            onPressed: _openCreateSentenceDialog,
                          ),
                        ] else ...[
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
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (_sentenceIds.isNotEmpty || _draftSentences.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(
                          'Tap an example to edit its **emphasis**.',
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    if (widget.isNew) ..._suggestedExamples(provider, theme),
                    if (_sentenceIds.isEmpty && _draftSentences.isEmpty)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(vertical: 20),
                        alignment: Alignment.center,
                        child: Text(
                          widget.isNew
                              ? 'No examples yet. Choose from the pool, or create a new one with +.'
                              : 'No examples yet. Add one from the pool or create a new one.',
                          style: TextStyle(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      )
                    else if (_sentenceIds.isNotEmpty)
                      ListView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: _sentenceIds.length,
                        itemBuilder: (ctx, i) {
                          final sentence = provider.getSentenceById(
                            _sentenceIds[i],
                          );
                          if (sentence == null) return const SizedBox.shrink();
                          final usesRecording =
                              _pendingUseAudio[sentence.id] ??
                              sentence.useAudio;

                          return Card(
                            margin: const EdgeInsets.symmetric(vertical: 4),
                            child: ListTile(
                              onTap: () => _editLinkedSentence(sentence),
                              title: EmphasisText(
                                _pendingEmphasis[sentence.id]?.target ??
                                    sentence.targetText,
                              ),
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  EmphasisText(
                                    _pendingEmphasis[sentence.id]
                                            ?.translation ??
                                        sentence.translationText,
                                  ),
                                  SentenceAudioChoice(
                                    hasRecording: sentence.hasAudioUrl,
                                    useAudio: usesRecording,
                                    onChanged: (value) => setState(
                                      () =>
                                          _pendingUseAudio[sentence.id] = value,
                                    ),
                                  ),
                                ],
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  AudioButton(
                                    audioUrl: usesRecording
                                        ? sentence.audioUrl
                                        : null,
                                    fallbackText: sentence.speechText,
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
                    for (var i = 0; i < _draftSentences.length; i++)
                      _draftSentenceCard(i, theme),
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

  @override
  void dispose() {
    _targetWordCtrl.dispose();
    _translationCtrl.dispose();
    _posCtrl.dispose();
    _audioCtrl.dispose();
    _ttsCtrl.dispose();
    _notesCtrl.dispose();
    _disambiguationCtrl.dispose();
    _targetToNativeBackNotesCtrl.dispose();
    _nativeToTargetBackNotesCtrl.dispose();
    _idCtrl.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _targetWordCtrl = TextEditingController(text: widget.vocab.targetWord);
    _translationCtrl = TextEditingController(text: widget.vocab.translation);
    _posCtrl = TextEditingController(text: widget.vocab.pos);
    _audioCtrl = TextEditingController(text: widget.vocab.audioUrl ?? '');
    _useAudio = widget.vocab.useAudio;
    _ttsCtrl = TextEditingController(text: widget.vocab.ttsText ?? '');
    _notesCtrl = TextEditingController(text: widget.vocab.notes);
    _disambiguationCtrl = TextEditingController(
      text: widget.vocab.disambiguation,
    );
    _targetToNativeHintCtrl = TextEditingController(
      text: widget.vocab.cardTargetToNative.frontHint,
    );
    _nativeToTargetHintCtrl = TextEditingController(
      text: widget.vocab.cardNativeToTarget.frontHint,
    );
    // dispose(): _targetToNativeHintCtrl.dispose(); _nativeToTargetHintCtrl.dispose();
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

  void _applyChoice(CardDirection direction, SimilarMeaningsChoice choice) {
    final controller = direction == CardDirection.nativeToTarget
        ? _nativeToTargetHintCtrl
        : _targetToNativeHintCtrl;
    setState(() {
      if (choice.targetHint != null) controller.text = choice.targetHint!;
      _pendingHints[direction]!
        ..clear()
        ..addAll(choice.otherHints);
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
        '$meanings. Add a front hint for this card under Hints to tell them apart.',
        style: TextStyle(
          color: Theme.of(context).colorScheme.error,
          fontSize: 12,
        ),
      ),
    );
  }

  Future<void> _editAndLinkSentence({
    required BuildContext context,
    required Sentence sentence,
    required StateSetter setSheetState,
  }) async {
    final provider = this.context.read<AppProvider>();
    final edited = await _editEmphasis(
      target: sentence.targetText,
      translation: sentence.translationText,
    );
    if (edited == null || !mounted) return;

    sentence
      ..targetText = edited.target
      ..translationText = edited.translation;
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

  /// Edits only the `**` emphasis of a sentence. The plain text has to stay
  /// the same: a sentence is identified by its text without emphasis, and one
  /// sentence can be shared by several words.
  Future<({String target, String translation})?> _editEmphasis({
    required String target,
    required String translation,
  }) async {
    final targetCtrl = TextEditingController(
      text: Sentence.suggestEmphasis(
        target,
        _targetWordCtrl.text,
        korean: true,
      ),
    );
    final translationCtrl = TextEditingController(
      text: Sentence.suggestEmphasis(translation, _translationCtrl.text),
    );
    const mismatch = 'Only ** emphasis can be changed here.';
    final result = await showDialog<({String target, String translation})>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          final targetOk = Sentence.sameExceptEmphasis(target, targetCtrl.text);
          final translationOk = Sentence.sameExceptEmphasis(
            translation,
            translationCtrl.text,
          );
          return AlertDialog(
            title: const Text('Edit emphasis'),
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
                      onChanged: (_) => setDialogState(() {}),
                      decoration: InputDecoration(
                        labelText: 'Korean sentence',
                        helperText: 'Wrap each part in **double asterisks**; use several for several words.',
                        helperMaxLines: 2,
                        errorText: targetOk ? null : mismatch,
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Cloze: ${Sentence(targetText: targetCtrl.text, translationText: '').toCloze(targetWord: _targetWordCtrl.text)}',
                        style: Theme.of(dialogContext).textTheme.bodySmall,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: translationCtrl,
                      minLines: 2,
                      maxLines: 5,
                      onChanged: (_) => setDialogState(() {}),
                      decoration: InputDecoration(
                        labelText: 'Translation',
                        errorText: translationOk ? null : mismatch,
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: targetOk && translationOk
                    ? () => Navigator.pop(dialogContext, (
                        target: targetCtrl.text.trim(),
                        translation: translationCtrl.text.trim(),
                      ))
                    : null,
                child: const Text('Apply'),
              ),
            ],
          );
        },
      ),
    );
    _disposeAfterRouteExit([targetCtrl, translationCtrl]);
    return result;
  }

  Future<void> _editLinkedSentence(Sentence sentence) async {
    final pending = _pendingEmphasis[sentence.id];
    final edited = await _editEmphasis(
      target: pending?.target ?? sentence.targetText,
      translation: pending?.translation ?? sentence.translationText,
    );
    if (edited == null || !mounted) return;
    setState(() => _pendingEmphasis[sentence.id] = edited);
  }

  Future<void> _editDraftSentence(int index) async {
    final sentence = _draftSentences[index];
    final edited = await _editEmphasis(
      target: sentence.targetText,
      translation: sentence.translationText,
    );
    if (edited == null || !mounted) return;
    setState(() {
      sentence
        ..targetText = edited.target
        ..translationText = edited.translation;
    });
  }

  Widget _hintField(AppProvider provider, CardDirection direction) {
    final enKo = direction == CardDirection.nativeToTarget;
    final pending = _pendingHints[direction]!.length;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: enKo
                ? _nativeToTargetHintCtrl
                : _targetToNativeHintCtrl,
            decoration: InputDecoration(
              labelText: enKo ? 'EN ➔ KO front hint' : 'KO ➔ EN front hint',
              hintText: enKo ? 'e.g. general size' : 'e.g. fruit',
              border: const OutlineInputBorder(),
              suffixIcon: _hintSuffix(provider, direction),
            ),
          ),
          if (pending > 0)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Hints for $pending similar word(s) will be saved with this one.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }

  Widget? _hintSuffix(AppProvider provider, CardDirection direction) {
    final enKo = direction == CardDirection.nativeToTarget;
    final buttons = <Widget>[
      if (enKo)
        IconButton(
          tooltip: 'Find similar English meanings',
          icon: const Icon(Icons.manage_search),
          onPressed: () => _searchSimilar(provider),
        ),
      if (provider.canUseAi)
        IconButton(
          tooltip: enKo
              ? 'Suggest hint with AI (sends vocabulary of the same type to DeepSeek)'
              : 'Suggest hint with AI (sends words with the same spelling to DeepSeek)',
          icon: _suggestingDirection == direction
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.auto_awesome),
          onPressed: _suggestingDirection != null
              ? null
              : () => _suggestHint(provider, direction),
        ),
    ];
    return buttons.isEmpty
        ? null
        : Row(mainAxisSize: MainAxisSize.min, children: buttons);
  }

  Future<void> _mergeManually() async {
    final merged = await startManualMerge(
      context,
      widget.vocab,
      note: 'Unsaved changes in this edit form will be discarded.',
    );
    if (merged && mounted) Navigator.of(context).pop();
  }

  Widget _mergeSection(AppProvider provider) {
    if (!_isSaved) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Merge duplicates', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            'Combine this word with another entry that means the same thing. '
            'They share SRS progress, audio, notes and hints. '
            'Unsaved edits in this form are discarded.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.merge_type),
                label: const Text('Merge with another word…'),
                onPressed: _mergeManually,
              ),
              if (provider.canUseAi)
                OutlinedButton.icon(
                  icon: const Icon(Icons.auto_awesome),
                  label: const Text('Suggest merge with AI'),
                  onPressed: _mergeWithAi,
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _mergeWithAi() async {
    final merged = await showAiMergeSuggestions(context, scope: widget.vocab);
    if (merged == true && mounted) Navigator.of(context).pop();
  }

  /// Pool sentences matching the word typed so far, one tap to link.
  List<Widget> _suggestedExamples(AppProvider provider, ThemeData theme) {
    final word = _targetWordCtrl.text.trim();
    if (word.isEmpty) return const [];
    final matches = provider.sentences
        .where(
          (sentence) =>
              !_sentenceIds.contains(sentence.id) &&
              KoreanTextSearch.matches(
                query: word,
                targetText: sentence.targetText,
                translationText: sentence.translationText,
              ),
        )
        .take(5)
        .toList();
    if (matches.isEmpty) return const [];
    return [
      Text('Suggested from the pool', style: theme.textTheme.labelMedium),
      for (final sentence in matches)
        CheckboxListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: false,
          onChanged: (_) => setState(() => _sentenceIds.add(sentence.id)),
          title: EmphasisText(sentence.targetText),
          subtitle: EmphasisText(sentence.translationText),
        ),
      const SizedBox(height: 8),
    ];
  }

  Widget _draftSentenceCard(int index, ThemeData theme) {
    final sentence = _draftSentences[index];
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        onTap: () => _editDraftSentence(index),
        title: EmphasisText(sentence.targetText),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            EmphasisText(sentence.translationText),
            SentenceAudioChoice(
              hasRecording: sentence.hasAudioUrl,
              useAudio: sentence.useAudio,
              onChanged: (value) => setState(() => sentence.useAudio = value),
            ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AudioButton(
              audioUrl: sentence.playableAudioUrl,
              fallbackText: sentence.speechText,
              compact: true,
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline, color: Colors.red),
              tooltip: 'Remove example',
              onPressed: () => setState(() => _draftSentences.removeAt(index)),
            ),
          ],
        ),
      ),
    );
  }

  void _openCreateSentenceDialog() {
    final targetCtrl = TextEditingController();
    final ttsCtrl = TextEditingController();
    final transCtrl = TextEditingController();
    final audioCtrl = TextEditingController();
    final notesCtrl = TextEditingController();
    var useAudio = true;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(widget.isNew ? 'Add example' : 'Add New Sentence to Pool'),
        content: StatefulBuilder(
          builder: (ctx, setDialogState) => SingleChildScrollView(
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
                AudioUrlField(
                  controller: audioCtrl,
                  useAudio: useAudio,
                  onUseAudioChanged: (value) =>
                      setDialogState(() => useAudio = value),
                ),
                const SizedBox(height: 4),
                TtsTextField(controller: ttsCtrl, spokenFallback: targetCtrl),
                const SizedBox(height: 8),
                MarkdownTextField(
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
                  useAudio: useAudio,
                  ttsText: ttsCtrl.text.trim().isEmpty
                      ? null
                      : ttsCtrl.text.trim(),
                  notes: notesCtrl.text.trim(),
                  lessonId: widget.lessonId,
                );
                if (widget.isNew) {
                  final existing = context
                      .read<AppProvider>()
                      .findDuplicateSentence(newSentence);
                  if (existing != null) {
                    final useExisting = await showDialog<bool>(
                      context: ctx,
                      builder: (dialogContext) => AlertDialog(
                        title: const Text('Sentence already exists'),
                        content: Text(
                          'The pool already has:\n\n${existing.targetText}\n'
                          '${existing.translationText}',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () =>
                                Navigator.pop(dialogContext, false),
                            child: const Text('Go back'),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(dialogContext, true),
                            child: const Text('Use existing'),
                          ),
                        ],
                      ),
                    );
                    if (useExisting != true) return;
                    if (!mounted) return;
                    setState(() {
                      if (!_sentenceIds.contains(existing.id)) {
                        _sentenceIds.add(existing.id);
                      }
                    });
                  } else {
                    setState(() => _draftSentences.add(newSentence));
                  }
                  if (ctx.mounted) Navigator.pop(ctx);
                  return;
                }
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
            child: Text(widget.isNew ? 'Add' : 'Create & Link'),
          ),
        ],
      ),
    ).whenComplete(
      () => _disposeAfterRouteExit([
        targetCtrl,
        ttsCtrl,
        transCtrl,
        audioCtrl,
        notesCtrl,
      ]),
    );
  }

  void _openSentencePicker() {
    final provider = context.read<AppProvider>();
    final word = (widget.isNew ? _targetWordCtrl.text : widget.vocab.targetWord)
        .trim();
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
                              title: EmphasisText(sentence.targetText),
                              subtitle: EmphasisText(sentence.translationText),
                              trailing: Checkbox(
                                value: isAttached,
                                onChanged: (val) {
                                  if (val == true &&
                                      !isAttached &&
                                      widget.isNew) {
                                    // Nothing is edited in the pool until the
                                    // word is saved; emphasis can be adjusted
                                    // later by editing the word.
                                    setSheetState(
                                      () => _sentenceIds.add(sentence.id),
                                    );
                                    setState(() {});
                                  } else if (val == true && !isAttached) {
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

  /// Asks before adding a word whose card front matches an existing card.
  Future<bool> _confirmDuplicates() async {
    final provider = context.read<AppProvider>();
    final draft = VocabItem(
      targetWord: _targetWordCtrl.text.trim(),
      translation: _translationCtrl.text.trim(),
      pos: _posCtrl.text.trim(),
    );
    final duplicates = <VocabItem>{
      if (_enableTargetToNative)
        ...provider.getDuplicateFrontVocabularies(
          draft,
          CardDirection.targetToNative,
        ),
      if (_enableNativeToTarget)
        ...provider.getDuplicateFrontVocabularies(
          draft,
          CardDirection.nativeToTarget,
        ),
    };
    if (duplicates.isEmpty) return true;

    final meanings = duplicates
        .map((vocab) => '${vocab.targetWord} — ${vocab.translation}')
        .join('\n');
    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Similar vocabulary exists'),
        content: Text(
          'Another card already has the same front prompt:\n\n$meanings\n\n'
          'You can add a front hint later by editing this word.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Go back'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Add anyway'),
          ),
        ],
      ),
    );
    return proceed ?? false;
  }

  Future<void> _save() async {
    if (widget.isNew) {
      final pos = _posCtrl.text.trim();
      setState(() {
        _targetError = _targetWordCtrl.text.trim().isEmpty ? 'Required' : null;
        _translationError = _translationCtrl.text.trim().isEmpty
            ? 'Required'
            : null;
        _posError = pos.isEmpty ? 'Required' : null;
      });
      if (_targetError != null ||
          _translationError != null ||
          _posError != null) {
        return;
      }
      // The card toggles are hidden when adding; use the defaults for this POS.
      _enableTargetToNative = !VocabItem.isVerbOrAdjective(pos);
      _enableNativeToTarget = VocabItem.isVerbOrAdjective(pos);
      if (!await _confirmDuplicates() || !mounted) return;
      final pool = context.read<AppProvider>();
      for (final draft in _draftSentences) {
        final canonical = await pool.addSentenceToPool(draft);
        if (!_sentenceIds.contains(canonical.id)) {
          _sentenceIds.add(canonical.id);
        }
      }
      if (!mounted) return;
    }
    final sentencePool = context.read<AppProvider>();
    // Before the emphasis edits: one of those may merge the sentence into a
    // duplicate, which keeps the choice made here.
    for (final entry in _pendingUseAudio.entries) {
      if (!_sentenceIds.contains(entry.key)) continue;
      final sentence = sentencePool.getSentenceById(entry.key);
      if (sentence == null || sentence.useAudio == entry.value) continue;
      sentence.useAudio = entry.value;
      await sentencePool.updateSentenceInPool(sentence);
    }
    for (final entry in _pendingEmphasis.entries) {
      if (!_sentenceIds.contains(entry.key)) continue;
      final sentence = sentencePool.getSentenceById(entry.key);
      if (sentence == null) continue;
      if (sentence.targetText == entry.value.target &&
          sentence.translationText == entry.value.translation) {
        continue;
      }
      sentence
        ..targetText = entry.value.target
        ..translationText = entry.value.translation;
      await sentencePool.updateSentenceInPool(sentence);
    }
    if (!mounted) return;
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
    widget.vocab.useAudio = _useAudio;
    if ((widget.vocab.ttsText ?? '') != _ttsCtrl.text.trim()) {
      widget.vocab.ttsText = _ttsCtrl.text.trim().isEmpty
          ? null
          : _ttsCtrl.text.trim();
    }
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

    widget.vocab.cardTargetToNative.frontHint = _targetToNativeHintCtrl.text
        .trim();
    widget.vocab.cardNativeToTarget.frontHint = _nativeToTargetHintCtrl.text
        .trim();

    // Because it’s deferred to Save, cancelling the dialog discards the other words’ hints.
    // Add import 'dart:async'; and wrap the call in unawaited(...) if the unawaited_futures lint is on.
    for (final entry in _pendingHints.entries) {
      if (entry.value.isNotEmpty) {
        unawaited(provider.applyFrontHints(Map.of(entry.value), entry.key));
      }
    }

    provider.updateVocab(widget.vocab, previousId: _originalId);
    Navigator.of(context).pop();
  }

  Future<void> _searchSimilar(AppProvider provider) async {
    final draft = VocabItem(
      id: widget.vocab.id,
      targetWord: _targetWordCtrl.text.trim(),
      translation: _translationCtrl.text.trim(),
      pos: _posCtrl.text.trim(),
      notes: _notesCtrl.text,
    );
    final choice = await showEnKoSearch(
      context,
      provider: provider,
      draft: draft,
      initialHint: _nativeToTargetHintCtrl.text,
    );
    if (choice == null || !mounted) return;
    _applyChoice(CardDirection.nativeToTarget, choice);
  }

  Future<void> _suggestHint(
    AppProvider provider,
    CardDirection direction,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final draft = VocabItem(
      id: widget.vocab.id,
      targetWord: _targetWordCtrl.text.trim(),
      translation: _translationCtrl.text.trim(),
      pos: _posCtrl.text.trim(),
      notes: _notesCtrl.text,
    );
    if (draft.targetWord.isEmpty || draft.translation.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Enter the word and its meaning first.')),
      );
      return;
    }
    final enKo = direction == CardDirection.nativeToTarget;
    setState(() => _suggestingDirection = direction);
    try {
      final result = enKo
          ? await provider.suggestEnKoHint(draft)
          : await provider.suggestKoEnHint(draft);
      if (!mounted) return;
      final choice = await showSimilarMeanings(
        context,
        provider: provider,
        result: result,
        direction: direction,
      );
      if (choice == null || !mounted) return;
      _applyChoice(direction, choice);
    } catch (error) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text('Could not get a hint: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _suggestingDirection = null);
    }
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
}
