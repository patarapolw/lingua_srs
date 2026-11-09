import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:lingua_srs/services/lesson_links.dart';
import 'package:lingua_srs/widgets/lesson_content_view.dart';

void main() {
  group('LessonContent.parse', () {
    test('starts a chunk at every heading and collects headings', () {
      final content = LessonContent.parse(
        '# One\n\ntext\n\n## 두 번째\n\nmore\n\n### Three',
      );

      expect(content.chunks, ['# One\n\ntext', '## 두 번째\n\nmore', '### Three']);
      expect(content.headings.map((h) => h.level), [1, 2, 3]);
      expect(content.headings.map((h) => h.text), ['One', '두 번째', 'Three']);
      expect(content.headings.map((h) => h.chunk), [0, 1, 2]);
    });

    test('ignores headings and markers inside fenced code', () {
      final content = LessonContent.parse(
        '## A\n\n```\n# not a heading\n<!-- chunk -->\n```\n\n## A',
      );

      expect(content.headings.length, 2);
      expect(content.chunks.length, 2);
      expect(content.chunks.first, contains('<!-- chunk -->'));
    });

    test('returns nothing for empty input', () {
      final content = LessonContent.parse('  \n');

      expect(content.chunks, isEmpty);
      expect(content.headings, isEmpty);
    });

    test('cuts a long section at a blank line', () {
      final content = LessonContent.parse('aaaa\n\nbbbb\n\ncccc', maxChars: 5);

      expect(content.chunks, ['aaaa', 'bbbb', 'cccc']);
    });

    test('does not cut inside a list or a table', () {
      final content = LessonContent.parse(
        '- a\n\n- b\n\n| x |\n|---|\n\n| y |',
        maxChars: 1,
      );

      expect(content.chunks, ['- a\n\n- b\n\n| x |\n|---|\n\n| y |']);
    });

    test('forces a cut at <!-- chunk --> and drops the marker', () {
      final content = LessonContent.parse('one\n\n<!-- chunk -->\n\ntwo');

      expect(content.chunks, ['one', 'two']);
    });

    test('keeps a chunk:start/chunk:end group in one chunk', () {
      final content = LessonContent.parse(
        'before\n\n<!-- chunk:start -->\n\n# Inside\n\n<!-- chunk -->\n\n'
        'body\n\n<!-- chunk:end -->\n\nafter',
        maxChars: 1,
      );

      expect(content.chunks.length, 3);
      expect(content.chunks[0], 'before');
      expect(content.chunks[1], startsWith('# Inside'));
      expect(content.chunks[1], endsWith('body'));
      expect(content.chunks[2], 'after');
      expect(content.headings.single.chunk, 1);
    });
  });

  group('LessonContent.preprocess', () {
    test('turns components into what MarkdownContent renders', () {
      final text = LessonContent.preprocess(
        'Intro\n\n<YouTube id="abc123" />\n\n'
        '<AudioButton src="a.mp3" />\n\n<TTS>안녕</TTS>\n\n'
        '<span class="spoiler">hidden</span>',
      );

      expect(text, contains('lingua-youtube:'));
      expect(text, contains('lingua-audio:?src=a.mp3'));
      expect(text, contains('안녕 ![tts]'));
      expect(text, contains('![spoiler]'));
    });

    test('strips scripts, quizzes, unknown components and comments', () {
      final text = LessonContent.preprocess(
        '<VocabQuiz a="b" />\n<script>alert(1)</script>\n<Foo>x</Foo>\n'
        '<!-- note -->\n<!-- chunk -->',
      );

      expect(text, isNot(contains('VocabQuiz')));
      expect(text, isNot(contains('script')));
      expect(text, isNot(contains('Foo')));
      expect(text, isNot(contains('note')));
      expect(text, contains('<!-- chunk -->'));
    });

    test('turns [[lesson links]] into Markdown links', () {
      final text = LessonContent.preprocess(
        '[[Lesson 26#Past tense]]\n\n```\n[[Lesson 26]]\n```',
      );

      expect(text, contains('[Lesson 26 › Past tense](<lingua-lesson:'));
      expect(text, contains('```\n[[Lesson 26]]\n```'));
    });

    test('does not alter fenced code content', () {
      final text = LessonContent.preprocess('```\n<YouTube id="x" />\n```');

      expect(text, contains('<YouTube id="x" />'));
      expect(text, isNot(contains('lingua-youtube')));
    });
  });

  group('heading anchors', () {
    const markdown =
        '## Present\n\n### Polite\n\n## Past\n\n### Polite\n\n'
        '## Future\n\n### Polite {#future-polite .note}\n\n'
        'Plain\n=====\n\nSetext {#setext}\n------';

    test('number repeated headings and use {#id}', () {
      final content = LessonContent.parse(markdown);

      expect(content.headings.map((h) => h.anchor), [
        'present',
        'polite',
        'past',
        'polite-1',
        'future',
        'future-polite',
        'plain',
        'setext',
      ]);
      expect(content.headings[5].text, 'Polite');
      expect(content.headings[7].text, 'Setext');
    });

    test('drop {#id} from the rendered heading', () {
      final content = LessonContent.parse(markdown);

      expect(content.chunks[5], '### Polite');
      expect(content.chunks[7], startsWith('Setext\n---'));
    });

    test('a link finds a heading by anchor, then by text', () {
      final content = LessonContent.parse(markdown);

      expect(content.headingFor('polite'), same(content.headings[1]));
      expect(content.headingFor('Polite-1'), same(content.headings[3]));
      expect(content.headingFor('future-polite'), same(content.headings[5]));
      expect(content.headingFor('Past'), same(content.headings[2]));
      expect(content.headingFor('nothing'), isNull);
    });

    test('a site generator\'s anchor finds its heading', () {
      // VitePress writes `1. Intro` as `#_1-intro`.
      final content = LessonContent.parse('## 1. Intro\n\ntext');

      expect(content.headingFor('_1-intro'), same(content.headings.single));
    });
  });

  group('setext headings', () {
    test('are listed and start a chunk', () {
      final content = LessonContent.parse(
        'Intro\n\nTitle\n=====\n\nbody\n\nSub\n---\n\ntext',
      );

      expect(content.headings.map((h) => (h.level, h.text)), [
        (1, 'Title'),
        (2, 'Sub'),
      ]);
      expect(content.headings.map((h) => h.chunk), [1, 2]);
    });

    test('ignore rules after a multi-line paragraph and fenced code', () {
      final content = LessonContent.parse(
        'one\ntwo\n---\n\n```\nTitle\n=====\n```',
      );

      expect(content.headings, isEmpty);
    });
  });

  testWidgets('renders chunks and scrolls to a far heading', (tester) async {
    final controller = LessonContentController();
    final markdown = [
      for (var i = 0; i < 40; i++)
        '# Section $i\n\n${'word ' * ((i % 5 + 1) * 150)}',
    ].join('\n\n');
    final headings = LessonContent.parse(markdown).headings;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LessonContentView(markdown: markdown, controller: controller),
        ),
      ),
    );

    expect(find.textContaining('Section 0', findRichText: true), findsWidgets);
    expect(find.textContaining('Section 39', findRichText: true), findsNothing);

    controller.scrollToHeading(headings.last);
    await tester.pumpAndSettle();

    expect(find.textContaining('Section 39', findRichText: true), findsWidgets);
  });

  testWidgets('builds chunks ahead to stabilize the scroll extent', (
    tester,
  ) async {
    final markdown = [
      for (var i = 0; i < 40; i++) '# Section $i\n\n${'word ' * 100}',
    ].join('\n\n');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: LessonContentView(markdown: markdown)),
      ),
    );

    final list = tester.widget<ListView>(find.byType(ListView));
    expect(list.scrollCacheExtent, const ScrollCacheExtent.pixels(4000));
  });

  testWidgets('lesson markdown fills its reading column', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: LessonContentView(markdown: '# A short heading')),
      ),
    );

    final markdownBox = tester.renderObject<RenderBox>(
      find.byType(MarkdownBody),
    );
    expect(markdownBox.size.width, greaterThan(700));
  });

  group('lesson links', () {
    final markdown = [
      '[[#Section 39]]',
      '[[Other lesson#Part two|other]]',
      for (var i = 0; i < 40; i++) '# Section $i\n\n${'word ' * 300}',
    ].join('\n\n');

    testWidgets('a [[#Heading]] link scrolls to the heading', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: LessonContentView(markdown: markdown)),
        ),
      );
      expect(
        find.textContaining('Section 39', findRichText: true),
        findsOneWidget,
      );

      await tester.tap(find.text('Section 39', findRichText: true));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Section 0', findRichText: true),
        findsNothing,
      );
      expect(
        find.textContaining('Section 39', findRichText: true),
        findsWidgets,
      );
    });

    testWidgets('a link to another lesson goes to onLessonLink', (
      tester,
    ) async {
      final links = <LessonLink>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LessonContentView(
              markdown: markdown,
              onLessonLink: links.add,
            ),
          ),
        ),
      );

      await tester.tap(find.text('other', findRichText: true));
      await tester.pump();

      expect(links.single.lesson, 'Other lesson');
      expect(links.single.heading, 'Part two');
    });

    testWidgets('opens at initialHeading', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LessonContentView(
              markdown: markdown,
              initialHeading: 'section-39',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Section 0', findRichText: true),
        findsNothing,
      );
    });
  });
}
