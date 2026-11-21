import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/services/yaml_parser_service.dart';
import 'package:lingua_srs/widgets/markdown_editor.dart';
import 'package:material_ui/material_ui.dart';
import 'package:webview_platform_interface/webview_platform_interface.dart';

import 'fake_webview_platform.dart';

void main() {
  late FakeWebViewPlatform webview;
  setUp(() {
    webview = FakeWebViewPlatform();
    WebViewPlatform.instance = webview;
  });

  Widget host(
    TextEditingController controller, {
    bool enabled = true,
    bool startInPreview = false,
    bool allowPreview = true,
    String Function(String)? previewMarkdown,
    ValueChanged<String>? onChanged,
  }) => MaterialApp(
    home: Scaffold(
      body: MarkdownEditor(
        controller: controller,
        enabled: enabled,
        hintText: '# Lesson 1',
        startInPreview: startInPreview,
        allowPreview: allowPreview,
        previewMarkdown: previewMarkdown,
        onChanged: onChanged,
        fallback: const Text('text field'),
      ),
    ),
  );

  group('MarkdownEditorHtml', () {
    test('pastes formatted HTML as Markdown, other HTML as its text', () {
      expect(
        MarkdownEditorHtml.pastedText('<p><b>학교</b> school</p>', '학교 school'),
        '**학교** school',
      );
      expect(
        MarkdownEditorHtml.pastedText('<span>plain</span>', 'plain'),
        'plain',
      );
      expect(MarkdownEditorHtml.pastedText('', 'only text'), 'only text');
    });

    test('keeps the text from closing the page script', () {
      final start = MarkdownEditorHtml.start(text: '</script><b>');
      expect(start, isNot(contains('</')));
      expect(MarkdownEditorHtml.setText('</script>'), isNot(contains('</')));
      final page = MarkdownEditorHtml.page('', start: start);
      expect('</script>'.allMatches(page), hasLength(1));
    });
  });

  testWidgets('shows the fallback where there is no WebView', (tester) async {
    MarkdownEditor.debugUseWebView = false;
    addTearDown(() => MarkdownEditor.debugUseWebView = null);
    await tester.pumpWidget(host(TextEditingController(text: '# Hi')));

    expect(find.text('text field'), findsOneWidget);
    expect(find.text('Preview'), findsNothing);
    expect(webview.controllers, isEmpty);
  });

  testWidgets('starts the WebView only once asked to write', (tester) async {
    final controller = TextEditingController();
    await tester.pumpWidget(host(controller));
    await tester.pumpAndSettle();

    expect(find.text('Tap to write Markdown'), findsOneWidget);
    expect(find.text('# Lesson 1'), findsOneWidget);
    expect(webview.controllers, isEmpty);

    await tester.tap(find.text('Tap to write Markdown'));
    await tester.pumpAndSettle();
    expect(webview.controllers, hasLength(1));
    final page = webview.controller.html!;
    expect(page, contains('<textarea id="editor"'));
    expect(page, contains('linguaEditorStart("", "# Lesson 1", false, true'));
  });

  testWidgets('starts the WebView when text is put in by the app', (
    tester,
  ) async {
    final controller = TextEditingController();
    await tester.pumpWidget(host(controller));
    await tester.pumpAndSettle();
    expect(webview.controllers, isEmpty);

    controller.text = '# From a file';
    await tester.pumpAndSettle();
    expect(webview.controllers, hasLength(1));
    expect(webview.controller.html, contains('# From a file'));
  });

  testWidgets('does not start the WebView while disabled', (tester) async {
    await tester.pumpWidget(host(TextEditingController(), enabled: false));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Tap to write Markdown'));
    await tester.pumpAndSettle();
    expect(webview.controllers, isEmpty);
  });

  testWidgets('keeps the controller and the page in step', (tester) async {
    final controller = TextEditingController(text: 'one');
    final changes = <String>[];
    await tester.pumpWidget(host(controller, onChanged: changes.add));
    await tester.pumpAndSettle();
    final page = webview.controller;
    page.finish();
    await tester.pump();

    page.send({'type': 'change', 'text': 'one two', 'start': 3, 'end': 7});
    await tester.pump();
    expect(controller.text, 'one two');
    expect(
      controller.selection,
      const TextSelection(baseOffset: 3, extentOffset: 7),
    );
    expect(changes, ['one two']);
    // What came from the page is not sent back to it.
    expect(
      page.scripts.where((s) => s.startsWith('linguaEditorSetText')),
      isEmpty,
    );

    controller.text = 'three';
    await tester.pump();
    expect(page.scripts.last, 'linguaEditorSetText("three");');
    expect(changes, ['one two']);
  });

  testWidgets('sends text set while the page loads once it has loaded', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'one');
    await tester.pumpWidget(host(controller));
    await tester.pumpAndSettle();
    final page = webview.controller;

    controller.text = 'two';
    await tester.pump();
    expect(page.scripts, isEmpty);

    page.finish();
    await tester.pump();
    expect(page.scripts.last, 'linguaEditorSetText("two");');
  });

  testWidgets('converts pasted HTML to Markdown', (tester) async {
    await tester.pumpWidget(host(TextEditingController(text: 'ab')));
    await tester.pumpAndSettle();
    final page = webview.controller;
    page.finish();
    await tester.pump();

    page.send({
      'type': 'paste',
      'html': '<b>bold</b>',
      'text': 'bold',
      'start': 1,
      'end': 1,
    });
    await tester.pump();
    expect(page.scripts.last, 'linguaEditorInsert(1, 1, "**bold**");');
  });

  testWidgets('tells the page when it is disabled', (tester) async {
    final controller = TextEditingController(text: 'text');
    await tester.pumpWidget(host(controller));
    await tester.pumpAndSettle();
    final page = webview.controller;
    page.finish();
    await tester.pump();

    await tester.pumpWidget(host(controller, enabled: false));
    await tester.pump();
    expect(page.scripts.last, 'linguaEditorSetDisabled(true);');
  });

  testWidgets('opens on Preview when asked, showing previewMarkdown', (
    tester,
  ) async {
    final controller = TextEditingController(
      text: '---\nvocabulary:\n---\n# Shown heading\n',
    );
    await tester.pumpWidget(
      host(
        controller,
        startInPreview: true,
        previewMarkdown: YamlParserService.withoutFrontmatter,
      ),
    );
    await tester.pumpAndSettle();

    expect(webview.controllers, hasLength(1));
    final html = webview.controller.html!;
    expect(html, contains('Shown heading'));
    expect(html, isNot(contains('vocabulary:')));
    expect(html, isNot(contains('<textarea')));
  });

  testWidgets('keeps one WebView each for Edit and Preview', (tester) async {
    // Off Android, where focus goes through the page alone.
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final controller = TextEditingController(text: '# One');
    await tester.pumpWidget(host(controller, startInPreview: true));
    await tester.pumpAndSettle();
    expect(webview.controllers, hasLength(1));
    final preview = webview.controller;

    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    expect(webview.controllers, hasLength(2));
    final editor = webview.controller;
    expect(editor.html, contains('<textarea id="editor"'));
    editor.finish();
    await tester.pump();

    editor.send({'type': 'change', 'text': '# Two', 'start': 5, 'end': 5});
    await tester.tap(find.text('Preview'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();

    expect(webview.controllers, [preview, editor]);
    expect(preview.html, contains('Two'));
    // Back in Edit, the editor takes focus again.
    expect(editor.scripts.last, MarkdownEditorHtml.focus);

    // Leaving releases both WebViews rather than waiting for the GC.
    expect(preview.closed || editor.closed, isFalse);
    await tester.pumpWidget(const SizedBox());
    expect(preview.closed && editor.closed, isTrue);
  });

  testWidgets('asks Android to focus the WebView, so the keyboard opens', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('lingua/markdown_editor'),
      (call) async {
        calls.add(call);
        return true;
      },
    );
    final controller = TextEditingController(text: '# One');
    await tester.pumpWidget(host(controller, startInPreview: true));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    final editor = webview.controller;
    editor.finish();
    await tester.pump();

    expect(calls, hasLength(1));
    final title = (calls.single.arguments as Map)['title'] as String;
    expect(editor.html, contains('<title>$title</title>'));

    await tester.tap(find.text('Preview'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    expect(calls, hasLength(2));
    // The native side ran the focus script, so the page is not sent it.
    expect(editor.scripts, isNot(contains(MarkdownEditorHtml.focus)));
  });

  testWidgets('offers no Preview for YAML', (tester) async {
    await tester.pumpWidget(
      host(
        TextEditingController(text: 'vocabulary:'),
        startInPreview: true,
        allowPreview: false,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Preview'), findsNothing);
    expect(webview.controller.html, contains('<textarea id="editor"'));
  });

  group('YamlParserService.withoutFrontmatter', () {
    test('drops the frontmatter and its --- lines', () {
      expect(
        YamlParserService.withoutFrontmatter(
          '---\nvocabulary:\n  nouns: []\n---\n# Lesson\n\nText.\n',
        ),
        '# Lesson\n\nText.\n',
      );
    });

    test('keeps Markdown without frontmatter as it is', () {
      expect(
        YamlParserService.withoutFrontmatter('# Lesson\n\n---\n\nText.\n'),
        '# Lesson\n\n---\n\nText.\n',
      );
    });
  });
}
