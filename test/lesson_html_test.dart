import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/widgets/lesson_content_view.dart';
import 'package:lingua_srs/widgets/lesson_html.dart';

String body(String markdown) => LessonHtml.body(LessonContent.parse(markdown));

void main() {
  group('LessonHtml.body', () {
    test('renders Markdown with GitHub extensions', () {
      final html = body(
        '**bold** and ~~gone~~\n\n| a | b |\n|---|---|\n| 1 | 2 |',
      );

      expect(html, contains('<strong>bold</strong>'));
      expect(html, contains('<del>gone</del>'));
      expect(html, contains('<table>'));
    });

    test('keeps HTML in the Markdown for the browser', () {
      final html = body(
        'Line<br>two <mark>marked</mark> <ins>new</ins>\n\n'
        '<div class="box">\n\n**inside**\n\n</div>\n\n'
        '<details open>\n<summary>More</summary>\n\nhidden **text**\n\n'
        '</details>',
      );

      expect(html, contains('<br>'));
      expect(html, contains('<mark>marked</mark>'));
      expect(html, contains('<ins>new</ins>'));
      expect(html, contains('<div class="box">'));
      expect(html, contains('<details open>'));
      expect(html, contains('<summary>More</summary>'));
      expect(html, contains('<strong>text</strong>'));
    });

    test('gives headings the anchors the table of contents uses', () {
      final content = LessonContent.parse(
        '# One\n\n## Same\n\n## Same\n\n## Custom {#mine}',
      );
      final html = LessonHtml.body(content);

      expect(content.headings.map((h) => h.anchor), [
        'one',
        'same',
        'same-1',
        'mine',
      ]);
      expect(html, contains('<h1 id="one">One</h1>'));
      expect(html, contains('<h2 id="same">Same</h2>'));
      expect(html, contains('<h2 id="same-1">Same</h2>'));
      expect(html, contains('<h2 id="mine">Custom</h2>'));
    });

    test('drops scripts, handlers and chunk markers', () {
      final html = body(
        'a<script>alert(1)</script>\n\n<!-- chunk -->\n\n'
        '<b onclick="x()" class="k">b</b> <img src="p.png" onerror=boom()>',
      );

      expect(html, isNot(contains('script')));
      expect(html, isNot(contains('onclick')));
      expect(html, isNot(contains('onerror')));
      expect(html, isNot(contains('chunk')));
      expect(html, contains('<b class="k">b</b>'));
    });

    test('shows handler text in code as typed', () {
      final html = body('Use `<b onclick="x()">` carefully.');

      expect(html, contains('onclick'));
    });

    test('a YouTube tag becomes a player placeholder', () {
      final html = body('<YouTube id="dQw4w9WgXcQ" />');

      expect(html, contains('class="yt"'));
      expect(html, contains('youtube-nocookie.com/embed/dQw4w9WgXcQ'));
      expect(html, contains('data-thumb="https://img.youtube.com/vi/'));
      expect(html, contains('data-watch="https://www.youtube.com/watch?v='));
      expect(
        html,
        contains('<a class="yt-open" href="https://www.youtube.com/watch?v='),
      );
      expect(html, contains('Open on YouTube'));
      expect(
        html,
        contains('<div class="yt-title">Loading video title…</div>'),
      );
      expect(html, contains('data-oembed="https://www.youtube.com/oembed?'));
      expect(html, isNot(contains('<p><div')));
    });

    test('a playlist-only YouTube tag has no title to load', () {
      final html = body('<YouTube list="PL123" />');

      expect(html, contains('class="yt"'));
      expect(html, isNot(contains('yt-title')));
      expect(html, isNot(contains('data-oembed')));
    });

    test('audio and TTS tags become buttons the page script handles', () {
      final html = body(
        '<AudioButton src="https://a.test/x.mp3" />\n\n'
        '<TTS>안녕하세요</TTS>',
      );

      expect(html, contains('class="audio"'));
      expect(html, contains('data-src="https://a.test/x.mp3"'));
      expect(html, contains('class="tts"'));
      expect(html, contains('data-text="안녕하세요"'));
      expect(html, contains('안녕하세요 <button'));
    });

    test('a spoiler keeps the Markdown in it', () {
      final html = body('Say <span class="spoiler">my **brother**</span>.');

      expect(html, contains('class="spoiler"'));
      expect(html, contains('my <strong>brother</strong>'));
    });

    test('lesson links are links the app handles', () {
      final html = body('[[Unit 2::Lesson 26#Past tense]]');

      expect(html, contains('<a href="lingua-lesson:'));
    });

    test('images load lazily', () {
      expect(body('![x](https://a.test/p.png)'), contains('loading="lazy"'));
    });
  });

  group('LessonHtml pages', () {
    final theme = ThemeData(brightness: Brightness.dark);

    test('css follows the theme and the text size', () {
      final css = LessonHtml.css(theme, fontSize: 20);

      expect(css, contains('color-scheme: dark'));
      expect(css, contains('font: 20.0px/1.6'));
      expect(css, contains('max-width: 900px'));
    });

    test('a page holds the style, the body, the script and the start', () {
      final page = LessonHtml.page(
        'p{}',
        '<p>hi</p>',
        start: LessonHtml.start(scrollY: 12, anchor: 'a</script>'),
      );

      expect(page, startsWith('<!DOCTYPE html>'));
      expect(page, contains('<style>p{}</style>'));
      expect(page, contains('<div id="content"><p>hi</p></div>'));
      expect(page, contains('function linguaPost'));
      expect(page, contains('.yt-title'));
      expect(page, contains('linguaStart(12.0, "a\\u003c/script>");'));
      expect('</script>'.allMatches(page), hasLength(1));
    });

    test('an injection replaces the document, then runs the script', () {
      final script = LessonHtml.injection('p{}', '<p>hi</p>', start: 'go();');

      expect(script, startsWith('document.documentElement.innerHTML = "'));
      expect(script, contains(r'\u003cp>hi\u003c/p>'));
      expect(script, endsWith('go();'));
    });
  });
}
