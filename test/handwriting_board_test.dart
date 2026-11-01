import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/widgets/answer_workspace.dart';

void main() {
  group('AnswerWorkspace', () {
    testWidgets('supports typed answers and Ctrl+Enter submission', (
      tester,
    ) async {
      var submits = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AnswerWorkspace(onSubmit: () => submits++)),
        ),
      );
      await tester.tap(find.text('Type'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '안녕하세요');
      expect(find.text('안녕하세요'), findsOneWidget);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(submits, 1);
    });

    testWidgets('draws with pointer input and clears the drawing', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AnswerWorkspace(onSubmit: _noop)),
        ),
      );
      await tester.tap(find.text('Draw'));
      await tester.pumpAndSettle();
      final canvas = find.byKey(const ValueKey('answer-drawing-canvas'));
      await tester.dragFrom(
        tester.getTopLeft(canvas) + const Offset(30, 30),
        const Offset(60, 25),
      );
      await tester.pump();
      expect(find.text('Write with your finger or pen'), findsNothing);
      expect(find.byTooltip('Eraser'), findsOneWidget);
      await tester.tap(find.byTooltip('Blue pen'));
      await tester.pump();
      await tester.tap(find.byTooltip('Eraser'));
      await tester.pump();
      expect(find.byTooltip('Pen'), findsOneWidget);
      await tester.tap(find.byTooltip('Clear drawing'));
      await tester.pump();
      expect(find.text('Write with your finger or pen'), findsOneWidget);
    });

    testWidgets('clears answer state when the card key changes', (
      tester,
    ) async {
      var card = 'first';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => Column(
                children: [
                  TextButton(
                    onPressed: () => setState(() => card = 'next'),
                    child: const Text('Next card'),
                  ),
                  AnswerWorkspace(key: ValueKey(card), onSubmit: _noop),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Type'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'answer');
      await tester.tap(find.text('Next card'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Type'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
    });
  });
}

void _noop() {}
