import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/lesson.dart';
import 'package:lingua_srs/services/hangul_text.dart';
import 'package:lingua_srs/services/lesson_links.dart';

/// `한국어` as macOS can store it in a file or folder name (NFD).
const _decomposed = '한국어';

void main() {
  group('composeHangul', () {
    test('composes jamo into syllables', () {
      expect(_decomposed, isNot('한국어'));
      expect(composeHangul(_decomposed), '한국어');
      // With and without a final consonant, among other text.
      expect(composeHangul('1단원/a.md'), '1단원/a.md');
      expect(composeHangul('가 b'), '가 b');
    });

    test('leaves composed text and other text as it is', () {
      expect(composeHangul('한국어 Lesson 3'), '한국어 Lesson 3');
      expect(composeHangul('ㄱ ㄴ'), 'ㄱ ㄴ');
      // Jamo that do not make a syllable stay.
      expect(composeHangul('ᆨx'), 'ᆨx');
      expect(composeHangul('ᄀ가'), 'ᄀ가');
    });
  });

  group('lessons', () {
    test('keep names composed, however they are made', () {
      final lesson = Lesson(
        title: _decomposed,
        unitTitle: 'Unit 1::$_decomposed',
        fileName: '$_decomposed.md',
      );

      expect(lesson.title, '한국어');
      expect(lesson.unitTitle, 'Unit 1::한국어');
      expect(lesson.fileName, '한국어.md');
      final loaded = Lesson.fromJson({
        'title': _decomposed,
        'unitTitle': _decomposed,
        'fileName': '$_decomposed.md',
      });
      expect(loaded.virtualPath, ['한국어', '한국어.md']);
    });

    test('links written with jamo find them', () {
      final lesson = Lesson(title: '한국어', unitTitle: '1단원');

      expect(
        LessonLink.resolveLesson([lesson], '1단원::$_decomposed'),
        same(lesson),
      );
      expect(
        LessonLink.resolveFile([lesson], '/1단원/$_decomposed.md', from: lesson),
        same(lesson),
      );
      expect(LessonLink.headingMatches('한국어', _decomposed), isTrue);
    });
  });
}
