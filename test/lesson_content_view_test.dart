import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
      final content = LessonContent.parse(
        'aaaa\n\nbbbb\n\ncccc',
        maxChars: 5,
      );

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

    test('does not alter fenced code content', () {
      final text = LessonContent.preprocess('```\n<YouTube id="x" />\n```');

      expect(text, contains('<YouTube id="x" />'));
      expect(text, isNot(contains('lingua-youtube')));
    });
  });

  testWidgets('renders chunks and scrolls to a far heading', (tester) async {
    final controller = LessonContentController();
    final markdown = [
      for (var i = 0; i < 40; i++) '# Section $i\n\n${'word ' * 40}',
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
}
