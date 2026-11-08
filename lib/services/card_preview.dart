import '../models/srs_card.dart';
import '../models/vocab_item.dart';

/// One card shown in a preview: a word and the direction it is asked in.
class PreviewCard {
  final VocabItem vocab;
  final CardDirection direction;

  const PreviewCard(this.vocab, this.direction);

  SrsCard get card => direction == CardDirection.targetToNative
      ? vocab.cardTargetToNative
      : vocab.cardNativeToTarget;
}

/// The new cards of [vocabularies] to preview, in the given order: each
/// word's KO ➔ EN card, then its EN ➔ KO card. Hidden, suspended and started
/// cards are left out, and a card shared by several words shows once.
List<PreviewCard> previewNewCards(Iterable<VocabItem> vocabularies) {
  final seen = <String>{};
  final cards = <PreviewCard>[];
  for (final vocab in vocabularies) {
    for (final direction in CardDirection.values) {
      final preview = PreviewCard(vocab, direction);
      if (!preview.card.isNewCard) continue;
      if (!seen.add(preview.card.id)) continue;
      cards.add(preview);
    }
  }
  return cards;
}
