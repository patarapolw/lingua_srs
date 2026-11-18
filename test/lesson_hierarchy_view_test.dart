import 'dart:collection';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/lesson.dart';
import 'package:lingua_srs/widgets/lesson_hierarchy_view.dart';

/// Counts how often a saved rank is read.
class _CountingOrder extends MapBase<String, int> {
  _CountingOrder(this._ranks);

  final Map<String, int> _ranks;
  int reads = 0;

  @override
  int? operator [](Object? key) {
    reads++;
    return _ranks[key];
  }

  @override
  Iterable<int> get values {
    reads += _ranks.length;
    return _ranks.values;
  }

  @override
  void operator []=(String key, int value) => _ranks[key] = value;
  @override
  void clear() => _ranks.clear();
  @override
  Iterable<String> get keys => _ranks.keys;
  @override
  int? remove(Object? key) => _ranks.remove(key);
}

void main() {
  group('buildLessonHierarchyRows', () {
    final lessons = [
      Lesson(id: 'a', title: 'A', unitTitle: 'Unit 1'),
      Lesson(id: 'b', title: 'B', unitTitle: 'Unit 1'),
      Lesson(id: 'c', title: 'C', unitTitle: 'Unit 2'),
      Lesson(id: 'd', title: 'D'),
      Lesson(id: 'e', title: 'E', unitTitle: 'Unit 1'),
    ];

    test('puts saved ranks first, then the rest in lesson order', () {
      final rows = buildLessonHierarchyRows(
        lessons: lessons,
        order: const {'lesson:d': 0, 'folder:unit 2': 1, 'lesson:e': 0},
        folderExpansion: const {},
      );

      expect(rows.map((row) => row.key), [
        'lesson:d',
        'folder:unit 2',
        'lesson:c',
        'folder:unit 1',
        'lesson:e',
        'lesson:a',
        'lesson:b',
      ]);
      expect(rows.map((row) => row.depth), [0, 0, 1, 0, 1, 1, 1]);
      expect(rows[3].lessonCount, 3);
    });

    test('gives each row its siblings and its place among them', () {
      final rows = buildLessonHierarchyRows(
        lessons: lessons,
        order: const {},
        folderExpansion: const {},
      );
      final byKey = {for (final row in rows) row.key: row};

      final roots = ['folder:unit 1', 'folder:unit 2', 'lesson:d'];
      expect(byKey['folder:unit 1']!.siblingKeys, roots);
      expect(byKey['lesson:d']!.siblingIndex, 2);
      expect(byKey['lesson:b']!.siblingKeys, [
        'lesson:a',
        'lesson:b',
        'lesson:e',
      ]);
      expect(byKey['lesson:b']!.siblingIndex, 1);
      expect(byKey['lesson:c']!.siblingKeys, ['lesson:c']);
      expect(byKey['lesson:c']!.siblingIndex, 0);
    });

    test('leaves out the contents of a collapsed folder', () {
      final rows = buildLessonHierarchyRows(
        lessons: lessons,
        order: const {},
        folderExpansion: const {'folder:unit 1': false},
      );

      expect(rows.map((row) => row.key), [
        'folder:unit 1',
        'folder:unit 2',
        'lesson:c',
        'lesson:d',
      ]);
      expect(rows.first.lessonCount, 3);
    });

    test('reads each saved rank once, not once per comparison', () {
      final many = [
        for (var i = 0; i < 200; i++)
          Lesson(id: 'l$i', title: 'L$i', unitTitle: 'Unit ${i % 4}'),
      ];
      final order = _CountingOrder({
        for (var i = 0; i < 200; i += 2) 'lesson:l$i': 200 - i,
      });

      final rows = buildLessonHierarchyRows(
        lessons: many,
        order: order,
        folderExpansion: const {},
      );

      expect(rows, hasLength(204));
      // One lookup per lesson and folder, plus one pass over the ranks.
      expect(order.reads, 204 + 100);
    });
  });

  testWidgets('folders are expanded by default and can be collapsed', (
    tester,
  ) async {
    final lessons = [
      Lesson(id: 'lesson-a', title: 'Lesson A', unitTitle: 'Unit 2::Grammar'),
    ];
    final expansionChanges = <(String, bool)>[];
    final expansion = <String, bool>{};

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) => Scaffold(
            body: SizedBox(
              height: 700,
              child: LessonHierarchyView(
                lessons: lessons,
                order: const {},
                folderExpansion: expansion,
                lessonBuilder: (context, lesson, _) =>
                    ListTile(title: Text(lesson.displayTitle)),
                onOrderChanged: (_) async {},
                onFolderExpansionChanged: (key, expanded) async {
                  expansionChanges.add((key, expanded));
                  setState(() => expansion[key] = expanded);
                },
                onMoveFolder: (_) {},
                onResetFolder: (_, _) {},
                onDeleteFolder: (_, _) {},
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text('Unit 2'), findsOneWidget);
    expect(find.text('Grammar'), findsOneWidget);
    expect(find.text('Lesson A'), findsOneWidget);

    await tester.tap(find.text('Unit 2'));
    await tester.pumpAndSettle();
    expect(expansionChanges, [('folder:unit 2', false)]);
    expect(find.text('Grammar'), findsNothing);
    expect(find.text('Lesson A'), findsNothing);

    await tester.tap(find.text('Unit 2'));
    await tester.pumpAndSettle();
    expect(find.text('Grammar'), findsOneWidget);
    expect(find.text('Lesson A'), findsOneWidget);

    await tester.tap(find.text('Grammar'));
    await tester.pumpAndSettle();
    expect(expansionChanges.last, ('folder:unit 2::grammar', false));
    expect(find.text('Lesson A'), findsNothing);
  });

  testWidgets('dragging a folder reports its saved sibling order', (
    tester,
  ) async {
    final lessons = [
      Lesson(id: 'lesson-1', title: 'Lesson 1', unitTitle: 'Unit 1'),
      Lesson(id: 'lesson-2', title: 'Lesson 2', unitTitle: 'Unit 2'),
      Lesson(id: 'lesson-3', title: 'Lesson 3', unitTitle: 'Unit 3'),
    ];
    List<String>? reorderedKeys;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 700,
            child: LessonHierarchyView(
              lessons: lessons,
              order: const {},
              folderExpansion: const {},
              lessonBuilder: (context, lesson, _) =>
                  ListTile(title: Text(lesson.displayTitle)),
              onOrderChanged: (keys) async {
                reorderedKeys = keys;
              },
              onFolderExpansionChanged: (_, _) async {},
              onMoveFolder: (_) {},
              onResetFolder: (_, _) {},
              onDeleteFolder: (_, _) {},
            ),
          ),
        ),
      ),
    );

    final folderDragHandle = find
        .byType(ReorderableDelayedDragStartListener)
        .first;
    final gesture = await tester.startGesture(
      tester.getCenter(folderDragHandle),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveBy(const Offset(0, 220));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(reorderedKeys, isNotNull);
    expect(reorderedKeys, hasLength(3));
    expect(reorderedKeys!.first, isNot('folder:unit 1'));
  });

  testWidgets('dragging a nested folder reorders siblings in its parent', (
    tester,
  ) async {
    final lessons = [
      Lesson(id: 'lesson-1', title: 'Lesson 1', unitTitle: 'Unit 1::Group A'),
      Lesson(id: 'lesson-2', title: 'Lesson 2', unitTitle: 'Unit 1::Group B'),
      Lesson(id: 'lesson-3', title: 'Lesson 3', unitTitle: 'Unit 1::Group C'),
    ];
    List<String>? reorderedKeys;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 700,
            child: LessonHierarchyView(
              lessons: lessons,
              order: const {},
              folderExpansion: const {},
              lessonBuilder: (context, lesson, _) =>
                  ListTile(title: Text(lesson.displayTitle)),
              onOrderChanged: (keys) async {
                reorderedKeys = keys;
              },
              onFolderExpansionChanged: (_, _) async {},
              onMoveFolder: (_) {},
              onResetFolder: (_, _) {},
              onDeleteFolder: (_, _) {},
            ),
          ),
        ),
      ),
    );

    final folderDragHandle = find.ancestor(
      of: find.byTooltip('Manage Unit 1 › Group A'),
      matching: find.byType(ReorderableDelayedDragStartListener),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(folderDragHandle),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveBy(const Offset(0, 300));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(reorderedKeys, isNotNull);
    expect(reorderedKeys, hasLength(3));
    expect(reorderedKeys!.first, isNot('folder:unit 1::group a'));
  });

  testWidgets('dragging a lesson reports its saved sibling order', (
    tester,
  ) async {
    final lessons = [
      Lesson(id: 'lesson-1', title: 'Lesson 1'),
      Lesson(id: 'lesson-2', title: 'Lesson 2'),
    ];
    List<String>? reorderedKeys;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 700,
            child: LessonHierarchyView(
              lessons: lessons,
              order: const {},
              folderExpansion: const {},
              lessonBuilder: (context, lesson, _) =>
                  ListTile(title: Text(lesson.displayTitle)),
              onOrderChanged: (keys) async {
                reorderedKeys = keys;
              },
              onFolderExpansionChanged: (_, _) async {},
              onMoveFolder: (_) {},
              onResetFolder: (_, _) {},
              onDeleteFolder: (_, _) {},
            ),
          ),
        ),
      ),
    );

    final lessonDragHandle = find
        .byType(ReorderableDelayedDragStartListener)
        .first;
    final gesture = await tester.startGesture(
      tester.getCenter(lessonDragHandle),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveBy(const Offset(0, 120));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(reorderedKeys, hasLength(2));
    expect(reorderedKeys!.first, 'lesson:lesson-2');
  });

  testWidgets('dropdown actions reorder lessons and folders', (tester) async {
    final lessons = [
      Lesson(id: 'lesson-a', title: 'Lesson A', unitTitle: 'Unit 1'),
      Lesson(id: 'lesson-b', title: 'Lesson B', unitTitle: 'Unit 1'),
      Lesson(id: 'lesson-c', title: 'Lesson C', unitTitle: 'Unit 2'),
    ];
    List<String>? reorderedKeys;
    (List<String>, int)? resetFolder;
    (List<String>, int)? deletedFolder;
    List<String>? exportedFolder;
    List<String>? renamedFolder;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 700,
            child: LessonHierarchyView(
              lessons: lessons,
              order: const {},
              folderExpansion: const {},
              lessonBuilder: (context, lesson, orderActions) =>
                  PopupMenuButton<String>(
                    key: ValueKey('lesson-menu-${lesson.id}'),
                    onSelected: (action) {
                      if (action == 'up') orderActions.moveUp();
                      if (action == 'down') orderActions.moveDown();
                    },
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        value: 'up',
                        enabled: orderActions.canMoveUp,
                        child: const Text('Move up'),
                      ),
                      PopupMenuItem(
                        value: 'down',
                        enabled: orderActions.canMoveDown,
                        child: const Text('Move down'),
                      ),
                    ],
                  ),
              onOrderChanged: (keys) async {
                reorderedKeys = keys;
              },
              onFolderExpansionChanged: (_, _) async {},
              onMoveFolder: (_) {},
              onRenameFolder: (path) {
                renamedFolder = path;
              },
              onResetFolder: (path, count) {
                resetFolder = (path, count);
              },
              onDeleteFolder: (path, count) {
                deletedFolder = (path, count);
              },
              onExportFolder: (path) {
                exportedFolder = path;
              },
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('lesson-menu-lesson-b')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move up'));
    await tester.pumpAndSettle();
    expect(reorderedKeys, ['lesson:lesson-b', 'lesson:lesson-a']);

    await tester.tap(find.byTooltip('Manage Unit 2'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move up'));
    await tester.pumpAndSettle();
    expect(reorderedKeys, ['folder:unit 2', 'folder:unit 1']);

    await tester.tap(find.byTooltip('Manage Unit 2'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reset SRS Progress'));
    await tester.pumpAndSettle();
    expect(resetFolder?.$1, ['Unit 2']);
    expect(resetFolder?.$2, 1);

    await tester.tap(find.byTooltip('Manage Unit 2'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete folder'));
    await tester.pumpAndSettle();
    expect(deletedFolder?.$1, ['Unit 2']);
    expect(deletedFolder?.$2, 1);

    await tester.tap(find.byTooltip('Manage Unit 2'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export as ZIP'));
    await tester.pumpAndSettle();
    expect(exportedFolder, ['Unit 2']);

    await tester.tap(find.byTooltip('Manage Unit 2'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename folder'));
    await tester.pumpAndSettle();
    expect(renamedFolder, ['Unit 2']);
  });

  testWidgets('slash-separated lesson titles create nested folders', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 700,
            child: LessonHierarchyView(
              lessons: [
                Lesson(id: 'nested-lesson', title: 'Topic::Subtopic::Lesson A'),
              ],
              order: const {},
              folderExpansion: const {},
              lessonBuilder: (context, lesson, _) =>
                  ListTile(title: Text(lesson.displayTitle)),
              onOrderChanged: (_) async {},
              onFolderExpansionChanged: (_, _) async {},
              onMoveFolder: (_) {},
              onResetFolder: (_, _) {},
              onDeleteFolder: (_, _) {},
            ),
          ),
        ),
      ),
    );

    expect(find.text('Topic'), findsOneWidget);
    expect(find.text('Subtopic'), findsOneWidget);
    expect(find.text('Lesson A'), findsOneWidget);
  });
}
