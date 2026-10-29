import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/app_provider.dart';
import '../services/ai_discussion_search.dart';
import '../widgets/emphasis_text.dart';
import 'ai_discussion_dialog.dart';

class RecentAiDiscussionsView extends StatefulWidget {
  const RecentAiDiscussionsView({super.key});

  @override
  State<RecentAiDiscussionsView> createState() =>
      _RecentAiDiscussionsViewState();
}

class _RecentAiDiscussionsViewState extends State<RecentAiDiscussionsView> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _setQuery(String query) => setState(() => _query = query);

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppProvider>();
    final saved = provider.aiDiscussionSummaries;
    final discussions = AiDiscussionSearch.search(_query, saved);

    return Scaffold(
      appBar: AppBar(title: const Text('Recent Discussions')),
      body: provider.isLoading
          ? const Center(child: CircularProgressIndicator())
          : saved.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.forum_outlined,
                      size: 48,
                      color: Theme.of(context).colorScheme.outline,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'No discussions yet',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Ask AI about a vocabulary word while studying to start a discussion.',
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            )
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: TextField(
                    controller: _searchController,
                    onChanged: _setQuery,
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      hintText: 'Search vocab, sentences or answers',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: _query.isEmpty
                          ? null
                          : IconButton(
                              tooltip: 'Clear search',
                              icon: const Icon(Icons.clear),
                              onPressed: () {
                                _searchController.clear();
                                _setQuery('');
                              },
                            ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: discussions.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              'No discussions match "${_query.trim()}".',
                              textAlign: TextAlign.center,
                            ),
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.all(16),
                          itemCount: discussions.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 8),
                          itemBuilder: (context, index) =>
                              _DiscussionCard(discussion: discussions[index]),
                        ),
                ),
              ],
            ),
    );
  }
}

class _DiscussionCard extends StatelessWidget {
  const _DiscussionCard({required this.discussion});

  final AiDiscussionSummary discussion;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: const CircleAvatar(child: Icon(Icons.forum_outlined)),
        // The date sits beside the title: ListTile limits its trailing widget
        // to 56px, which a date that wraps would exceed. Deleting is done
        // inside the discussion, not from the list.
        title: Row(
          children: [
            Expanded(
              child: Text(
                discussion.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              _formatUpdatedAt(discussion.updatedAt),
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (discussion.vocab?.translation case final translation
                when translation != null && translation.trim().isNotEmpty)
              Text(translation, maxLines: 1, overflow: TextOverflow.ellipsis),
            if (discussion.sentence?.targetText.trim() case final s?
                when s.isNotEmpty)
              Padding(
                padding: const EdgeInsetsGeometry.only(top: 2, bottom: 2),
                child: EmphasisText(
                  s,
                  style: const TextStyle(fontStyle: FontStyle.italic),
                ),
              ),
            Text(
              discussion.preview,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
        onTap: () => showAiDiscussion(context, discussion),
      ),
    );
  }

  String _formatUpdatedAt(DateTime? updatedAt) {
    if (updatedAt == null) return 'Saved';
    final date = updatedAt.toLocal();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final dateDay = DateTime(date.year, date.month, date.day);
    final dayDifference = today.difference(dateDay).inDays;
    if (dayDifference == 0) {
      return '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    }
    if (dayDifference == 1) return 'Yesterday';
    return '${date.month}/${date.day}/${date.year}';
  }
}
