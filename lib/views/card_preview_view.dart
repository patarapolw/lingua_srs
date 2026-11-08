import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/lesson.dart';
import '../models/sentence.dart';
import '../models/srs_card.dart';
import '../providers/app_provider.dart';
import '../services/card_preview.dart';
import '../widgets/audio_button.dart';
import '../widgets/emphasis_text.dart';
import '../widgets/markdown_content.dart';

/// Flips through new cards as flashcards without studying them: nothing is
/// rated, so the cards stay new and don't count toward the daily limit.
class CardPreviewView extends StatefulWidget {
  final Lesson lesson;
  final List<PreviewCard> cards;

  /// What the cards were picked by, such as a part of speech, for the title.
  final String? filterLabel;

  const CardPreviewView({
    super.key,
    required this.lesson,
    required this.cards,
    this.filterLabel,
  });

  @override
  State<CardPreviewView> createState() => _CardPreviewViewState();
}

class _CardPreviewViewState extends State<CardPreviewView> {
  int _index = 0;
  bool _revealed = false;
  final FocusNode _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _flip() => setState(() => _revealed = !_revealed);

  void _go(int delta) {
    final next = _index + delta;
    if (next < 0 || next >= widget.cards.length) return;
    setState(() {
      _index = next;
      _revealed = false;
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.space || key == LogicalKeyboardKey.enter) {
      _flip();
    } else if (key == LogicalKeyboardKey.arrowRight) {
      _go(1);
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      _go(-1);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = widget.filterLabel == null
        ? 'Preview new cards'
        : 'Preview new cards · ${widget.filterLabel}';
    final cards = widget.cards;

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: cards.isEmpty
          ? const Center(child: Text('No new cards to preview.'))
          : Focus(
              focusNode: _focus,
              autofocus: true,
              onKeyEvent: _onKey,
              child: Column(
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    color: theme.colorScheme.secondaryContainer,
                    child: Text(
                      'Preview only: these cards are not added to your '
                      'reviews.',
                      style: TextStyle(
                        color: theme.colorScheme.onSecondaryContainer,
                      ),
                    ),
                  ),
                  LinearProgressIndicator(value: (_index + 1) / cards.length),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 700),
                          child: InkWell(
                            key: const ValueKey('preview-card'),
                            borderRadius: BorderRadius.circular(16),
                            onTap: _flip,
                            child: Card(
                              child: Padding(
                                padding: const EdgeInsets.all(24),
                                child: _PreviewFace(
                                  key: ValueKey(
                                    '$_index-${cards[_index].card.id}',
                                  ),
                                  lesson: widget.lesson,
                                  preview: cards[_index],
                                  revealed: _revealed,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                      child: Row(
                        children: [
                          IconButton.outlined(
                            icon: const Icon(Icons.chevron_left),
                            tooltip: 'Previous card',
                            onPressed: _index > 0 ? () => _go(-1) : null,
                          ),
                          Expanded(
                            child: Center(
                              child: Text(
                                '${_index + 1} / ${cards.length}',
                                style: theme.textTheme.titleMedium,
                              ),
                            ),
                          ),
                          FilledButton.tonal(
                            onPressed: _flip,
                            child: Text(_revealed ? 'Show front' : 'Flip'),
                          ),
                          const SizedBox(width: 8),
                          IconButton.outlined(
                            icon: const Icon(Icons.chevron_right),
                            tooltip: 'Next card',
                            onPressed: _index < cards.length - 1
                                ? () => _go(1)
                                : null,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

class _PreviewFace extends StatelessWidget {
  final Lesson lesson;
  final PreviewCard preview;
  final bool revealed;

  const _PreviewFace({
    super.key,
    required this.lesson,
    required this.preview,
    required this.revealed,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final vocab = preview.vocab;
    final toNative = preview.direction == CardDirection.targetToNative;
    final sentences = context.read<AppProvider>().getSentencesForVocab(vocab);
    // The first example sentence, so the same card always looks the same.
    final Sentence? sentence = sentences.isEmpty ? null : sentences.first;
    final hint = vocab.frontHintFor(preview.direction);

    final header = Row(
      children: [
        Chip(
          label: Text(vocab.pos.replaceAll('_', ' ').toUpperCase()),
          visualDensity: VisualDensity.compact,
        ),
        const SizedBox(width: 8),
        Text(
          toNative ? 'KO ➔ EN' : 'EN ➔ KO Cloze',
          style: theme.textTheme.labelMedium,
        ),
        const Spacer(),
        Text(
          revealed ? 'BACK' : 'FRONT',
          style: theme.textTheme.labelSmall?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );

    if (!revealed) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          const SizedBox(height: 24),
          Text(
            toNative ? vocab.targetWord : vocab.translation,
            textAlign: TextAlign.center,
            style: theme.textTheme.displaySmall?.copyWith(
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.primary,
            ),
          ),
          if (hint.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                hint,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontStyle: FontStyle.italic,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          if (sentence != null) ...[
            const SizedBox(height: 20),
            EmphasisText(
              toNative
                  ? vocab.targetTextFor(sentence)
                  : vocab.clozeFor(sentence),
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(height: 1.4),
            ),
          ],
          const SizedBox(height: 24),
          Text(
            'Tap the card or press Space to flip',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        const SizedBox(height: 24),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(
              child: Text(
                vocab.targetWord,
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
            AudioButton(
              audioUrl: vocab.playableAudioUrl,
              fallbackText: vocab.speechText,
              language: lesson.targetLanguage,
              compact: true,
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          vocab.translation,
          textAlign: TextAlign.center,
          style: theme.textTheme.titleLarge,
        ),
        if (sentence != null) ...[
          const SizedBox(height: 20),
          EmphasisText(
            vocab.targetTextFor(sentence),
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          EmphasisText(
            vocab.translationTextFor(sentence),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        if (vocab.notes.isNotEmpty) ...[
          const SizedBox(height: 16),
          MarkdownContent(content: vocab.notes),
        ],
      ],
    );
  }
}
