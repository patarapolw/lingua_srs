import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/vocab_merge_record.dart';
import '../providers/app_provider.dart';
import '../services/vocab_pool_search.dart';
import 'vocab_edit_dialog.dart';

/// Every distinct vocabulary across all lessons, searchable in Korean and
/// English. Words shared by several lessons show once.
class VocabPoolView extends StatefulWidget {
  const VocabPoolView({super.key});

  @override
  State<VocabPoolView> createState() => _VocabPoolViewState();
}

class _VocabPoolViewState extends State<VocabPoolView> {
  final TextEditingController _searchCtrl = TextEditingController();
  String _filter = '';
  String? _pos;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _edit(AppProvider provider, VocabGroup group) {
    String? lessonId;
    for (final lesson in provider.lessons) {
      if (lesson.vocabularies.contains(group.entry)) {
        lessonId = lesson.id;
        break;
      }
    }
    VocabEditDialog.show(context, group.entry, lessonId: lessonId);
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppProvider>();
    final theme = Theme.of(context);

    final groups = provider.vocabGroups;
    final posOptions = VocabPoolSearch.posOptions(groups);
    // The selected part of speech can disappear after an edit or a merge.
    final selectedPos = posOptions.contains(_pos) ? _pos : null;
    final filtered = VocabPoolSearch.search(_filter, groups, pos: selectedPos);
    final isFiltered = _filter.isNotEmpty || selectedPos != null;

    // On a narrow screen the count goes under the search box, so the box
    // keeps room for its whole hint.
    final narrow = MediaQuery.sizeOf(context).width < 700;
    final searchField = TextField(
      controller: _searchCtrl,
      decoration: InputDecoration(
        prefixIcon: const Icon(Icons.search),
        hintText: 'Search Korean or English',
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 10,
        ),
        suffixIcon: _filter.isNotEmpty
            ? IconButton(
                icon: const Icon(Icons.clear),
                tooltip: 'Clear search',
                onPressed: () {
                  _searchCtrl.clear();
                  setState(() => _filter = '');
                },
              )
            : null,
      ),
      onChanged: (val) => setState(() => _filter = val.trim()),
    );
    final countChip = Chip(
      avatar: const Icon(Icons.translate, size: 18),
      label: Text(
        isFiltered
            ? '${filtered.length} of ${groups.length} words'
            : '${groups.length} words',
      ),
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Vocab Pool')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: narrow
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      searchField,
                      const SizedBox(height: 8),
                      countChip,
                    ],
                  )
                : Row(
                    children: [
                      Expanded(child: searchField),
                      const SizedBox(width: 16),
                      countChip,
                    ],
                  ),
          ),
          if (posOptions.isNotEmpty)
            SizedBox(
              height: 48,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      label: const Text('All'),
                      selected: selectedPos == null,
                      onSelected: (_) => setState(() => _pos = null),
                    ),
                  ),
                  for (final pos in posOptions)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: FilterChip(
                        label: Text(VocabPoolSearch.posLabel(pos)),
                        selected: selectedPos == pos,
                        onSelected: (_) => setState(() => _pos = pos),
                      ),
                    ),
                ],
              ),
            ),
          const Divider(),
          Expanded(
            child: filtered.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.translate,
                          size: 64,
                          color: theme.colorScheme.outline,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          groups.isEmpty
                              ? 'The Vocab Pool is currently empty.'
                              : 'No vocabulary matched your query.',
                          style: theme.textTheme.titleMedium,
                        ),
                      ],
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    itemCount: filtered.length,
                    separatorBuilder: (context, index) =>
                        const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final group = filtered[index];
                      final entry = group.entry;
                      return Card(
                        key: ValueKey('vocab-pool-${group.id}'),
                        elevation: 1,
                        clipBehavior: Clip.antiAlias,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: InkWell(
                          onTap: () => _edit(provider, group),
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  entry.targetWord,
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  entry.translation,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 4,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    if (entry.pos.trim().isNotEmpty)
                                      Badge(
                                        label: Text(
                                          VocabPoolSearch.posLabel(entry.pos),
                                        ),
                                        backgroundColor: theme
                                            .colorScheme
                                            .secondaryContainer,
                                        textColor: theme
                                            .colorScheme
                                            .onSecondaryContainer,
                                      ),
                                    Text(
                                      group.lessonTitles.join(' · '),
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                            color: theme.colorScheme.outline,
                                          ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
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
