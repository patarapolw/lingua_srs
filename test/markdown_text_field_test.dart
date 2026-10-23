import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/services/clipboard_markdown.dart';
import 'package:lingua_srs/widgets/markdown_text_field.dart';

void main() {
  final originalReader = clipboardHtmlReader;

  tearDown(() => clipboardHtmlReader = originalReader);

  void mockClipboard(WidgetTester tester, {String? plain, String? html}) {
    clipboardHtmlReader = () async => html;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.getData') {
          return plain == null ? null : <String, dynamic>{'text': plain};
        }
        if (call.method == 'Clipboard.hasStrings') {
          return <String, dynamic>{'value': plain != null};
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
  }

  Future<void> pumpField(
    WidgetTester tester,
    TextEditingController controller, {
    ValueChanged<String>? onChanged,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MarkdownTextField(
            controller: controller,
            maxLines: 5,
            onChanged: onChanged,
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pump();
  }

  Future<void> pressPaste(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
  }

  group('MarkdownTextField paste', () {
    testWidgets('converts copied HTML and replaces the selection', (
      tester,
    ) async {
      mockClipboard(
        tester,
        plain: 'bold',
        html: '<p>some <b>bold</b> text</p>',
      );
      final controller = TextEditingController(text: 'Hello XXX world');
      addTearDown(controller.dispose);
      String? changed;
      await pumpField(tester, controller, onChanged: (text) => changed = text);

      controller.selection = const TextSelection(
        baseOffset: 6,
        extentOffset: 9,
      );
      await pressPaste(tester);

      expect(controller.text, 'Hello some **bold** text world');
      expect(controller.selection, const TextSelection.collapsed(offset: 24));
      expect(changed, controller.text);
    });

    testWidgets('pastes plain text when the HTML has no formatting', (
      tester,
    ) async {
      mockClipboard(
        tester,
        plain: 'just text',
        html: '<div style="color:red"><span>just text</span></div>',
      );
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await pumpField(tester, controller);

      await pressPaste(tester);

      expect(controller.text, 'just text');
    });

    testWidgets('pastes plain text when the clipboard has no HTML', (
      tester,
    ) async {
      mockClipboard(tester, plain: 'plain only');
      final controller = TextEditingController(text: 'a ');
      addTearDown(controller.dispose);
      await pumpField(tester, controller);
      controller.selection = const TextSelection.collapsed(offset: 2);

      await pressPaste(tester);

      expect(controller.text, 'a plain only');
    });

    testWidgets('falls back to plain text when reading HTML fails', (
      tester,
    ) async {
      mockClipboard(tester, plain: 'fallback');
      clipboardHtmlReader = () async => throw StateError('no native clipboard');
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await pumpField(tester, controller);

      await pressPaste(tester);

      expect(controller.text, 'fallback');
    });

    testWidgets('an empty clipboard changes nothing', (tester) async {
      mockClipboard(tester);
      final controller = TextEditingController(text: 'keep');
      addTearDown(controller.dispose);
      await pumpField(tester, controller);

      await pressPaste(tester);

      expect(controller.text, 'keep');
    });
  });
}
