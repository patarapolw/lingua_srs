import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/sentence.dart';
import 'package:lingua_srs/widgets/emphasis_field.dart';
import 'package:material_ui/material_ui.dart';

/// [marked] after toggling the emphasis of [start]–[end], with the new
/// selection written as `[…]` around what it covers.
String _toggle(String marked, int start, int end) {
  final result = Sentence.toggleEmphasis(marked, start, end);
  return '${result.text.substring(0, result.start)}['
      '${result.text.substring(result.start, result.end)}]'
      '${result.text.substring(result.end)}';
}

void main() {
  group('Sentence.toggleEmphasis', () {
    test('emphasizes a selection without changing the text', () {
      expect(_toggle('저는 배를 먹어요', 3, 4), '저는 **[배]**를 먹어요');
    });

    test('takes emphasis away from a selection inside it', () {
      expect(_toggle('저는 **배**를 먹어요', 5, 6), '저는 [배]를 먹어요');
    });

    test('a selection that includes the markers takes them away', () {
      expect(_toggle('저는 **배**를 먹어요', 3, 8), '저는 [배]를 먹어요');
    });

    test('takes part of a segment out of it, keeping the rest', () {
      expect(_toggle('저는 **배를** 먹어요', 5, 6), '저는 [배]**를** 먹어요');
    });

    test('joins a segment the selection touches', () {
      expect(_toggle('저는 **배**를 먹어요', 8, 9), '저는 **배[를]** 먹어요');
    });

    test('joins every segment the selection overlaps', () {
      expect(_toggle('a **b** c **d** e', 0, 17), '**[a b c d e]**');
    });

    test('leaves spaces at the ends of a selection outside it', () {
      expect(_toggle('I eat a pear today', 7, 13), 'I eat a **[pear]** today');
    });

    test('with nothing selected, takes away the segment at the cursor', () {
      expect(_toggle('저는 **배**를 먹어요', 5, 5), '저는 []배를 먹어요');
    });

    test('with nothing selected, emphasizes the word at the cursor', () {
      expect(_toggle('I eat a pear', 10, 10), 'I eat a **[pear]**');
    });

    test('leaves only spaces, or a stray *, unchanged', () {
      expect(_toggle('a   b', 1, 4), 'a[   ]b');
      expect(_toggle('a *b c', 0, 6), '[a *b c]');
    });

    test('accepts a selection made backwards', () {
      expect(_toggle('저는 배를 먹어요', 4, 3), '저는 **[배]**를 먹어요');
    });

    test('isEmphasized tells which label the button shows', () {
      expect(Sentence.isEmphasized('저는 **배**를 먹어요', 5, 6), isTrue);
      expect(Sentence.isEmphasized('저는 **배**를 먹어요', 3, 8), isTrue);
      expect(Sentence.isEmphasized('저는 **배**를 먹어요', 5, 9), isFalse);
      expect(Sentence.isEmphasized('저는 **배**를 먹어요', 5, 5), isFalse);
    });

    test('toggling twice gives the sentence back', () {
      const plain = 'I eat a pear and an apple';
      final once = Sentence.toggleEmphasis(plain, 8, 12);
      final twice = Sentence.toggleEmphasis(once.text, once.start, once.end);
      expect(twice.text, plain);
    });
  });

  group('EmphasisField', () {
    Future<TextEditingController> pump(
      WidgetTester tester, {
      required String text,
      bool textEditable = true,
    }) async {
      final controller = TextEditingController(text: text);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EmphasisField(
              controller: controller,
              textEditable: textEditable,
            ),
          ),
        ),
      );
      return controller;
    }

    /// Focuses the field and selects [start]–[end] of it.
    Future<void> select(
      WidgetTester tester,
      TextEditingController controller,
      int start,
      int end,
    ) async {
      await tester.tap(find.byType(TextField));
      await tester.pump();
      controller.selection = TextSelection(
        baseOffset: start,
        extentOffset: end,
      );
      await tester.pump();
    }

    testWidgets('Emphasize shows only while text is selected', (tester) async {
      final controller = await pump(tester, text: '저는 배를 먹어요');
      expect(find.text('Emphasize'), findsNothing);

      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(find.text('Emphasize'), findsNothing, reason: 'only a cursor');

      controller.selection = const TextSelection(
        baseOffset: 3,
        extentOffset: 4,
      );
      await tester.pump();
      expect(find.text('Emphasize'), findsOneWidget);
    });

    testWidgets('Emphasize, then Remove emphasis, on the same selection', (
      tester,
    ) async {
      final controller = await pump(tester, text: '저는 배를 먹어요');
      await select(tester, controller, 3, 4);
      await tester.tap(find.text('Emphasize'));
      await tester.pump();
      expect(controller.text, '저는 **배**를 먹어요');

      // The selection stays on 배, now inside the markers.
      await tester.tap(find.text('Remove emphasis'));
      await tester.pump();
      expect(controller.text, '저는 배를 먹어요');
    });

    testWidgets('a mouse click on Emphasize keeps the selection it acts on', (
      tester,
    ) async {
      final controller = await pump(tester, text: 'I eat a pear');
      await select(tester, controller, 8, 12);
      await tester.tap(find.text('Emphasize'), kind: PointerDeviceKind.mouse);
      await tester.pump();
      expect(controller.text, 'I eat a **pear**');
    });

    testWidgets('Ctrl+B toggles emphasis', (tester) async {
      final controller = await pump(tester, text: 'I eat a pear');
      await select(tester, controller, 8, 12);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(controller.text, 'I eat a **pear**');
    });

    testWidgets('a locked field takes emphasis but not typing', (tester) async {
      final controller = await pump(
        tester,
        text: 'I eat a pear',
        textEditable: false,
      );
      expect(
        tester.widget<EditableText>(find.byType(EditableText)).readOnly,
        isTrue,
      );

      await select(tester, controller, 8, 12);
      await tester.tap(find.text('Emphasize'));
      await tester.pump();
      expect(controller.text, 'I eat a **pear**');
    });

    test('mentions the shortcut on a computer only', () {
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(
        EmphasisField.howTo('a part'),
        'Select a part and choose Emphasize',
      );
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      expect(
        EmphasisField.howTo('a part'),
        'Select a part and choose Emphasize (or press ⌘B)',
      );
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      expect(EmphasisField.howTo('a part'), endsWith('(or press Ctrl+B)'));
    });
  });
}
