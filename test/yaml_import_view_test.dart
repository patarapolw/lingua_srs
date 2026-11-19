import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:lingua_srs/services/yaml_parser_service.dart';
import 'package:lingua_srs/views/yaml_import_view.dart';
import 'package:lingua_srs/widgets/markdown_text_field.dart';

void main() {
  testWidgets('offers separate file and folder import actions', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const MaterialApp(home: YamlImportView()));
    await tester.pumpAndSettle();

    expect(find.text('Files'), findsOneWidget);
    expect(find.text('Folder'), findsOneWidget);
    expect(find.byType(DropTarget), findsOneWidget);
    expect(find.textContaining('.md, .yaml, .yml, or .zip'), findsOneWidget);
    expect(find.textContaining('plain YAML both work'), findsOneWidget);
    expect(find.text('Pick File'), findsNothing);
    expect(find.text('Pick ZIP'), findsNothing);
  });

  testWidgets('hides folder import where there are no desktop folders', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() {
      YamlImportView.debugSupportsFolderImport = null;
      tester.binding.setSurfaceSize(null);
    });
    YamlImportView.debugSupportsFolderImport = false;

    await tester.pumpWidget(const MaterialApp(home: YamlImportView()));
    await tester.pumpAndSettle();

    expect(find.text('Files'), findsOneWidget);
    expect(find.text('Folder'), findsNothing);
    expect(find.byIcon(Icons.folder_open_outlined), findsNothing);
  });

  testWidgets('starts with empty Markdown input and import disabled', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const MaterialApp(home: YamlImportView()));
    await tester.pumpAndSettle();

    expect(find.text('e.g. Unit 2::Lesson 1'), findsOneWidget);
    expect(tester.widgetList<TextField>(find.byType(TextField)).length, 2);
    final markdownInput = tester
        .widgetList<TextField>(find.byType(TextField))
        .last;
    expect(markdownInput.maxLines, isNull);
    expect(markdownInput.expands, isTrue);
    expect(markdownInput.style?.fontFamily, 'monospace');
    expect(markdownInput.controller?.text, isEmpty);
    // The placeholder is a lesson in Markdown, with no YAML: a title, text
    // and a ## Vocabulary list the words are read from.
    final hint = markdownInput.decoration!.hintText!;
    expect(hint, startsWith('# Lesson 1\n'));
    expect(hint, isNot(contains('---')));
    // Easy to type: a hyphen, not an em dash.
    expect(hint, isNot(contains('—')));
    expect(find.text('Markdown'), findsOneWidget);
    // The Files tab's drop hint mentions YAML frontmatter too: find the
    // editor's own line.
    expect(
      find.textContaining('List words under a ## Vocabulary heading'),
      findsOneWidget,
    );
    expect(
      find.textContaining('YAML frontmatter with vocabulary:, or plain YAML'),
      findsOneWidget,
    );
    // Pasted HTML is converted, as in the lesson editor.
    expect(find.byType(MarkdownTextField), findsOneWidget);
    final parsedHint = YamlParserService.parseLessonYaml(hint);
    expect(parsedHint.wordsFromSection, isTrue);
    expect(parsedHint.lesson.title, 'Lesson 1');
    expect(parsedHint.lesson.targetLanguage, 'ko');
    expect(
      parsedHint.lesson.vocabularies.map((v) => '${v.pos}|${v.targetWord}'),
      ['nouns|학교', 'nouns|학생', 'verbs|가다'],
    );
    final school = parsedHint.lesson.vocabularies.first;
    expect(school.notes, 'Optional notes about the word.');
    expect(parsedHint.lesson.vocabularies[1].hanja, '學生');
    expect(parsedHint.sentences, hasLength(2));
    expect(
      parsedHint.sentences.first.notes,
      'Optional notes about the sentence.',
    );
    expect(find.text('Enter Markdown to see preview'), findsOneWidget);

    final importButton = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('Import Markdown'),
        matching: find.byType(FilledButton),
      ),
    );
    expect(importButton.onPressed, isNull);
  });

  testWidgets('parses Markdown frontmatter in the text editor', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const MaterialApp(home: YamlImportView()));
    await tester.enterText(find.byType(TextField).last, '''
---
vocabulary:
  nouns:
    - ko: 배
      en: pear
---
# Lesson 7: Markdown import

The full lesson body.
''');
    await tester.pump(const Duration(milliseconds: 301));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    await tester.pump();
    // The parse lands in a microtask after that frame: build it.
    await tester.pump();

    expect(
      find.text('Import Markdown'),
      findsOneWidget,
      reason: tester
          .widgetList<Text>(find.byType(Text))
          .map((text) => text.data)
          .join('\n'),
    );
    expect(find.text('Lesson 7: Markdown import'), findsOneWidget);
  });

  testWidgets('keeps the preview while typing and parses once it pauses', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    Future<void> waitForParse() async {
      await tester.pump(const Duration(milliseconds: 301));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 500)),
      );
      await tester.pump();
      // The parse lands in a microtask after that frame: build it.
      await tester.pump();
    }

    FilledButton importButton() => tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('Import Markdown'),
        matching: find.byType(FilledButton),
      ),
    );

    await tester.pumpWidget(const MaterialApp(home: YamlImportView()));
    const lesson =
        '---\nvocabulary:\n  nouns:\n    - ko: 배\n      en: pear\n---\n';
    await tester.enterText(find.byType(TextField).last, '$lesson# Lesson A\n');
    await waitForParse();
    expect(find.text('Lesson A'), findsOneWidget);
    expect(importButton().onPressed, isNotNull);

    // Typing: no progress bar and no cleared preview on each key, but no
    // importing the old parse either.
    await tester.enterText(find.byType(TextField).last, '$lesson# Lesson AB\n');
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Lesson A'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text('Parsing lesson...'), findsNothing);
    expect(importButton().onPressed, isNull);

    await waitForParse();
    expect(find.text('Lesson AB'), findsOneWidget);
    expect(importButton().onPressed, isNotNull);
  });

  testWidgets('offers to add a vocabulary to Markdown with no words', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    Future<void> waitForParse() async {
      await tester.pump(const Duration(milliseconds: 301));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 500)),
      );
      await tester.pump();
      // The parse lands in a microtask after that frame: build it.
      await tester.pump();
    }

    await tester.pumpWidget(const MaterialApp(home: YamlImportView()));
    // As pasted from a web page: a rule that YAML reads as a new document.
    await tester.enterText(
      find.byType(TextField).last,
      '# 인사\n\nHello is **안녕하세요**.\n\n---\n\nMore text.\n',
    );
    await waitForParse();

    expect(find.textContaining('Parse Error'), findsNothing);
    expect(find.textContaining('no words to study yet'), findsOneWidget);
    // No AI key here: only the button that needs none.
    expect(find.text('Generate vocabulary list with AI'), findsNothing);

    await tester.tap(find.text('Continue without words'));
    await waitForParse();

    final text = tester
        .widgetList<TextField>(find.byType(TextField))
        .last
        .controller!
        .text;
    expect(text, startsWith('---\ntarget: ko\nvocabulary:\n---\n'));
    expect(find.textContaining('no words to study yet'), findsNothing);
    expect(find.text('인사'), findsWidgets);
  });

  testWidgets('warns that ## Vocabularies is not a Vocabulary section', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const MaterialApp(home: YamlImportView()));
    await tester.enterText(
      find.byType(TextField).last,
      '---\nvocabulary:\n---\n# Lesson\n\n## Vocabularies\n\n- 학교 - school\n',
    );
    await tester.pump(const Duration(milliseconds: 301));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    await tester.pump();
    // The parse lands in a microtask after that frame: build it.
    await tester.pump();

    expect(
      find.textContaining('The heading "## Vocabularies" is read as lesson'),
      findsOneWidget,
    );
  });

  testWidgets('warns of a ## Vocabulary section and moves its words', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    Future<void> waitForParse() async {
      await tester.pump(const Duration(milliseconds: 301));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 500)),
      );
      await tester.pump();
      // The parse lands in a microtask after that frame: build it.
      await tester.pump();
    }

    await tester.pumpWidget(const MaterialApp(home: YamlImportView()));
    await tester.enterText(find.byType(TextField).last, '''
---
vocabulary:
---
# Lesson 8

## Vocabulary

- 학교 — school
''');
    await waitForParse();

    expect(
      find.textContaining('## Vocabulary section will be removed'),
      findsOneWidget,
    );
    expect(
      find.textContaining('1 word in it is not in the frontmatter'),
      findsOneWidget,
    );
    expect(find.text('Move with AI'), findsNothing);

    await tester.tap(find.text('Move words to frontmatter'));
    await waitForParse();

    final text = tester
        .widgetList<TextField>(find.byType(TextField))
        .last
        .controller!
        .text;
    expect(text, contains('- ko: 학교'));
    expect(text, isNot(contains('## Vocabulary')));
    expect(
      find.textContaining('## Vocabulary section will be removed'),
      findsNothing,
    );
  });

  testWidgets('prefills the lesson name and YAML when adding to a lesson', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      const MaterialApp(
        home: YamlImportView(
          initialLessonName: 'Unit 2::Lesson 1',
          initialYaml:
              'vocabulary:\n  nouns:\n    - ko: "새"\n      en: "new"\n',
        ),
      ),
    );
    await tester.pumpAndSettle();

    final fields = tester
        .widgetList<TextField>(find.byType(TextField))
        .map((field) => field.controller?.text)
        .toList();
    expect(fields, contains('Unit 2::Lesson 1'));
    expect(
      fields.any((text) => text?.contains('vocabulary:') ?? false),
      isTrue,
    );
  });

  testWidgets('previews prefilled YAML on open when asked to', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      const MaterialApp(
        home: YamlImportView(
          initialLessonName: 'Lesson 1',
          initialYaml:
              'vocabulary:\n  nouns:\n    - ko: "배"\n      en: "pear"\n',
          previewInitialYaml: true,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 301));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    await tester.pump();
    // The parse lands in a microtask after that frame: build it.
    await tester.pump();

    final importButton = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('Import Markdown'),
        matching: find.byType(FilledButton),
      ),
    );
    expect(importButton.onPressed, isNotNull);
    expect(
      find.descendant(of: find.byType(ListTile), matching: find.text('pear')),
      findsOneWidget,
    );
  });

  testWidgets('vocabulary only: no Markdown, files or other lesson', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      const MaterialApp(
        home: YamlImportView(
          initialLessonName: 'Lesson 1',
          vocabularyOnly: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Add Vocabulary'), findsWidgets);
    expect(find.text('Files'), findsNothing);
    expect(find.text('Folder'), findsNothing);
    expect(find.byType(DropTarget), findsOneWidget);
    expect(tester.widget<DropTarget>(find.byType(DropTarget)).enable, isFalse);
    final nameField = tester.widget<TextField>(find.byType(TextField).first);
    expect(nameField.readOnly, isTrue);

    Future<void> enter(String text) async {
      await tester.enterText(find.byType(TextField).last, text);
      await tester.pump(const Duration(milliseconds: 301));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 500)),
      );
      await tester.pump();
      // The parse lands in a microtask after that frame: build it.
      await tester.pump();
    }

    FilledButton addButton() => tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('Add Vocabulary').last,
        matching: find.byType(FilledButton),
      ),
    );

    const yaml = 'vocabulary:\n  nouns:\n    - ko: 배\n      en: pear\n';
    await enter('---\n$yaml---\n# New lesson text\n');
    expect(find.textContaining('Markdown'), findsWidgets);
    expect(
      find.textContaining('it would replace the lesson\'s text'),
      findsOneWidget,
    );
    expect(addButton().onPressed, isNull);

    await enter(yaml);
    expect(addButton().onPressed, isNotNull);
  });

  testWidgets('explains that an existing lesson name adds to that lesson', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const MaterialApp(home: YamlImportView()));
    await tester.pumpAndSettle();

    expect(find.textContaining('existing lesson'), findsOneWidget);
  });

  testWidgets('does not force the editor line height (CJK clipping)', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const MaterialApp(home: YamlImportView()));
    await tester.pumpAndSettle();

    final markdownInput = tester
        .widgetList<TextField>(find.byType(TextField))
        .last;
    expect(markdownInput.strutStyle?.forceStrutHeight, isNot(true));
  });

  testWidgets('keeps desktop YAML content not overlapping top border', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      const MaterialApp(
        home: YamlImportView(initialYaml: 'target: zh-TW\nvocabulary:\n'),
      ),
    );
    await tester.pumpAndSettle();

    final border = find
        .byWidgetPredicate(
          (widget) =>
              widget is InputDecorator &&
              widget.decoration.border is OutlineInputBorder,
        )
        .last;
    final fieldTop = tester.getTopLeft(border).dy;
    final editable = tester
        .state<EditableTextState>(find.byType(EditableText).last)
        .renderEditable;
    final caretTop = editable
        .localToGlobal(
          editable.getLocalRectForCaret(const TextPosition(offset: 0)).topLeft,
        )
        .dy;
    expect(caretTop, greaterThanOrEqualTo(fieldTop));
  });
}
