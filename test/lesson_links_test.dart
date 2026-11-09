import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/lesson.dart';
import 'package:lingua_srs/services/lesson_links.dart';

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
}
