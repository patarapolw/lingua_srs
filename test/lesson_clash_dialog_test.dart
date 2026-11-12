import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/lesson.dart';
import 'package:lingua_srs/models/vocab_item.dart';
import 'package:lingua_srs/providers/app_provider.dart';
import 'package:lingua_srs/widgets/lesson_clash_dialog.dart';

VocabItem _word(String ko, String en) =>
    VocabItem(targetWord: ko, translation: en, pos: 'nouns');

Lesson _lesson(List<VocabItem> words, {String text = ''}) => Lesson(
  title: 'Lesson 1',
  unitTitle: 'Unit 1',
  vocabularies: words,
  markdownContent: text,
);

Future<void> _show(
  WidgetTester tester,
  LessonNameClash clash, {
  required bool importing,
}) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: LessonClashDialog(clash: clash, importing: importing),
    ),
  ),
);

String? _warning(WidgetTester tester) {
  final found = find.byKey(const ValueKey('clash-warning'));
  return found.evaluate().isEmpty ? null : tester.widget<Text>(found).data;
}

void main() {
  testWidgets('warns how many saved words an imported file leaves in place', (
    tester,
  ) async {
    final saved = _lesson([
      _word('사과', 'apple'),
      _word('배', 'pear'),
      _word('귤', 'tangerine'),
    ]);
    final file = _lesson([_word('사과', 'apple')]);
    await _show(
      tester,
      LessonNameClash(existing: saved, incoming: file, renamedTitle: 'x'),
      importing: true,
    );
    // Keep both is chosen first: nothing is overwritten.
    expect(_warning(tester), isNull);

    await tester.tap(find.text('Imported file'));
    await tester.pump();

    expect(_warning(tester), startsWith('2 words in the saved lesson are not'));
    expect(_warning(tester), contains('They are not deleted'));
    expect(_warning(tester), contains('study progress'));

    await tester.tap(find.text('Saved lesson'));
    await tester.pump();
    expect(_warning(tester), isNull);
  });

  testWidgets('says "1 word" and says nothing when the file has them all', (
    tester,
  ) async {
    final saved = _lesson([_word('사과', 'apple'), _word('배', 'pear')]);
    await _show(
      tester,
      LessonNameClash(
        existing: saved,
        incoming: _lesson([_word('사과', 'apple')]),
        renamedTitle: 'x',
      ),
      importing: true,
    );
    await tester.tap(find.text('Imported file'));
    await tester.pump();
    expect(_warning(tester), startsWith('1 word in the saved lesson is not'));

    await _show(
      tester,
      LessonNameClash(
        existing: saved,
        incoming: _lesson([_word('사과', 'apple'), _word('배', 'pear')]),
        renamedTitle: 'x',
      ),
      importing: true,
    );
    await tester.tap(find.text('Imported file'));
    await tester.pump();
    expect(_warning(tester), isNull);
  });

  testWidgets('for saved lessons, says which words move and that text goes', (
    tester,
  ) async {
    final first = _lesson([_word('사과', 'apple')], text: '# First notes');
    final second = _lesson([
      _word('사과', 'apple'),
      _word('배', 'pear'),
    ], text: '# Second notes');
    await _show(
      tester,
      LessonNameClash(existing: first, incoming: second, renamedTitle: 'x'),
      importing: false,
    );

    await tester.tap(find.text('First lesson'));
    await tester.pump();
    expect(_warning(tester), startsWith('1 word only the second lesson has'));
    expect(_warning(tester), contains('No words are deleted'));
    expect(_warning(tester), endsWith('The second lesson’s text is not kept.'));

    await tester.tap(find.text('Second lesson'));
    await tester.pump();
    // The second has every word the first has; only the text goes.
    expect(_warning(tester), 'The first lesson’s text is not kept.');
  });

  testWidgets('does not warn about text the kept lesson takes over', (
    tester,
  ) async {
    // A kept lesson without text takes the other's (see _absorbLesson).
    await _show(
      tester,
      LessonNameClash(
        existing: _lesson([_word('사과', 'apple')]),
        incoming: _lesson([_word('사과', 'apple')], text: '# Notes'),
        renamedTitle: 'x',
      ),
      importing: false,
    );
    await tester.tap(find.text('First lesson'));
    await tester.pump();

    expect(_warning(tester), isNull);
  });
}
