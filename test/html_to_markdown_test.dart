import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/services/html_to_markdown.dart';

void main() {
  group('htmlToMarkdown', () {
    test('converts bold, italic, links and code', () {
      expect(
        htmlToMarkdown('<b>Bold</b> and <strong>strong</strong> and <i>it</i>'),
        '**Bold** and **strong** and *it*',
      );
      expect(
        htmlToMarkdown(
          '<a href="https://x.com">link</a> and <code>code</code>',
        ),
        '[link](https://x.com) and `code`',
      );
    });

    test('emphasis sits right next to Korean text', () {
      expect(htmlToMarkdown('<b>배</b>를 <i>먹어요</i>'), '**배**를 *먹어요*');
    });

    test('converts headings and paragraphs', () {
      expect(
        htmlToMarkdown('<h1>Title</h1><p>Para one</p><p>Para two</p>'),
        '# Title\n\nPara one\n\nPara two',
      );
    });

    test('converts lists with plain markers', () {
      expect(
        htmlToMarkdown(
          '<ul><li>one</li><li>two<ul><li>nested</li></ul></li></ul>'
          '<ol><li>a</li><li>b</li></ol>',
        ),
        '- one\n- two\n    - nested\n\n1. a\n2. b',
      );
    });

    test('keeps indentation inside fenced code', () {
      expect(
        htmlToMarkdown('<pre><code>line1\n  line2</code></pre>'),
        '```\nline1\n  line2\n```',
      );
    });

    test('converts tables', () {
      expect(
        htmlToMarkdown(
          '<table><tr><th>A</th><th>B</th></tr>'
          '<tr><td>1</td><td>2</td></tr></table>',
        ),
        '| A | B |\n| --- | --- |\n| 1 | 2 |',
      );
    });

    test('reads bold and italic from inline styles (Google Docs, Word)', () {
      expect(
        htmlToMarkdown(
          '<meta charset="utf-8">'
          '<b style="font-weight:normal;" id="docs-internal-guid-1">'
          '<p dir="ltr"><span style="font-weight:700;">Hello</span> '
          '<span style="font-style:italic;">there</span> <span>plain</span>'
          '</p></b>',
        ),
        '**Hello** *there* plain',
      );
      expect(
        htmlToMarkdown(
          '<span style="font-weight:bold">sty</span> '
          '<span style="font-weight:700;font-style:italic">both</span> '
          '<span style="text-decoration:line-through">gone</span>',
        ),
        '**sty** ***both*** ~~gone~~',
      );
    });

    test('uses only the copied fragment when it is marked', () {
      expect(
        htmlToMarkdown(
          '<!--StartFragment--><p>in <b>fragment</b></p><!--EndFragment--> out',
        ),
        'in **fragment**',
      );
    });

    test('ignores scripts', () {
      expect(
        htmlToMarkdown('<script>alert(1)</script><b>safe</b>'),
        '**safe**',
      );
    });

    test('returns null when there is no formatting to keep', () {
      expect(
        htmlToMarkdown(
          '<div style="color:red"><span style="color:blue">text</span></div>',
        ),
        isNull,
      );
      expect(htmlToMarkdown('<p>a&nbsp;b</p>'), isNull);
      expect(htmlToMarkdown(''), isNull);
      expect(htmlToMarkdown('<b>   </b>'), isNull);
    });
  });
}
