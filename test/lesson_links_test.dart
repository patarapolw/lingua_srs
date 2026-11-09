import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/lesson.dart';
import 'package:lingua_srs/services/lesson_export_service.dart';
import 'package:lingua_srs/services/lesson_links.dart';
import 'package:lingua_srs/services/yaml_parser_service.dart';

void main() {
  group('LessonLink.prepareWikiLinks', () {
    test('turns a lesson link into a Markdown link named by its target', () {
      final text = LessonLink.prepareWikiLinks('See [[Lesson 26]].');

      expect(text, startsWith('See [Lesson 26](<lingua-lesson:'));
      final href = RegExp(r'\(<([^>]+)>\)').firstMatch(text)![1]!;
      final link = LessonLink.fromHref(href)!;
      expect(link.lesson, 'Lesson 26');
      expect(link.heading, isNull);
    });

    test('names a lesson heading link with › between the parts', () {
      final text = LessonLink.prepareWikiLinks(
        '[[ Unit 2 :: Lesson 26 #Past tense ]]',
      );

      expect(text, startsWith('[Unit 2 › Lesson 26 › Past tense]'));
      final href = RegExp(r'\(<([^>]+)>\)').firstMatch(text)![1]!;
      final link = LessonLink.fromHref(href)!;
      expect(link.lesson, 'Unit 2::Lesson 26');
      expect(link.heading, 'Past tense');
    });

    test('links a heading in the same lesson', () {
      final text = LessonLink.prepareWikiLinks('[[#Greetings]]');

      expect(text, startsWith('[Greetings]'));
      final href = RegExp(r'\(<([^>]+)>\)').firstMatch(text)![1]!;
      final link = LessonLink.fromHref(href)!;
      expect(link.lesson, isNull);
      expect(link.heading, 'Greetings');
    });

    test('uses the label after |', () {
      final text = LessonLink.prepareWikiLinks(
        '[[Lesson 26#Past tense|table]]',
      );

      expect(text, startsWith('[table](<lingua-lesson:'));
    });

    test('escapes brackets in the label', () {
      final text = LessonLink.prepareWikiLinks('[[Lesson 26|see \\ ]]');

      expect(text, startsWith(r'[see \\](<'));
    });

    test('leaves code and empty links alone', () {
      const markdown =
          '`[[Lesson 26]]` and ``a [[b]]``\n\n```\n[[Lesson 26]]\n```\n\n'
          '[[ ]] [[#]]';

      expect(LessonLink.prepareWikiLinks(markdown), markdown);
    });
  });

  group('LessonLink.fromHref', () {
    test('reads #anchor links, decoding them', () {
      expect(LessonLink.fromHref('#Past%20tense')!.heading, 'Past tense');
      expect(LessonLink.fromHref('#')?.heading, isNull);
    });

    test('ignores other links', () {
      expect(LessonLink.fromHref('https://example.com'), isNull);
      expect(LessonLink.fromHref('lingua-lesson:?'), isNull);
    });

    test('reads back what href writes', () {
      const link = LessonLink(lesson: 'A::B & C', heading: '1 + 1 = 2?');
      final read = LessonLink.fromHref(link.href)!;

      expect(read.lesson, link.lesson);
      expect(read.heading, link.heading);
    });
  });

  group('LessonLink.headingMatches', () {
    test('matches by text or by anchor, ignoring case and punctuation', () {
      expect(LessonLink.headingMatches('Hello, World!', 'hello world'), isTrue);
      expect(LessonLink.headingMatches('Hello, World!', 'hello-world'), isTrue);
      expect(LessonLink.headingMatches('두 번째', '두 번째'), isTrue);
      expect(LessonLink.headingMatches('Hello', 'Help'), isFalse);
      expect(LessonLink.headingMatches('Hello', '!!'), isFalse);
    });
  });

  group('LessonLink.resolveLesson', () {
    final unit1 = Lesson(title: 'Lesson 26', unitTitle: 'Unit 1');
    final unit2 = Lesson(title: 'Lesson 26', unitTitle: 'Unit 2');
    final other = Lesson(title: 'Other', unitTitle: 'Unit 2');
    final top = Lesson(title: 'Greetings');
    final lessons = [unit1, unit2, other, top];

    test('finds a lesson by title, ignoring case', () {
      expect(LessonLink.resolveLesson(lessons, 'greetings'), same(top));
      expect(LessonLink.resolveLesson(lessons, 'Missing'), isNull);
      expect(LessonLink.resolveLesson(lessons, ' :: '), isNull);
    });

    test('tells lessons with the same title apart by folder', () {
      expect(
        LessonLink.resolveLesson(lessons, 'Unit 2::Lesson 26'),
        same(unit2),
      );
      expect(
        LessonLink.resolveLesson(lessons, 'unit 1 :: lesson 26'),
        same(unit1),
      );
    });

    test('prefers the lesson nearest to the one with the link', () {
      expect(
        LessonLink.resolveLesson(lessons, 'Lesson 26', from: other),
        same(unit2),
      );
      expect(LessonLink.resolveLesson(lessons, 'Lesson 26'), same(unit1));
    });
  });

  group('.md links', () {
    test('reads a relative .md link and its heading', () {
      final link = LessonLink.fromHref(
        '../unit-2/lesson%2026.md?x=1#Past%20tense',
      )!;

      expect(link.file, '../unit-2/lesson 26.md');
      expect(link.heading, 'Past tense');
      expect(link.isOtherLesson, isTrue);
    });

    test('leaves web links and other files alone', () {
      expect(LessonLink.fromHref('https://example.com/a.md'), isNull);
      expect(LessonLink.fromHref('mailto:a.md'), isNull);
      expect(LessonLink.fromHref('notes.txt'), isNull);
    });

    final unit2 = Lesson(
      title: 'Lesson 26',
      unitTitle: 'Unit 2',
      fileName: 'lesson-26.md',
    );
    final unit1 = Lesson(
      title: 'Lesson 26',
      unitTitle: 'Unit 1',
      fileName: 'lesson-26.md',
    );
    final three = Lesson(title: 'Lesson 3', unitTitle: 'Unit 1');
    final intro = Lesson(title: 'Intro');
    final lessons = [unit1, unit2, three, intro];

    test('finds the lesson at a relative virtual path', () {
      expect(
        LessonLink.resolveFile(lessons, '../unit-2/lesson-26.md', from: three),
        same(unit2),
      );
      expect(
        LessonLink.resolveFile(lessons, 'lesson-26.md', from: three),
        same(unit1),
      );
      expect(
        LessonLink.resolveFile(lessons, '../intro.md', from: unit2),
        same(intro),
      );
    });

    test('starts at the top folder for a leading /', () {
      expect(
        LessonLink.resolveFile(lessons, '/Unit_2/Lesson 26.md', from: intro),
        same(unit2),
      );
    });

    test('matches a lesson made in the app by its title', () {
      expect(
        LessonLink.resolveFile(lessons, './lesson-3.md', from: unit1),
        same(three),
      );
    });

    test('falls back to the nearest lesson with that name', () {
      expect(
        LessonLink.resolveFile(lessons, 'lesson-3.md', from: unit2),
        same(three),
      );
      expect(
        LessonLink.resolveFile(lessons, 'missing.md', from: intro),
        isNull,
      );
    });
  });

  group('virtual file names', () {
    test('folder import keeps the Markdown file name', () {
      final parsed = YamlParserService.parseLessonYaml(
        '---\nvocabulary:\n---\n# Lesson 26 {#l26}\n',
        sourcePath: 'unit-2/lesson-26.md',
      );

      expect(parsed.lesson.fileName, 'lesson-26.md');
      expect(parsed.lesson.title, 'Lesson 26');
      expect(parsed.lesson.virtualPath, ['lesson-26.md']);
    });

    test('other files and typed lessons fall back to the title', () {
      final parsed = YamlParserService.parseLessonYaml(
        'title: Greetings\nvocabulary:\n  nouns:\n    - ko: 단어\n      en: word\n',
        sourcePath: 'greetings.yaml',
      );

      expect(parsed.lesson.fileName, isNull);
      expect(parsed.lesson.virtualFileName, 'Greetings.md');
    });

    test('is saved and exported', () {
      final lesson = Lesson(
        title: 'Lesson 26',
        unitTitle: 'Unit 2',
        fileName: 'lesson-26.md',
      );

      expect(Lesson.fromJson(lesson.toJson()).fileName, 'lesson-26.md');
      expect(Lesson.fromJson(Lesson(title: 'A').toJson()).fileName, isNull);
      final zip = ZipDecoder().decodeBytes(
        LessonExportService.createZip([lesson], const []),
      );
      expect(zip.files.single.name, 'Unit 2/lesson-26.md');
    });
  });

  group('LessonLink.splitHeadingAttributes', () {
    test('splits off markdown-it-attrs and returns the id', () {
      expect(
        LessonLink.splitHeadingAttributes('Polite {#past-polite .note k=v}'),
        ('Polite', 'past-polite'),
      );
      expect(LessonLink.splitHeadingAttributes('Polite {.note}'), (
        'Polite',
        null,
      ));
    });

    test('keeps braces that are not attributes', () {
      expect(LessonLink.splitHeadingAttributes('Set {a b}'), (
        'Set {a b}',
        null,
      ));
      expect(LessonLink.splitHeadingAttributes('x {#a} y'), ('x {#a} y', null));
    });
  });

  group('virtual path text and copied links', () {
    test('names a path from the top folder, safe as file names', () {
      expect(
        LessonLink.virtualPathText(
          Lesson(title: 'Lesson 26', unitTitle: 'Unit 2', fileName: 'l26.md'),
        ),
        '/Unit 2/l26.md',
      );
      expect(
        LessonLink.virtualPathText(Lesson(title: 'Lesson / 1')),
        '/Lesson _ 1.md',
      );
    });

    test('a copied link finds its lesson again', () {
      final odd = Lesson(title: 'Q&A #1? 100%', unitTitle: 'Unit 2::Sub/part');
      final plain = Lesson(title: 'Lesson / 1');
      final lessons = [odd, plain];

      for (final lesson in lessons) {
        final markdown = LessonLink.markdownLinkTo(lesson);
        expect(markdown, startsWith('[${lesson.displayTitle}](<'));
        final href = RegExp(r'\(<(.*)>\)$')
            .firstMatch(markdown)![1]!
            .replaceAll(' ', '%20');
        final link = LessonLink.fromHref(href)!;
        expect(
          LessonLink.resolveFile(lessons, link.file!, from: plain),
          same(lesson),
        );
      }
    });
  });
}
