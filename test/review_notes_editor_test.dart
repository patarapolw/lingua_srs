import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/srs_card.dart';
import 'package:lingua_srs/widgets/review_notes_editor.dart';

Future<void> pumpEditor(
  WidgetTester tester,
  SrsCard card,
  ValueChanged<String> onSave,
) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: StatefulBuilder(
            builder: (context, setState) => ReviewNotesEditor(
              card: card,
              onSave: (text) {
                card.backNotes = text;
                onSave(text);
                setState(() {});
              },
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('ReviewNotesEditor', () {
    testWidgets('an empty note only offers a small add button', (tester) async {
      final card = SrsCard(direction: CardDirection.targetToNative);
      await pumpEditor(tester, card, (_) {});

      expect(find.text('Add review note'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(find.textContaining('Review notes'), findsNothing);
    });

    testWidgets('adds a note for this card only, with Markdown', (tester) async {
      final card = SrsCard(direction: CardDirection.nativeToTarget);
      final other = SrsCard(direction: CardDirection.targetToNative);
      String? saved;
      await pumpEditor(tester, card, (text) => saved = text);

      await tester.tap(find.text('Add review note'));
      await tester.pumpAndSettle();
      expect(find.text('Review notes · EN ➔ KO'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '  Use **polite** form  ');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(saved, 'Use **polite** form');
      expect(card.backNotes, 'Use **polite** form');
      expect(other.backNotes, isEmpty);
      expect(find.byTooltip('Edit review note'), findsOneWidget);
      expect(find.text('Review notes · EN ➔ KO'), findsOneWidget);
    });

    testWidgets('preview toggle renders without changing the note', (
      tester,
    ) async {
      final card = SrsCard(direction: CardDirection.targetToNative)
        ..backNotes = 'old';
      await pumpEditor(tester, card, (_) {});

      await tester.tap(find.byTooltip('Edit review note'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'old');

      await tester.tap(find.text('Preview'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      expect(find.text('Edit'), findsOneWidget);

      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      expect(card.backNotes, 'old');
    });

    testWidgets('cancel keeps the existing note', (tester) async {
      final card = SrsCard(direction: CardDirection.targetToNative)
        ..backNotes = 'keep me';
      var saves = 0;
      await pumpEditor(tester, card, (_) => saves++);

      await tester.tap(find.byTooltip('Edit review note'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'changed');
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(card.backNotes, 'keep me');
      expect(saves, 0);
    });

    testWidgets('clearing the text removes the note', (tester) async {
      final card = SrsCard(direction: CardDirection.targetToNative)
        ..backNotes = 'remove me';
      await pumpEditor(tester, card, (_) {});

      await tester.tap(find.byTooltip('Edit review note'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '   ');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(card.backNotes, isEmpty);
      expect(find.text('Add review note'), findsOneWidget);
    });

    testWidgets('typing in the note blocks study shortcuts', (tester) async {
      final card = SrsCard(direction: CardDirection.targetToNative);
      await pumpEditor(tester, card, (_) {});
      expect(isEditingText(), isFalse);

      await tester.tap(find.text('Add review note'));
      await tester.pumpAndSettle();
      expect(isEditingText(), isTrue);

      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(isEditingText(), isFalse);
    });
  });
}
