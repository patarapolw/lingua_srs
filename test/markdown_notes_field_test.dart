import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/widgets/markdown_notes_field.dart';

Future<void> _pump(
  WidgetTester tester,
  String notes, {
  bool previewWhenFilled = false,
}) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: MarkdownNotesField(
          label: 'Notes',
          controller: TextEditingController(text: notes),
          previewWhenFilled: previewWhenFilled,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('starts in Edit and toggles to Preview', (tester) async {
    await _pump(tester, 'some **notes**');
    expect(find.byType(TextField), findsOneWidget);

    await tester.tap(find.text('Preview'));
    await tester.pump();
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Edit'), findsOneWidget);
  });

  testWidgets('previewWhenFilled opens filled notes in Preview', (
    tester,
  ) async {
    await _pump(tester, 'some **notes**', previewWhenFilled: true);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Edit'), findsOneWidget);
  });

  testWidgets('previewWhenFilled stays in Edit for empty notes', (
    tester,
  ) async {
    await _pump(tester, '  ', previewWhenFilled: true);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('Preview'), findsOneWidget);
  });
}
