import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/widgets/ai_question_chip.dart';

const _short = 'Quiz me?';
const _long =
    'How is "사과" used in everyday speech? '
    'What formality and politeness (speech levels) does it suit?';

/// Chips in a Wrap of [width], as the suggested questions are shown.
Widget _host(List<Widget> chips, {double width = 220}) => MaterialApp(
  home: Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: width,
        child: Wrap(spacing: 6, runSpacing: 6, children: chips),
      ),
    ),
  ),
);

void main() {
  group('AiQuestionChip', () {
    testWidgets('breaks a long question onto more lines inside the width', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host([
          AiQuestionChip(label: _short, onPressed: () {}),
          AiQuestionChip(label: _long, onPressed: () {}),
        ]),
      );

      // A label that was cut off at the edge shows up as a layout error.
      expect(tester.takeException(), isNull);
      final shortSize = tester.getSize(
        find.widgetWithText(AiQuestionChip, _short),
      );
      final longSize = tester.getSize(
        find.widgetWithText(AiQuestionChip, _long),
      );
      expect(longSize.width, lessThanOrEqualTo(220));
      expect(longSize.height, greaterThan(shortSize.height * 2));
    });

    testWidgets('shows the whole question', (tester) async {
      await tester.pumpWidget(
        _host([AiQuestionChip(label: _long, onPressed: () {})]),
      );

      final text = tester.widget<Text>(find.text(_long));
      expect(text.maxLines, isNull);
      expect(text.softWrap, isNull);
      expect(text.overflow, isNull);
    });

    testWidgets('keeps a short question on one line at its own width', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host([AiQuestionChip(label: _short, onPressed: () {})], width: 400),
      );

      final size = tester.getSize(find.byType(AiQuestionChip));
      expect(size.width, lessThan(400));
    });

    testWidgets('asks the question when tapped', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        _host([AiQuestionChip(label: _short, onPressed: () => taps++)]),
      );

      await tester.tap(find.byType(AiQuestionChip));
      await tester.pump();

      expect(taps, 1);
    });

    testWidgets('does nothing when disabled', (tester) async {
      await tester.pumpWidget(_host([const AiQuestionChip(label: _short)]));

      await tester.tap(find.byType(AiQuestionChip));
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(tester.widget<InkWell>(find.byType(InkWell)).onTap, isNull);
    });
  });
}
