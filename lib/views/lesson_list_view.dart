import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/lesson.dart';
import '../providers/app_provider.dart';
import 'lesson_detail_view.dart';
import 'study_view.dart';
import 'yaml_import_view.dart';

class LessonListView extends StatelessWidget {
  final VoidCallback? onToggleTheme;
  final bool isDarkMode;

  const LessonListView({
    super.key,
    this.onToggleTheme,
    this.isDarkMode = false,
  });

  void _showCreateLessonDialog(BuildContext context) {
    final titleCtrl = TextEditingController();
    final targetLangCtrl = TextEditingController(text: 'ko');
    final nativeLangCtrl = TextEditingController(text: 'en');

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Create New Lesson'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleCtrl,
              decoration: const InputDecoration(
                labelText: 'Lesson Title (e.g. Unit 3/Lesson 1)',
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: targetLangCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Target Lang (e.g. ko, ja, es)',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: nativeLangCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Native Lang (e.g. en)',
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (titleCtrl.text.trim().isNotEmpty) {
                final newLesson = Lesson(
                  title: titleCtrl.text.trim(),
                  targetLanguage: targetLangCtrl.text.trim(),
                  nativeLanguage: nativeLangCtrl.text.trim(),
                );
                final provider = context.read<AppProvider>();
                provider.lessons.add(newLesson);
                provider.saveState();
                Navigator.pop(ctx);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => LessonDetailView(lessonId: newLesson.id),
                  ),
                );
              }
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  void _confirmResetLesson(BuildContext context, Lesson lesson) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Reset SRS Progress for "${lesson.displayTitle}"?'),
        content: const Text(
          'This will reset all vocabulary card repetitions, intervals, and review dates in this lesson back to New. Are you sure?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.orange.shade800,
            ),
            onPressed: () {
              context.read<AppProvider>().resetLessonSrs(lesson.id);
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    'Reset SRS progress for "${lesson.displayTitle}".',
                  ),
                ),
              );
            },
            child: const Text('Reset to New'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppProvider>();
    final theme = Theme.of(context);

    int totalDue = 0;
    int totalCards = 0;
    final activeCardIds = <String>{};
    final dueCardIds = <String>{};
    for (final l in provider.lessons) {
      for (final vocab in l.vocabularies) {
        for (final card in [
          vocab.cardTargetToNative,
          vocab.cardNativeToTarget,
        ]) {
          if (!card.isEnabled) continue;
          if (activeCardIds.add(card.id)) totalCards++;
          if (card.isDue && dueCardIds.add(card.id)) totalDue++;
        }
      }
    }

    final lessonsByUnit = <String?, List<Lesson>>{};
    for (final lesson in provider.lessons) {
      lessonsByUnit
          .putIfAbsent(lesson.effectiveUnitTitle, () => [])
          .add(lesson);
    }
    final lessonRows = <Object>[];
    for (final entry in lessonsByUnit.entries) {
      if (entry.key != null) lessonRows.add(entry.key!);
      lessonRows.addAll(entry.value);
    }

    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.auto_stories_rounded),
            SizedBox(width: 10),
            Text('LinguaSRS'),
          ],
        ),
        actions: [
          // Autoplay toggle
          Tooltip(
            message: 'Audio Autoplay on Answer',
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  provider.autoplayAudio ? Icons.volume_up : Icons.volume_off,
                  size: 20,
                  color: provider.autoplayAudio
                      ? theme.colorScheme.primary
                      : theme.colorScheme.outline,
                ),
                Switch(
                  value: provider.autoplayAudio,
                  onChanged: (_) => provider.toggleAutoplay(),
                ),
              ],
            ),
          ),
          const SizedBox(width: 4),
          if (onToggleTheme != null)
            IconButton(
              icon: Icon(isDarkMode ? Icons.light_mode : Icons.dark_mode),
              tooltip: 'Toggle Theme',
              onPressed: onToggleTheme,
            ),
          const SizedBox(width: 8),
          FilledButton.icon(
            icon: const Icon(Icons.code),
            label: const Text('Import YAML'),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const YamlImportView()),
              );
            },
          ),
          const SizedBox(width: 16),
        ],
      ),
      body: provider.isLoading
          ? const Center(child: CircularProgressIndicator())
          : CustomScrollView(
              slivers: [
                // Top Statistics Banner
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    child: Card(
                      elevation: 2,
                      color: theme.colorScheme.primaryContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Daily Review Queue',
                                    style: theme.textTheme.titleMedium
                                        ?.copyWith(
                                          fontWeight: FontWeight.bold,
                                          color: theme
                                              .colorScheme
                                              .onPrimaryContainer,
                                        ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    '$totalDue cards due today across ${provider.lessons.length} lessons ($totalCards active cards total)',
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      color: theme
                                          .colorScheme
                                          .onPrimaryContainer
                                          .withValues(alpha: 0.8),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            FilledButton.icon(
                              style: FilledButton.styleFrom(
                                backgroundColor: theme.colorScheme.primary,
                                foregroundColor: theme.colorScheme.onPrimary,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 20,
                                  vertical: 14,
                                ),
                              ),
                              icon: const Icon(Icons.bolt_rounded),
                              label: Text('Study All Due ($totalDue)'),
                              onPressed: totalDue == 0
                                  ? null
                                  : () {
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (_) => const StudyView(),
                                        ),
                                      );
                                    },
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),

                // Lessons Section Header
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Your Lessons',
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        TextButton.icon(
                          icon: const Icon(Icons.add),
                          label: const Text('New Lesson'),
                          onPressed: () => _showCreateLessonDialog(context),
                        ),
                      ],
                    ),
                  ),
                ),

                // Lessons Grid / List
                if (provider.lessons.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.library_books_outlined,
                            size: 64,
                            color: theme.colorScheme.outline,
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            'No lessons found. Import from YAML or create one!',
                          ),
                          const SizedBox(height: 16),
                          FilledButton.icon(
                            icon: const Icon(Icons.code),
                            label: const Text('Import Sample YAML'),
                            onPressed: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => const YamlImportView(),
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    sliver: SliverList(
                      delegate: SliverChildBuilderDelegate((context, idx) {
                        final row = lessonRows[idx];
                        if (row is String) {
                          return Padding(
                            padding: const EdgeInsets.fromLTRB(4, 20, 4, 4),
                            child: Text(
                              row,
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: theme.colorScheme.primary,
                              ),
                            ),
                          );
                        }
                        final lesson = row as Lesson;
                        final due = lesson.dueCardsCount;
                        final active = lesson.activeCardsCount;

                        return Card(
                          margin: const EdgeInsets.symmetric(vertical: 6),
                          elevation: 1,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 10,
                            ),
                            leading: CircleAvatar(
                              radius: 24,
                              backgroundColor:
                                  theme.colorScheme.secondaryContainer,
                              child: Text(
                                lesson.targetLanguage.toUpperCase(),
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: theme.colorScheme.onSecondaryContainer,
                                ),
                              ),
                            ),
                            title: Text(
                              lesson.displayTitle,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 17,
                              ),
                            ),
                            subtitle: Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Row(
                                children: [
                                  Text(
                                    '${lesson.vocabularies.length} Words • $active Cards',
                                  ),
                                  const SizedBox(width: 8),
                                  if (due > 0)
                                    Badge(
                                      label: Text('$due Due'),
                                      backgroundColor: Colors.amber.shade800,
                                    ),
                                ],
                              ),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                FilledButton.tonalIcon(
                                  icon: const Icon(Icons.play_arrow, size: 18),
                                  label: const Text('Study'),
                                  onPressed: active == 0
                                      ? null
                                      : () {
                                          Navigator.push(
                                            context,
                                            MaterialPageRoute(
                                              builder: (_) => StudyView(
                                                lessonId: lesson.id,
                                              ),
                                            ),
                                          );
                                        },
                                ),
                                const SizedBox(width: 8),
                                IconButton(
                                  icon: const Icon(
                                    Icons.arrow_forward_ios,
                                    size: 16,
                                  ),
                                  tooltip: 'View Vocabulary',
                                  onPressed: () {
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => LessonDetailView(
                                          lessonId: lesson.id,
                                        ),
                                      ),
                                    );
                                  },
                                ),
                                PopupMenuButton<String>(
                                  onSelected: (val) {
                                    if (val == 'reset_srs') {
                                      _confirmResetLesson(context, lesson);
                                    } else if (val == 'delete') {
                                      provider.deleteLesson(lesson.id);
                                    }
                                  },
                                  itemBuilder: (ctx) => [
                                    const PopupMenuItem(
                                      value: 'reset_srs',
                                      child: Row(
                                        children: [
                                          Icon(
                                            Icons.restart_alt,
                                            color: Colors.orange,
                                            size: 18,
                                          ),
                                          SizedBox(width: 8),
                                          Text('Reset SRS Progress'),
                                        ],
                                      ),
                                    ),
                                    const PopupMenuItem(
                                      value: 'delete',
                                      child: Row(
                                        children: [
                                          Icon(
                                            Icons.delete,
                                            color: Colors.red,
                                            size: 18,
                                          ),
                                          SizedBox(width: 8),
                                          Text(
                                            'Delete Lesson',
                                            style: TextStyle(color: Colors.red),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                            onTap: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) =>
                                      LessonDetailView(lessonId: lesson.id),
                                ),
                              );
                            },
                          ),
                        );
                      }, childCount: lessonRows.length),
                    ),
                  ),
              ],
            ),
    );
  }
}
