import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/widgets/markdown_content.dart';

void main() {
  test('converts spoiler spans into interactive Markdown markers', () {
    final prepared = MarkdownContent.prepareSpoilerSpans(
      '<span class="spoiler">hidden words</span>',
    );

    expect(prepared, contains('![spoiler]'));
    expect(
      Uri.parse(RegExp(r'<(lingua-spoiler:[^>]+)>').firstMatch(prepared)![1]!)
          .queryParameters['text'],
      'hidden words',
    );
  });

  testWidgets('renders horizontal rules as thin dividers', (tester) async {
    for (final content in [
      'before\n\n---\n\nafter',
      'before\n\n<hr>\n\nafter',
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: MarkdownContent(content: content)),
        ),
      );

      expect(
        find.byWidgetPredicate((widget) {
          if (widget is! Container || widget.decoration is! BoxDecoration) {
            return false;
          }
          final border = (widget.decoration! as BoxDecoration).border;
          return border is Border && border.top.width == 1;
        }),
        findsOneWidget,
        reason: 'Expected a 1-pixel rule for: $content',
      );
    }
  });

  testWidgets('spoiler text reveals on tap for touch interaction', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MarkdownContent(
            content: '![spoiler](<lingua-spoiler:?text=hidden>)',
          ),
        ),
      ),
    );

    expect(find.byType(SpoilerText), findsOneWidget);
    expect(find.byType(ImageFiltered), findsOneWidget);

    await tester.tap(find.byType(SpoilerText));
    await tester.pumpAndSettle();

    expect(find.byType(ImageFiltered), findsNothing);
    expect(find.text('hidden'), findsOneWidget);
  });

  testWidgets('spoiler text reveals on hover for desktop interaction', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MarkdownContent(
            content: '![spoiler](<lingua-spoiler:?text=hidden>)',
          ),
        ),
      ),
    );

    final spoiler = find.byType(SpoilerText);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(spoiler));
    await tester.pumpAndSettle();
    expect(find.byType(ImageFiltered), findsNothing);

    await mouse.moveTo(const Offset(700, 500));
    await tester.pumpAndSettle();
    expect(find.byType(ImageFiltered), findsOneWidget);
  });
}
