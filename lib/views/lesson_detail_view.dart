import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/lesson.dart';
import '../models/vocab_item.dart';
import '../models/srs_card.dart';
import '../providers/app_provider.dart';
import '../widgets/audio_button.dart';
import '../widgets/markdown_content.dart';
import 'vocab_edit_dialog.dart';
import 'study_view.dart';
import 'yaml_import_view.dart';

/// Short state shown on a card chip: Hidden, New, Due, or its interval.
String cardStatusLabel(SrsCard card) {
  if (!card.isEnabled) return 'Hidden';
  if (card.isNewCard) return 'New';
  if (card.isDue) return 'Due';
  return '${card.interval}d';
}

/// Label of a lesson's Study button: how many cards the session will hold.
/// Only as many new cards as the daily limit still allows are counted.
String lessonStudyLabel({
  required int due,
  required int newCards,
  required int remainingNewCards,
}) {
  final fresh = newCards < remainingNewCards ? newCards : remainingNewCards;
  return due + fresh > 0 ? 'Study (${due + fresh})' : 'Study';
}

class LessonDetailView extends StatefulWidget {
  final String lessonId;

  const LessonDetailView({super.key, required this.lessonId});

  @override
  State<LessonDetailView> createState() => _LessonDetailViewState();
}

class _SectionNode {
  final String name;
  final Map<String, _SectionNode> children = {};
  final List<VocabItem> vocabularies = [];

  _SectionNode(this.name);

  int get vocabularyCount =>
      vocabularies.length +
      children.values.fold(0, (count, child) => count + child.vocabularyCount);
}

class _SectionRow {
  final List<String> path;
  final int depth;
  final int vocabularyCount;

  _SectionRow(this.path, this.depth, this.vocabularyCount);

  String get key => path.join('\u0000');
  String get parentLabel => path.length < 2
      ? ''
      : '${formatHierarchyPath(path.sublist(0, path.length - 1))} · ';
  String get subtitle =>
      '$parentLabel$vocabularyCount vocabulary ${vocabularyCount == 1 ? 'item' : 'items'}';
}

class _LessonDetailViewState extends State<LessonDetailView> {
  String _selectedCategory = 'All';
  String _searchQuery = '';
  bool _searchOpen = false;
  final TextEditingController _searchCtrl = TextEditingController();
  final Set<String> _collapsedSections = {};

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _confirmResetLesson(Lesson lesson) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Reset SRS progress for "${lesson.displayTitle}"?'),
        content: const Text(
          'All vocabulary cards in this lesson will return to New. Review history and intervals will be cleared.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Reset lesson'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;
    await context.read<AppProvider>().resetLessonSrs(lesson.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Reset SRS progress for "${lesson.displayTitle}".'),
      ),
    );
  }

  Future<void> _confirmResetVocab(VocabItem vocab) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Reset SRS for "${vocab.targetWord}"?'),
        content: const Text(
          'Both card directions will return to New. Review history and intervals will be cleared.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Reset vocabulary'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;
    await context.read<AppProvider>().resetVocabSrs(vocab);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Reset SRS progress for "${vocab.targetWord}".')),
    );
  }

  Future<void> _confirmDeleteVocab(Lesson lesson, VocabItem vocab) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete "${vocab.targetWord}"?'),
        content: const Text(
          'This vocabulary entry will be removed. Its SRS progress will be '
          'reset for any other entries sharing the same vocabulary ID.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete vocabulary'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await context.read<AppProvider>().deleteVocab(lesson.id, vocab);
  }

  Future<void> _confirmDeleteSection(Lesson lesson, _SectionRow section) async {
    final sectionName = section.path.last;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete section "$sectionName"?'),
        content: Text(
          'This will delete the section and all ${section.vocabularyCount} vocabulary '
          'entries inside it, including nested sections.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete section'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await context.read<AppProvider>().deleteSection(lesson.id, section.path);
    setState(() {
      _collapsedSections.removeWhere(
        (key) => key == section.key || key.startsWith('${section.key}\u0000'),
      );
    });
  }

  /// Opens the YAML import prefilled with this lesson's name. Importing under
  /// an existing lesson name adds to it and keeps existing vocabulary.
  void _showAddFromYaml(Lesson lesson) {
    final name = joinHierarchyPath([...lesson.folderPath, lesson.displayTitle]);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => YamlImportView(
          initialLessonName: name,
          initialYaml:
              'vocabulary:\n'
              '  nouns:\n'
              '    - ${lesson.targetLanguage}: ""\n'
              '      ${lesson.nativeLanguage}: ""\n',
        ),
      ),
    );
  }

  /// Warns when an enabled card has the same front prompt as another card.
  /// Uses the same check as the edit dialog; tapping opens it to add a hint.
  List<Widget> _duplicateFrontNotices(
    AppProvider provider,
    Lesson lesson,
    VocabItem vocab,
    ThemeData theme,
  ) {
    final notices = <Widget>[];
    for (final direction in CardDirection.values) {
      final toNative = direction == CardDirection.targetToNative;
      if (!(toNative ? vocab.cardTargetToNative : vocab.cardNativeToTarget)
          .isEnabled) {
        continue;
      }
      final duplicates = provider.getDuplicateFrontVocabularies(
        vocab,
        direction,
      );
      if (duplicates.isEmpty) continue;

      final others = duplicates
          .map((other) => '${other.targetWord} — ${other.translation}')
          .join('; ');
      notices.add(
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: InkWell(
            key: ValueKey('duplicate-front-${vocab.id}-${direction.name}'),
            borderRadius: BorderRadius.circular(6),
            onTap: () =>
                VocabEditDialog.show(context, vocab, lessonId: lesson.id),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  size: 16,
                  color: theme.colorScheme.error,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${toNative ? 'KO ➔ EN' : 'EN ➔ KO'} card has the same '
                    'front as $others. Tap to add a front hint.',
                    style: TextStyle(
                      color: theme.colorScheme.error,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return notices;
  }

  void _showAddVocabDialog(Lesson lesson) {
    final vocab = VocabItem(targetWord: '', translation: '', pos: '');
    VocabEditDialog.show(context, vocab, lessonId: lesson.id, isNew: true).then(
      (_) {
        if (!mounted) return;
        if (vocab.targetWord.isNotEmpty) {
          context.read<AppProvider>().addVocabToLesson(lesson.id, vocab);
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppProvider>();
    final theme = Theme.of(context);

    final Lesson lesson;
    try {
      lesson = provider.lessons.firstWhere((l) => l.id == widget.lessonId);
    } catch (_) {
      return Scaffold(
        appBar: AppBar(title: const Text('Lesson Not Found')),
        body: const Center(child: Text('This lesson could not be found.')),
      );
    }

    // Root vocabulary sections are the lesson's filter categories.
    final categories =
        <String>{
            ...lesson.vocabularies.map(
              (vocab) => vocab.effectiveSectionPath.isEmpty
                  ? vocab.pos
                  : vocab.effectiveSectionPath.first,
            ),
          }.toList()
          ..sort(
            (first, second) =>
                first.toLowerCase().compareTo(second.toLowerCase()),
          )
          ..insert(0, 'All');

    // Filter items
    final filtered = lesson.vocabularies.where((v) {
      final sectionPath = v.effectiveSectionPath;
      final rootSection = sectionPath.isEmpty ? v.pos : sectionPath.first;
      if (_selectedCategory != 'All' &&
          rootSection.toLowerCase() != _selectedCategory.toLowerCase()) {
        return false;
      }
      if (_searchQuery.isNotEmpty) {
        final q = _searchQuery.toLowerCase();
        return v.targetWord.toLowerCase().contains(q) ||
            v.translation.toLowerCase().contains(q) ||
            v.notes.toLowerCase().contains(q);
      }
      return true;
    }).toList();

    final rootSection = _SectionNode('');
    for (final vocab in filtered) {
      final path = vocab.effectiveSectionPath.isEmpty
          ? [vocab.pos]
          : vocab.effectiveSectionPath;
      var current = rootSection;
      for (final name in path) {
        current = current.children.putIfAbsent(name, () => _SectionNode(name));
      }
      current.vocabularies.add(vocab);
    }

    void sortSections(_SectionNode node) {
      node.vocabularies.sort(
        (first, second) => first.targetWord.toLowerCase().compareTo(
          second.targetWord.toLowerCase(),
        ),
      );
      final children = node.children.entries.toList()
        ..sort(
          (first, second) =>
              first.key.toLowerCase().compareTo(second.key.toLowerCase()),
        );
      node.children
        ..clear()
        ..addEntries(children);
      for (final child in node.children.values) {
        sortSections(child);
      }
    }

    sortSections(rootSection);
    final displayRows = <Object>[];
    void flattenSections(
      _SectionNode section,
      List<String> parentPath,
      int depth,
    ) {
      for (final entry in section.children.entries) {
        final path = [...parentPath, entry.key];
        final row = _SectionRow(path, depth, entry.value.vocabularyCount);
        displayRows.add(row);
        final child = entry.value;
        final key = row.key;
        if (_collapsedSections.contains(key)) continue;
        displayRows.addAll(child.vocabularies);
        flattenSections(child, path, depth + 1);
      }
    }

    flattenSections(rootSection, const [], 0);

    final compact = MediaQuery.sizeOf(context).width < 700;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (lesson.effectiveUnitTitle != null)
              Text(
                lesson.effectiveUnitTitle!,
                style: theme.textTheme.labelSmall,
              ),
            Text(
              lesson.displayTitle,
              style: compact ? theme.textTheme.titleMedium : null,
            ),
          ],
        ),
        actions: [
          if (!compact)
            IconButton(
              icon: const Icon(Icons.restart_alt),
              tooltip: 'Reset all SRS progress in this lesson',
              onPressed: () => _confirmResetLesson(lesson),
            ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.add_circle_outline),
            tooltip: 'Add vocabulary',
            onSelected: (value) {
              if (value == 'word') _showAddVocabDialog(lesson);
              if (value == 'yaml') _showAddFromYaml(lesson);
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'word', child: Text('Add manually')),
              PopupMenuItem(value: 'yaml', child: Text('Add from YAML')),
            ],
          ),
          if (context.watch<AppProvider>().getRecentMistakesCount(
                lessonId: lesson.id,
              ) >
              0) ...[
            if (compact)
              IconButton(
                icon: Badge(
                  label: Text(
                    '${context.watch<AppProvider>().getRecentMistakesCount(lessonId: lesson.id)}',
                  ),
                  backgroundColor: theme.colorScheme.error,
                  child: const Icon(Icons.history_edu_rounded),
                ),
                tooltip: 'Review recent mistakes',
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => StudyView(
                        lessonId: lesson.id,
                        recentMistakesOnly: true,
                      ),
                    ),
                  );
                },
              )
            else
              FilledButton.tonalIcon(
                style: FilledButton.styleFrom(
                  backgroundColor: theme.colorScheme.errorContainer,
                  foregroundColor: theme.colorScheme.onErrorContainer,
                ),
                icon: const Icon(Icons.history_edu_rounded),
                label: Text(
                  'Mistakes (${context.watch<AppProvider>().getRecentMistakesCount(lessonId: lesson.id)})',
                ),
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => StudyView(
                        lessonId: lesson.id,
                        recentMistakesOnly: true,
                      ),
                    ),
                  );
                },
              ),
            const SizedBox(width: 8),
          ],
          FilledButton.icon(
            icon: const Icon(Icons.play_arrow_rounded),
            label: Text(
              lessonStudyLabel(
                due: lesson.dueCardsCount,
                newCards: lesson.newCardsCount,
                remainingNewCards: context
                    .watch<AppProvider>()
                    .remainingNewCards24h,
              ),
            ),
            onPressed: lesson.activeCardsCount == 0
                ? null
                : () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => StudyView(lessonId: lesson.id),
                      ),
                    );
                  },
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          // Header summary bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: theme.colorScheme.surfaceContainerHighest.withValues(
              alpha: 0.3,
            ),
            child: Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: categories.map((cat) {
                        final isSelected = _selectedCategory == cat;
                        return Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: FilterChip(
                            label: Text(cat.toUpperCase()),
                            selected: isSelected,
                            onSelected: (_) =>
                                setState(() => _selectedCategory = cat),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                if (MediaQuery.sizeOf(context).width >= 700)
                  SizedBox(
                    width: 220,
                    height: 40,
                    child: TextField(
                      controller: _searchCtrl,
                      decoration: InputDecoration(
                        prefixIcon: const Icon(Icons.search, size: 20),
                        hintText: 'Search vocab',
                        contentPadding: EdgeInsets.zero,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                      ),
                      onChanged: (val) =>
                          setState(() => _searchQuery = val.trim()),
                    ),
                  )
                else if (_searchOpen || _searchQuery.isNotEmpty)
                  SizedBox(
                    width: 150,
                    height: 40,
                    child: TextField(
                      controller: _searchCtrl,
                      autofocus: true,
                      decoration: InputDecoration(
                        hintText: 'Search',
                        contentPadding: const EdgeInsets.only(left: 14),
                        suffixIcon: IconButton(
                          icon: const Icon(Icons.close, size: 18),
                          tooltip: 'Close search',
                          onPressed: () => setState(() {
                            _searchOpen = false;
                            _searchQuery = '';
                            _searchCtrl.clear();
                          }),
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                      ),
                      onChanged: (val) =>
                          setState(() => _searchQuery = val.trim()),
                    ),
                  )
                else
                  IconButton(
                    icon: const Icon(Icons.search),
                    tooltip: 'Search vocab',
                    onPressed: () => setState(() => _searchOpen = true),
                  ),
              ],
            ),
          ),

          // List of vocabularies
          Expanded(
            child: filtered.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.menu_book,
                          size: 64,
                          color: theme.colorScheme.outline,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          lesson.vocabularies.isEmpty
                              ? 'No vocabulary items in this lesson yet.'
                              : 'No words matched your filter.',
                          style: theme.textTheme.titleMedium,
                        ),
                        const SizedBox(height: 12),
                        if (lesson.vocabularies.isEmpty)
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            alignment: WrapAlignment.center,
                            children: [
                              FilledButton.tonalIcon(
                                icon: const Icon(Icons.add),
                                label: const Text('Add vocabulary'),
                                onPressed: () => _showAddVocabDialog(lesson),
                              ),
                              OutlinedButton.icon(
                                icon: const Icon(Icons.code),
                                label: const Text('Add from YAML'),
                                onPressed: () => _showAddFromYaml(lesson),
                              ),
                            ],
                          ),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: displayRows.length,
                    itemBuilder: (context, idx) {
                      final row = displayRows[idx];
                      if (row is _SectionRow) {
                        final isCollapsed = _collapsedSections.contains(
                          row.key,
                        );
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Card(
                            margin: EdgeInsets.only(left: row.depth * 20.0),
                            color: theme.colorScheme.surfaceContainerHighest
                                .withValues(alpha: row.depth == 0 ? 0.75 : 0.4),
                            child: ListTile(
                              leading: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    isCollapsed
                                        ? Icons.chevron_right
                                        : Icons.expand_more,
                                  ),
                                  Icon(
                                    isCollapsed
                                        ? Icons.folder_outlined
                                        : Icons.folder_open_outlined,
                                    color: theme.colorScheme.primary,
                                  ),
                                ],
                              ),
                              title: Text(
                                row.path.last,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              subtitle: Text(row.subtitle),
                              trailing: IconButton(
                                icon: Icon(
                                  Icons.delete_outline,
                                  color: theme.colorScheme.error,
                                ),
                                tooltip: 'Delete section and its vocabulary',
                                onPressed: () =>
                                    _confirmDeleteSection(lesson, row),
                              ),
                              onTap: () => setState(() {
                                if (isCollapsed) {
                                  _collapsedSections.remove(row.key);
                                } else {
                                  _collapsedSections.add(row.key);
                                }
                              }),
                            ),
                          ),
                        );
                      }
                      final vocab = row as VocabItem;
                      final sentences = provider.getSentencesForVocab(vocab);

                      return Padding(
                        padding: EdgeInsets.fromLTRB(
                          vocab.effectiveSectionPath.length * 20.0,
                          4,
                          0,
                          4,
                        ),
                        child: Card(
                          elevation: 1,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // Word header
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Wrap(
                                            crossAxisAlignment:
                                                WrapCrossAlignment.center,
                                            spacing: 10,
                                            children: [
                                              Text(
                                                vocab.targetWord,
                                                style: theme
                                                    .textTheme
                                                    .headlineSmall
                                                    ?.copyWith(
                                                      fontWeight:
                                                          FontWeight.bold,
                                                      color: theme
                                                          .colorScheme
                                                          .primary,
                                                    ),
                                              ),
                                              Chip(
                                                label: Text(vocab.pos),
                                                visualDensity:
                                                    VisualDensity.compact,
                                                backgroundColor: theme
                                                    .colorScheme
                                                    .secondaryContainer,
                                              ),
                                              AudioButton(
                                                audioUrl: vocab.audioUrl,
                                                fallbackText: vocab.speechText,
                                                language: lesson.targetLanguage,
                                                compact: true,
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            vocab.translation,
                                            style: theme.textTheme.titleMedium,
                                          ),
                                          ..._duplicateFrontNotices(
                                            provider,
                                            lesson,
                                            vocab,
                                            theme,
                                          ),
                                        ],
                                      ),
                                    ),
                                    PopupMenuButton<String>(
                                      tooltip: 'More actions',
                                      onSelected: (action) {
                                        switch (action) {
                                          case 'edit':
                                            VocabEditDialog.show(
                                              context,
                                              vocab,
                                              lessonId: lesson.id,
                                            );
                                          case 'reset':
                                            _confirmResetVocab(vocab);
                                          case 'delete':
                                            _confirmDeleteVocab(lesson, vocab);
                                        }
                                      },
                                      itemBuilder: (_) => const [
                                        PopupMenuItem(
                                          value: 'edit',
                                          child: ListTile(
                                            leading: Icon(Icons.edit_outlined),
                                            title: Text('Edit'),
                                            contentPadding: EdgeInsets.zero,
                                          ),
                                        ),
                                        PopupMenuItem(
                                          value: 'reset',
                                          child: ListTile(
                                            leading: Icon(Icons.restart_alt),
                                            title: Text('Reset SRS'),
                                            contentPadding: EdgeInsets.zero,
                                          ),
                                        ),
                                        PopupMenuItem(
                                          value: 'delete',
                                          child: ListTile(
                                            leading: Icon(
                                              Icons.delete_outline,
                                              color: Colors.red,
                                            ),
                                            title: Text('Delete'),
                                            contentPadding: EdgeInsets.zero,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),

                                // Notes if available
                                if (vocab.notes.isNotEmpty) ...[
                                  const SizedBox(height: 8),
                                  Container(
                                    padding: const EdgeInsets.all(10),
                                    decoration: BoxDecoration(
                                      color: theme
                                          .colorScheme
                                          .surfaceContainerHighest
                                          .withValues(alpha: 0.4),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: MarkdownContent(
                                      content: vocab.notes,
                                    ),
                                  ),
                                ],

                                // Sentences list
                                if (sentences.isNotEmpty) ...[
                                  const SizedBox(height: 8),
                                  ...sentences.map(
                                    (s) => Padding(
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 2,
                                      ),
                                      child: Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          const Text(
                                            '• ',
                                            style: TextStyle(
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                MarkdownContent(
                                                  content: s.targetText,
                                                ),
                                                MarkdownContent(
                                                  content: s.translationText,
                                                  style: theme
                                                      .textTheme
                                                      .bodySmall
                                                      ?.copyWith(
                                                        color: theme
                                                            .colorScheme
                                                            .onSurfaceVariant,
                                                      ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          AudioButton(
                                            audioUrl: s.audioUrl,
                                            fallbackText: s.speechText,
                                            language: lesson.targetLanguage,
                                            compact: true,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],

                                const SizedBox(height: 12),
                                const Divider(),

                                // Direction Toggles Bar
                                Wrap(
                                  spacing: 16,
                                  runSpacing: 8,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    // KO -> EN toggle
                                    FilterChip(
                                      avatar: Icon(
                                        vocab.cardTargetToNative.isEnabled
                                            ? Icons.visibility
                                            : Icons.visibility_off,
                                        size: 16,
                                      ),
                                      label: Text(
                                        'KO ➔ EN (${cardStatusLabel(vocab.cardTargetToNative)})',
                                      ),
                                      selected:
                                          vocab.cardTargetToNative.isEnabled,
                                      onSelected: (_) {
                                        provider.toggleCardDirection(
                                          vocab,
                                          CardDirection.targetToNative,
                                        );
                                      },
                                    ),

                                    // EN -> KO toggle
                                    FilterChip(
                                      avatar: Icon(
                                        vocab.cardNativeToTarget.isEnabled
                                            ? Icons.visibility
                                            : Icons.visibility_off,
                                        size: 16,
                                      ),
                                      label: Text(
                                        'EN ➔ KO Cloze (${cardStatusLabel(vocab.cardNativeToTarget)})',
                                      ),
                                      selected:
                                          vocab.cardNativeToTarget.isEnabled,
                                      onSelected: (_) {
                                        provider.toggleCardDirection(
                                          vocab,
                                          CardDirection.nativeToTarget,
                                        );
                                      },
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
