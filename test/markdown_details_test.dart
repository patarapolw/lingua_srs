import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/widgets/markdown_content.dart';
import 'package:lingua_srs/widgets/markdown_details.dart';

void main() {
  group('MarkdownDetailsPart.split', () {
    test('returns null without a details block', () {
      expect(MarkdownDetailsPart.split('plain **text**'), isNull);
      expect(MarkdownDetailsPart.split('Write `<details>` here.'), isNull);
      expect(
        MarkdownDetailsPart.split('```html\n<details>x</details>\n```'),
        isNull,
      );
    });

    test('cuts the text around a block and reads its summary', () {
      final parts = MarkdownDetailsPart.split(
        'before\n\n<details>\n<summary>More **words**</summary>\n\n'
        '- one\n- two\n\n</details>\n\nafter',
      )!;

      expect(parts.map((part) => part.isDetails), [false, true, false]);
      expect(parts[0].text, 'before');
      expect(parts[1].summary, 'More **words**');
      expect(parts[1].text, '- one\n- two');
      expect(parts[1].open, isFalse);
      expect(parts[2].text, 'after');
    });

    test('reads the open attribute, in any case', () {
      expect(
        MarkdownDetailsPart.split('<details open>x</details>')!.single.open,
        isTrue,
      );
      expect(
        MarkdownDetailsPart.split('<DETAILS class="a" OPEN="">x</DETAILS>')!
            .single
            .open,
        isTrue,
      );
      expect(
        MarkdownDetailsPart.split('<details class="opened">x</details>')!
            .single
            .open,
        isFalse,
      );
    });

    test('names a block without a summary', () {
      final part = MarkdownDetailsPart.split('<details>hidden</details>')!;

      expect(part.single.summary, MarkdownDetailsPart.defaultSummary);
      expect(part.single.text, 'hidden');
    });

    test('keeps a block inside another in the outer one', () {
      final parts = MarkdownDetailsPart.split(
        '<details><summary>Outer</summary>\n\na\n\n'
        '<details><summary>Inner</summary>\n\nb\n\n</details>\n\n'
        'c\n\n</details>',
      )!;

      expect(parts, hasLength(1));
      expect(parts.single.summary, 'Outer');
      final inner = MarkdownDetailsPart.split(parts.single.text)!;
      expect(inner.map((part) => part.summary), [null, 'Inner', null]);
    });

    test('a block that is never closed runs to the end', () {
      final parts = MarkdownDetailsPart.split(
        'a\n\n<details><summary>S</summary>\n\nrest',
      )!;

      expect(parts.last.summary, 'S');
      expect(parts.last.text, 'rest');
    });
  });

  group('MarkdownContent with details', () {
    Future<void> pump(WidgetTester tester, String content) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: MarkdownContent(content: content)),
        ),
      ),
    );

    testWidgets('a block is closed until its summary is tapped', (
      tester,
    ) async {
      await pump(
        tester,
        'before\n\n<details>\n<summary>Examples</summary>\n\n'
        '- **one**\n- two\n\n</details>\n\nafter',
      );

      expect(find.text('before'), findsOneWidget);
      expect(find.text('Examples'), findsOneWidget);
      expect(find.text('after'), findsOneWidget);
      expect(find.text('one'), findsNothing);
      expect(find.textContaining('<'), findsNothing);

      await tester.tap(find.text('Examples'));
      await tester.pump();
      expect(find.text('one'), findsOneWidget);
      expect(find.text('two'), findsOneWidget);

      await tester.tap(find.text('Examples'));
      await tester.pump();
      expect(find.text('one'), findsNothing);
    });

    testWidgets('in selectable text, tapping the summary text opens it', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: MarkdownContent(
                content:
                    '<details>\n<summary>New sentences</summary>\n\n'
                    '- **one**\n\n</details>',
                selectable: true,
              ),
            ),
          ),
        ),
      );
      final inside = find.byWidgetPredicate(
        (widget) => widget is MarkdownContent && widget.content == '- **one**',
      );
      expect(inside, findsNothing);

      // The middle of the summary's text, away from the arrow.
      await tester.tap(find.text('New sentences'));
      await tester.pump();
      expect(inside, findsOneWidget);

      await tester.tap(find.text('New sentences'));
      await tester.pump();
      expect(inside, findsNothing);
    });

    testWidgets('an open block starts shown', (tester) async {
      await pump(
        tester,
        '<details open><summary>Examples</summary>\n\ninside\n\n</details>',
      );

      expect(find.text('inside'), findsOneWidget);
    });

    testWidgets('a block inside another opens by itself', (tester) async {
      await pump(
        tester,
        '<details><summary>Outer</summary>\n\nouter text\n\n'
        '<details><summary>Inner</summary>\n\ninner text\n\n</details>\n\n'
        '</details>',
      );

      await tester.tap(find.text('Outer'));
      await tester.pump();
      expect(find.text('outer text'), findsOneWidget);
      expect(find.text('Inner'), findsOneWidget);
      expect(find.text('inner text'), findsNothing);

      await tester.tap(find.text('Inner'));
      await tester.pump();
      expect(find.text('inner text'), findsOneWidget);
    });

    testWidgets('Markdown without a block is one Markdown body', (
      tester,
    ) async {
      await pump(tester, 'plain **text**');

      expect(find.byType(MarkdownDetails), findsNothing);
      expect(find.text('plain text'), findsOneWidget);
    });
  });
}
