import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/widgets/lesson_html_view.dart';

void main() {
  test('renders Markdown, rules and headings as one HTML document', () {
    final html = LessonHtmlView.markdownToHtmlBody(
      '### Title\n\nBody **bold**\n\n---\n\n| a | b |\n|---|---|\n| 1 | 2 |',
    );

    expect(html, contains('<h3>Title</h3>'));
    expect(html, contains('<hr />'));
    expect(html, contains('<table>'));
  });

  test('keeps YouTube embeds, spoilers and strips unknown components', () {
    final html = LessonHtmlView.markdownToHtmlBody(
      'Intro\n\n<YouTube id="abc123" />\n\n'
      '<span class="spoiler">hidden</span>\n\n<VocabQuiz a="b" />\n\n'
      '<script>alert(1)</script>',
    );

    expect(html, contains('class="yt"'));
    expect(html, contains('youtube.com/embed/abc123'));
    expect(html, contains('class="spoiler"'));
    expect(html, isNot(contains('VocabQuiz')));
    expect(html, isNot(contains('<script')));
  });

  test('does not alter fenced code content', () {
    final html = LessonHtmlView.markdownToHtmlBody(
      '```\n<YouTube id="x" />\n```',
    );

    expect(html, contains('&lt;YouTube'));
    expect(html, isNot(contains('class="yt"')));
  });
}
