import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/widgets/markdown_content.dart';
import 'package:lingua_srs/widgets/markdown_notes_field.dart';

Future<TextEditingController> _pump(WidgetTester tester, String notes) async {
  final controller = TextEditingController(text: notes);
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: MarkdownNotesField(
          label: 'Notes',
          addLabel: 'Add a note',
          controller: controller,
        ),
      ),
    ),
  );
  return controller;
}

void main() {
  testWidgets('empty notes are only an Add button', (tester) async {
    await _pump(tester, '');
    expect(find.text('Add a note'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Notes'), findsNothing);
    expect(find.text('Preview'), findsNothing);
  });

  testWidgets('blank notes count as empty', (tester) async {
    await _pump(tester, '  \n ');
    expect(find.text('Add a note'), findsOneWidget);
  });

  testWidgets('Add starts editing, Preview shows the notes rendered', (
    tester,
  ) async {
    final controller = await _pump(tester, '');

    await tester.tap(find.text('Add a note'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('Notes'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'some **notes**');
    expect(controller.text, 'some **notes**');
    await tester.tap(find.text('Preview'));
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsNothing);
    expect(find.byType(MarkdownContent), findsOneWidget);
    expect(find.text('Edit'), findsOneWidget);
  });

  testWidgets('filled notes open rendered, and Edit brings the text back', (
    tester,
  ) async {
    final controller = await _pump(tester, 'some **notes**');
    expect(find.byType(TextField), findsNothing);
    expect(find.byType(MarkdownContent), findsOneWidget);
    expect(find.text('Add a note'), findsNothing);

    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller,
      same(controller),
    );
    expect(find.text('Preview'), findsOneWidget);
  });

  testWidgets('clearing the notes and previewing goes back to the button', (
    tester,
  ) async {
    await _pump(tester, 'some notes');
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '');
    await tester.tap(find.text('Preview'));
    await tester.pumpAndSettle();

    expect(find.text('Add a note'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });
}
