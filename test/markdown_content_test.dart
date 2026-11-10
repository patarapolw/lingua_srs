import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:provider/provider.dart';
import 'package:lingua_srs/services/audio_service.dart';
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

  testWidgets('uses left-aligned headings with browser-like spacing', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: MarkdownContent(content: '# Heading\n\nText')),
      ),
    );

    final markdown = tester.widget<MarkdownBody>(find.byType(MarkdownBody));
    final styles = markdown.styleSheet!;
    expect(styles.h1Align, WrapAlignment.start);
    expect(styles.h2Align, WrapAlignment.start);
    expect(styles.h3Align, WrapAlignment.start);
    expect(styles.h4Align, WrapAlignment.start);
    expect(styles.h5Align, WrapAlignment.start);
    expect(styles.h6Align, WrapAlignment.start);
    final headingStyles = [
      (styles.h1!, styles.h1Padding!),
      (styles.h2!, styles.h2Padding!),
      (styles.h3!, styles.h3Padding!),
      (styles.h4!, styles.h4Padding!),
      (styles.h5!, styles.h5Padding!),
      (styles.h6!, styles.h6Padding!),
    ];
    for (final (heading, padding) in headingStyles) {
      expect(padding.top, greaterThanOrEqualTo(heading.fontSize! * 0.6));
      expect(padding.bottom, greaterThan(0));
    }
    expect(styles.h1!.fontSize, greaterThan(styles.h2!.fontSize!));
    expect(styles.h2!.fontSize, greaterThan(styles.h3!.fontSize!));
    expect(styles.h3!.fontSize, greaterThan(styles.h4!.fontSize!));
    expect(styles.h4!.fontSize, greaterThan(styles.h5!.fontSize!));
    expect(styles.h5!.fontSize, greaterThan(styles.h6!.fontSize!));
    expect(styles.blockSpacing, 16);
  });

  testWidgets('keeps bold and code in headings at the heading size', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MarkdownContent(
            content: '# Mnemonics for **강** (river)\n\n### `~은/ㄴ 듯이` as if',
          ),
        ),
      ),
    );

    final styles = tester
        .widget<MarkdownBody>(find.byType(MarkdownBody))
        .styleSheet!;
    for (final (text, heading) in [
      ('Mnemonics', styles.h1!),
      ('as if', styles.h3!),
    ]) {
      final finder = find.byWidgetPredicate(
        (widget) =>
            widget is RichText && widget.text.toPlainText().contains(text),
      );
      expect(finder, findsOneWidget);
      final sizes = <double?>[];
      void collect(InlineSpan span, TextStyle? inherited) {
        final style = inherited?.merge(span.style) ?? span.style;
        if (span is TextSpan) {
          if (span.text?.isNotEmpty ?? false) sizes.add(style?.fontSize);
          for (final child in span.children ?? const <InlineSpan>[]) {
            collect(child, style);
          }
        }
      }

      collect(tester.widget<RichText>(finder).text, null);
      expect(sizes, isNotEmpty);
      expect(sizes, everyElement(heading.fontSize), reason: text);
      // Lines are at least as tall as the heading text, so wrapped lines
      // don't overlap.
      expect(
        tester.getSize(finder).height,
        greaterThanOrEqualTo(heading.fontSize!),
        reason: text,
      );
    }
  });

  testWidgets('follows links in headings', (tester) async {
    final tapped = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MarkdownContent(
            content: '## See [the lesson](lesson-target) **now**',
            onLink: (href) {
              tapped.add(href);
              return true;
            },
          ),
        ),
      ),
    );

    await tester.tapOnText(find.textRange.ofSubstring('the lesson'));
    expect(tapped, ['lesson-target']);
  });

  testWidgets('renders HTML del tags with strikethrough styling', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: MarkdownContent(content: '<del>removed</del>')),
      ),
    );

    expect(find.text('removed'), findsOneWidget);
    final richTextWidgets = tester.widgetList<RichText>(find.byType(RichText));
    bool hasStrikethrough(InlineSpan span) {
      if (span is! TextSpan) return false;
      if (span.style?.decoration == TextDecoration.lineThrough) return true;
      return span.children?.any(hasStrikethrough) ?? false;
    }

    expect(
      richTextWidgets.any((richText) => hasStrikethrough(richText.text)),
      isTrue,
    );
  });

  testWidgets('centers audio controls on text in Markdown table cells', (
    tester,
  ) async {
    final audioService = AudioService();
    addTearDown(audioService.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChangeNotifierProvider<AudioService>.value(
            value: audioService,
            child: const MarkdownContent(
              content:
                  '| Audio | Text |\n'
                  '| --- | --- |\n'
                  '| Play ![audio](<lingua-audio:?src=a.mp3>) | '
                  'Say ![tts](<lingua-audio:?text=안녕>) |',
            ),
          ),
        ),
      ),
    );

    for (final (label, text) in [
      ('Play Audio', 'Play'),
      ('Play Text-to-Speech', 'Say'),
    ]) {
      final button = find.byTooltip(label);
      final cellText = find.byWidgetPredicate(
        (widget) =>
            widget is RichText && widget.text.toPlainText().contains(text),
      );
      expect(button, findsOneWidget);
      expect(cellText, findsOneWidget);
      expect(
        tester.getCenter(button).dy,
        closeTo(tester.getCenter(cellText).dy + 4, 0.6),
      );
    }
  });

  testWidgets('does not convert HTML del tags inside Markdown code', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MarkdownContent(
            content: '`<del>inline</del>`\n\n```\n<del>block</del>\n```',
          ),
        ),
      ),
    );

    final markdown = tester.widget<MarkdownBody>(find.byType(MarkdownBody));
    expect(markdown.data, contains('`<del>inline</del>`'));
    expect(markdown.data, contains('<del>block</del>'));
    expect(markdown.data, isNot(contains('~~inline~~')));
    expect(markdown.data, isNot(contains('~~block~~')));
  });

  testWidgets('opens external web links and ignores relative links', (
    tester,
  ) async {
    const channel = MethodChannel('plugins.flutter.io/url_launcher');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return true;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MarkdownContent(content: '[web](https://example.com)'),
        ),
      ),
    );
    await tester.tap(find.text('web'));
    await tester.pumpAndSettle();

    expect(calls, hasLength(1));
    expect(calls.single.method, 'launch');
    expect(
      (calls.single.arguments as Map<Object?, Object?>)['url'],
      'https://example.com',
    );
    expect(
      (calls.single.arguments as Map<Object?, Object?>)['useWebView'],
      false,
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MarkdownContent(content: '[lesson](./06-honorifics.md)'),
        ),
      ),
    );
    await tester.tap(find.text('lesson'));
    await tester.pumpAndSettle();
    expect(calls, hasLength(1));
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
