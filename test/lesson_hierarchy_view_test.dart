import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/lesson.dart';
import 'package:lingua_srs/widgets/lesson_hierarchy_view.dart';

void main() {
  testWidgets('folders are expanded by default and can be collapsed', (
    tester,
  ) async {
    final lessons = [
      Lesson(id: 'lesson-a', title: 'Lesson A', unitTitle: 'Unit 2/Grammar'),
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
                lessonBuilder: (context, lesson) =>
                    ListTile(title: Text(lesson.displayTitle)),
                onOrderChanged: (_) async {},
                onFolderExpansionChanged: (key, expanded) async {
                  expansionChanges.add((key, expanded));
                  setState(() => expansion[key] = expanded);
                },
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
    expect(expansionChanges.last, ('folder:unit 2/grammar', false));
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
              lessonBuilder: (context, lesson) =>
                  ListTile(title: Text(lesson.displayTitle)),
              onOrderChanged: (keys) async {
                reorderedKeys = keys;
              },
              onFolderExpansionChanged: (_, _) async {},
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
              lessonBuilder: (context, lesson) =>
                  ListTile(title: Text(lesson.displayTitle)),
              onOrderChanged: (keys) async {
                reorderedKeys = keys;
              },
              onFolderExpansionChanged: (_, _) async {},
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
}
