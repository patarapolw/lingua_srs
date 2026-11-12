import 'package:material_ui/material_ui.dart';

import '../models/vocab_item.dart';

/// A word's reading and the other ways it is written, under the word: the
/// reading as a line of text, then one small tag per other form
/// (*Traditional:* 學生, *Hanja:* 學生). Tapping a tag opens
/// [CharacterZoom]. Nothing is built when the word has neither.
class VocabForms extends StatelessWidget {
  const VocabForms({
    super.key,
    required this.vocab,
    this.alignment = WrapAlignment.center,
    this.readingStyle,
  });

  final VocabItem vocab;

  /// How the reading and the tags line up: centred on a card, at the start
  /// in a list.
  final WrapAlignment alignment;

  /// The reading's style; [TextTheme.titleMedium] by default.
  final TextStyle? readingStyle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reading = vocab.reading.trim();
    final forms = vocab.otherForms;
    if (reading.isEmpty && forms.isEmpty) return const SizedBox.shrink();
    final muted = theme.colorScheme.onSurfaceVariant;
    final textAlign = switch (alignment) {
      WrapAlignment.center => TextAlign.center,
      WrapAlignment.end => TextAlign.end,
      _ => TextAlign.start,
    };
    return Column(
      crossAxisAlignment: switch (alignment) {
        WrapAlignment.center => CrossAxisAlignment.center,
        WrapAlignment.end => CrossAxisAlignment.end,
        _ => CrossAxisAlignment.start,
      },
      mainAxisSize: MainAxisSize.min,
      children: [
        if (reading.isNotEmpty)
          Text(
            reading,
            key: const ValueKey('vocab-reading'),
            style: (readingStyle ?? theme.textTheme.titleMedium)?.copyWith(
              color: muted,
            ),
            textAlign: textAlign,
          ),
        if (forms.isNotEmpty)
          Padding(
            key: const ValueKey('vocab-other-forms'),
            padding: const EdgeInsets.only(top: 8, bottom: 4),
            child: Wrap(
              alignment: alignment,
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final other in forms)
                  Material(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: CharacterZoom.canZoom(vocab)
                          ? () => CharacterZoom.show(context, vocab)
                          : null,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        child: Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: '${other.label}: ',
                                style: theme.textTheme.labelMedium?.copyWith(
                                  color: muted,
                                ),
                              ),
                              TextSpan(
                                text: other.form,
                                style: theme.textTheme.titleMedium,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// The word's Han characters drawn large in a dialog, to see the strokes:
/// the word and its other forms (simplified, traditional, Hanja) that are
/// written in Han characters. A Hangul word is left out, so a Korean word
/// shows its Hanja, or the word itself when `ko:` is already in Hanja.
/// Pinch or scroll to zoom further.
/// The dialog is as wide as its characters, up to 440 pixels, and wraps
/// the forms onto more rows past that.
class CharacterZoom extends StatelessWidget {
  const CharacterZoom({super.key, required this.vocab});

  final VocabItem vocab;

  static final _han = RegExp(r'\p{Script=Han}', unicode: true);

  /// The forms of [vocab] that have Han characters, the word first and
  /// unlabelled, then its other forms with their labels.
  static List<({String label, String form})> zoomForms(VocabItem vocab) => [
    for (final f in [
      (label: '', form: vocab.targetWord.trim()),
      ...vocab.otherForms,
    ])
      if (_han.hasMatch(f.form)) f,
  ];

  /// Whether [vocab] has Han characters to zoom into, in the word or in
  /// another form of it.
  static bool canZoom(VocabItem vocab) => zoomForms(vocab).isNotEmpty;

  static Future<void> show(BuildContext context, VocabItem vocab) =>
      showDialog<void>(
        context: context,
        builder: (_) => CharacterZoom(vocab: vocab),
      );

  /// Wraps [child] (the word as shown) so that tapping it opens the zoom,
  /// when [canZoom]; otherwise returns [child] as it is.
  static Widget tappable({
    required BuildContext context,
    required VocabItem vocab,
    required Widget child,
  }) {
    if (!canZoom(vocab)) return child;
    return Tooltip(
      message: 'Zoom characters',
      child: InkWell(
        key: const ValueKey('vocab-zoom-word'),
        borderRadius: BorderRadius.circular(8),
        onTap: () => show(context, vocab),
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final word = vocab.targetWord.trim();
    final forms = zoomForms(vocab);
    // The heading says what the characters read as: the reading, and the
    // word when it is not drawn below (a Hangul word with its Hanja).
    final heading = {
      if (forms.every((f) => f.form != word)) word,
      vocab.reading.trim(),
    }.where((text) => text.isNotEmpty).join(' · ');
    return Dialog(
      key: const ValueKey('character-zoom'),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440, maxHeight: 560),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 8, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      heading,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              Flexible(
                child: InteractiveViewer(
                  maxScale: 6,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.only(right: 16),
                    child: Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 24,
                      runSpacing: 16,
                      children: [
                        for (final f in forms)
                          Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                f.form,
                                style: theme.textTheme.displayLarge?.copyWith(
                                  fontSize: 96,
                                  height: 1.2,
                                  color: f.label.isEmpty
                                      ? theme.colorScheme.primary
                                      : null,
                                ),
                              ),
                              if (f.label.isNotEmpty)
                                Text(
                                  f.label,
                                  style: theme.textTheme.labelLarge?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
