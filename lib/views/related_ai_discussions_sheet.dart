import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/vocab_merge_record.dart';
import '../providers/app_provider.dart';
import '../services/ai_discussion_search.dart';
import '../widgets/ai_discussion_suggestion_tile.dart';

/// Lists discussions related to [discussionId] and returns the one the learner
/// picks, or null. The search box starts as [suggestedQuery] (the word), so
/// the suggestions are there without typing; editing it turns the list into a
/// plain search.
Future<AiDiscussionSummary?> showRelatedAiDiscussions(
  BuildContext context, {
  required String discussionId,
  required String suggestedQuery,
}) {
  return showModalBottomSheet<AiDiscussionSummary>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => _RelatedAiDiscussionsSheet(
      discussionId: discussionId,
      suggestedQuery: suggestedQuery,
    ),
  );
}

class _RelatedAiDiscussionsSheet extends StatefulWidget {
  const _RelatedAiDiscussionsSheet({
    required this.discussionId,
    required this.suggestedQuery,
  });

  final String discussionId;
  final String suggestedQuery;

  @override
  State<_RelatedAiDiscussionsSheet> createState() =>
      _RelatedAiDiscussionsSheetState();
}

class _RelatedAiDiscussionsSheetState
    extends State<_RelatedAiDiscussionsSheet> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.suggestedQuery,
  );
  late final List<VocabGroup> _groups;
  late final List<AiDiscussionSummary> _discussions;

  @override
  void initState() {
    super.initState();
    // Read once: the lists do not change while the sheet is open.
    final provider = context.read<AppProvider>();
    _groups = provider.vocabGroups;
    _discussions = provider.aiDiscussionSummaries;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final query = _controller.text;
    final results = AiDiscussionRelated.forPanel(
      discussionId: widget.discussionId,
      query: query,
      suggestedQuery: widget.suggestedQuery,
      groups: _groups,
      discussions: _discussions,
    );
    final untouched = query.trim() == widget.suggestedQuery.trim();

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.8,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Related discussions', style: theme.textTheme.titleMedium),
              const SizedBox(height: 12),
              TextField(
                controller: _controller,
                onChanged: (_) => setState(() {}),
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  labelText: 'Search discussions',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: query.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Clear search',
                          icon: const Icon(Icons.close),
                          onPressed: () {
                            _controller.clear();
                            setState(() {});
                          },
                        ),
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              Flexible(
                child: results.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(vertical: 24),
                        child: Center(
                          child: Text(
                            untouched
                                ? 'No related discussions yet. Edit the search to look further.'
                                : 'No discussions match "${query.trim()}".',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      )
                    : ListView(
                        shrinkWrap: true,
                        children: [
                          for (final suggestion in results)
                            AiDiscussionSuggestionTile(
                              suggestion: suggestion,
                              onTap: () =>
                                  Navigator.of(context)
                                      .pop(suggestion.discussion),
                            ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
