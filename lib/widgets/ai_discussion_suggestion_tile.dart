import 'package:flutter/material.dart';

import '../services/ai_discussion_search.dart';

/// One saved AI discussion offered next to another, with why it is shown.
class AiDiscussionSuggestionTile extends StatelessWidget {
  const AiDiscussionSuggestionTile({
    super.key,
    required this.suggestion,
    required this.onTap,
  });

  final AiDiscussionSuggestion suggestion;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final discussion = suggestion.discussion;
    final vocab = discussion.vocab;
    final label = suggestion.label;
    final sentence = discussion.sentence?.targetText.trim() ?? '';
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: ListTile(
        dense: true,
        leading: Icon(
          discussion.isLesson
              ? Icons.menu_book_outlined
              : suggestion.sameWord
              ? Icons.forum_outlined
              : Icons.link,
          size: 20,
        ),
        title: Text(
          vocab == null || vocab.translation.trim().isEmpty
              ? discussion.title
              : '${vocab.targetWord} — ${vocab.translation}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (label != null)
              Text(
                label,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
            if (suggestion.sameWord && sentence.isNotEmpty)
              Text(
                sentence,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontStyle: FontStyle.italic),
              ),
            Text(
              discussion.preview,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
        onTap: onTap,
      ),
    );
  }
}
