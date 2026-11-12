import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/widgets/answer_workspace.dart';

void main() {
  group('AnswerWorkspace', () {
    testWidgets('keeps the collapsed scratchpad control compact', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AnswerWorkspace(onSubmit: _noop)),
        ),
      );

      final button = tester.widget<TextButton>(find.byType(TextButton));
      expect(button.style!.visualDensity, VisualDensity.compact);
      expect(button.style!.padding!.resolve({}), EdgeInsets.zero);
    });

    testWidgets('supports typed answers and Ctrl+Enter submission', (
      tester,
    ) async {
      var submits = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AnswerWorkspace(onSubmit: () => submits++)),
        ),
      );
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.text('Your answer'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Type'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
      expect(find.byType(TextField), findsOneWidget);
      await tester.enterText(find.byType(TextField), '안녕하세요');
      expect(find.text('안녕하세요'), findsOneWidget);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(submits, 1);
      await tester.tap(find.byTooltip('Hide scratchpad'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.text('Your answer'));
      await tester.pumpAndSettle();
      expect(find.text('안녕하세요'), findsOneWidget);
    });

    testWidgets('draws with pointer input and clears the drawing', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AnswerWorkspace(onSubmit: _noop)),
        ),
      );
      expect(find.byKey(const ValueKey('answer-drawing-canvas')), findsNothing);
      await tester.tap(find.text('Your answer'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Draw'));
      await tester.pumpAndSettle();
      final scrim = tester
          .widget<Scaffold>(
            find.ancestor(
              of: find.byKey(const ValueKey('answer-drawing-canvas')),
              matching: find.byType(Scaffold),
            ),
          )
          .backgroundColor!;
      expect(scrim.a, greaterThan(0));
      expect(scrim.a, lessThan(1));
      final canvas = find.byKey(const ValueKey('answer-drawing-canvas'));
      expect(tester.getSize(canvas).height, greaterThan(300));
      await tester.dragFrom(tester.getCenter(canvas), const Offset(60, 25));
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
      await tester.tap(find.byTooltip('Close scratchpad'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('answer-drawing-canvas')), findsNothing);
      await tester.tap(find.text('Open drawing pad'));
      await tester.pumpAndSettle();
      expect(find.text('Write with your finger or pen'), findsOneWidget);
      await tester.tap(find.byTooltip('Close scratchpad'));
      await tester.pumpAndSettle();
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
      await tester.tap(find.text('Your answer'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Type'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'answer');
      await tester.tap(find.text('Next card'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Your answer'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Type'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
    });
  });
}

void _noop() {}
