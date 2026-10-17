import 'package:flutter/material.dart';

import '../models/lesson.dart';

class LessonHierarchyRow {
  final String key;
  final String parentKey;
  final int depth;
  final List<String>? folderPath;
  final Lesson? lesson;
  final int lessonCount;

  const LessonHierarchyRow._({
    required this.key,
    required this.parentKey,
    required this.depth,
    this.folderPath,
    this.lesson,
    this.lessonCount = 0,
  });

  bool get isFolder => folderPath != null;
}

class LessonHierarchyView extends StatelessWidget {
  final List<Lesson> lessons;
  final Map<String, int> order;
  final Map<String, bool> folderExpansion;
  final Widget Function(BuildContext context, Lesson lesson) lessonBuilder;
  final Future<void> Function(List<String> siblingKeys) onOrderChanged;
  final Future<void> Function(String folderKey, bool expanded)
  onFolderExpansionChanged;
  final void Function(List<String> folderPath) onMoveFolder;
  final void Function(List<String> folderPath, int lessonCount) onDeleteFolder;

  static const double _indentPerLevel = 24;

  const LessonHierarchyView({
    super.key,
    required this.lessons,
    required this.order,
    required this.folderExpansion,
    required this.lessonBuilder,
    required this.onOrderChanged,
    required this.onFolderExpansionChanged,
    required this.onMoveFolder,
    required this.onDeleteFolder,
  });

  @override
  Widget build(BuildContext context) {
    final roots = _buildTree();
    final rows = <LessonHierarchyRow>[];
    _appendVisibleRows(roots, rows, 'root', 0);

    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      itemCount: rows.length,
      onReorderItem: (oldIndex, newIndex) {
        if (oldIndex == newIndex || oldIndex < 0 || oldIndex >= rows.length) {
          return;
        }
        final reordered = [...rows];
        final moved = reordered.removeAt(oldIndex);
        final insertionIndex = newIndex.clamp(0, reordered.length).toInt();
        final validSiblingGaps = <int>{};
        for (var index = 0; index < reordered.length; index++) {
          final sibling = reordered[index];
          if (sibling.parentKey != moved.parentKey) continue;
          validSiblingGaps.add(index);
          var subtreeEnd = index + 1;
          if (sibling.isFolder) {
            while (subtreeEnd < reordered.length &&
                reordered[subtreeEnd].depth > sibling.depth) {
              subtreeEnd++;
            }
          }
          for (var gap = index; gap <= subtreeEnd; gap++) {
            validSiblingGaps.add(gap);
          }
        }
        if (!validSiblingGaps.contains(insertionIndex)) return;
        reordered.insert(insertionIndex, moved);
        final siblingKeys = reordered
            .where((row) => row.parentKey == moved.parentKey)
            .map((row) => row.key)
            .toList();
        onOrderChanged(siblingKeys);
      },
      itemBuilder: (context, index) {
        final row = rows[index];
        final child = row.isFolder
            ? _folderRow(context, row, index)
            : ReorderableDelayedDragStartListener(
                index: index,
                child: Padding(
                  padding: EdgeInsets.only(
                    left: _indentPerLevel * row.depth,
                    right: 6,
                  ),
                  child: lessonBuilder(context, row.lesson!),
                ),
              );
        return KeyedSubtree(key: ValueKey(row.key), child: child);
      },
    );
  }

  List<_HierarchyNode> _buildTree() {
    final roots = <_HierarchyNode>[];
    final foldersByPath = <String, _HierarchyNode>{};
    for (var lessonIndex = 0; lessonIndex < lessons.length; lessonIndex++) {
      final lesson = lessons[lessonIndex];
      final folders = lesson.folderPath;
      var siblings = roots;
      final parentPath = <String>[];
      for (final folder in folders) {
        parentPath.add(folder);
        final folderKey = hierarchyFolderKey(parentPath);
        var node = foldersByPath[folderKey];
        if (node == null) {
          node = _HierarchyNode.folder(
            key: folderKey,
            path: List.unmodifiable(parentPath),
            originOrder: lessonIndex,
          );
          foldersByPath[folderKey] = node;
          siblings.add(node);
        } else if (lessonIndex < node.originOrder) {
          node.originOrder = lessonIndex;
        }
        siblings = node.children;
      }
      siblings.add(
        _HierarchyNode.lesson(
          key: 'lesson:${lesson.id}',
          lesson: lesson,
          originOrder: lessonIndex,
        ),
      );
    }

    void sortNodes(List<_HierarchyNode> nodes) {
      nodes.sort((first, second) {
        final lastSavedRank = order.values.fold<int>(
          -1,
          (maximum, rank) => rank > maximum ? rank : maximum,
        );
        final firstRank =
            order[first.key] ?? lastSavedRank + first.originOrder + 1;
        final secondRank =
            order[second.key] ?? lastSavedRank + second.originOrder + 1;
        return firstRank.compareTo(secondRank);
      });
      for (final node in nodes) {
        sortNodes(node.children);
      }
    }

    sortNodes(roots);
    return roots;
  }

  void _appendVisibleRows(
    List<_HierarchyNode> nodes,
    List<LessonHierarchyRow> rows,
    String parentKey,
    int depth,
  ) {
    for (final node in nodes) {
      if (node.isFolder) {
        final count = _lessonCount(node);
        rows.add(
          LessonHierarchyRow._(
            key: node.key,
            parentKey: parentKey,
            depth: depth,
            folderPath: node.path,
            lessonCount: count,
          ),
        );
        if (folderExpansion[node.key] ?? true) {
          _appendVisibleRows(node.children, rows, node.key, depth + 1);
        }
      } else {
        rows.add(
          LessonHierarchyRow._(
            key: node.key,
            parentKey: parentKey,
            depth: depth,
            lesson: node.lesson,
          ),
        );
      }
    }
  }

  int _lessonCount(_HierarchyNode node) => node.isFolder
      ? node.children.fold(0, (count, child) => count + _lessonCount(child))
      : 1;

  Widget _folderRow(BuildContext context, LessonHierarchyRow row, int index) {
    final theme = Theme.of(context);
    final expanded = folderExpansion[row.key] ?? true;
    return Card(
      margin: EdgeInsets.fromLTRB(4 + _indentPerLevel * row.depth, 12, 4, 2),
      child: ReorderableDelayedDragStartListener(
        index: index,
        child: ListTile(
          dense: true,
          leading: Icon(Icons.drag_handle, color: theme.colorScheme.outline),
          title: Text(
            row.folderPath!.last,
            style: theme.textTheme.titleMedium?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
          subtitle: Text(
            '${row.lessonCount} ${row.lessonCount == 1 ? 'lesson' : 'lessons'}',
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip:
                    'Delete ${formatHierarchyPath(row.folderPath!)} and its lessons',
                icon: Icon(
                  Icons.delete_outline,
                  color: theme.colorScheme.error,
                ),
                onPressed: () =>
                    onDeleteFolder(row.folderPath!, row.lessonCount),
              ),
              PopupMenuButton<String>(
                tooltip: 'Manage ${formatHierarchyPath(row.folderPath!)}',
                onSelected: (action) {
                  if (action == 'move') onMoveFolder(row.folderPath!);
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(value: 'move', child: Text('Move folder...')),
                ],
              ),
              Icon(expanded ? Icons.expand_less : Icons.expand_more),
            ],
          ),
          onTap: () => onFolderExpansionChanged(row.key, !expanded),
        ),
      ),
    );
  }
}

class _HierarchyNode {
  final String key;
  final List<String>? path;
  final Lesson? lesson;
  final List<_HierarchyNode> children = [];
  int originOrder;

  _HierarchyNode._({
    required this.key,
    required this.originOrder,
    this.path,
    this.lesson,
  });

  factory _HierarchyNode.folder({
    required String key,
    required List<String> path,
    required int originOrder,
  }) => _HierarchyNode._(key: key, path: path, originOrder: originOrder);

  factory _HierarchyNode.lesson({
    required String key,
    required Lesson lesson,
    required int originOrder,
  }) => _HierarchyNode._(key: key, lesson: lesson, originOrder: originOrder);

  bool get isFolder => path != null;
}
