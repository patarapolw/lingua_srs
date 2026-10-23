import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:lingua_srs/services/yaml_parser_service.dart';
import 'package:lingua_srs/views/yaml_import_view.dart';

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

  testWidgets('starts with empty Markdown input and import disabled', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const MaterialApp(home: YamlImportView()));
    await tester.pumpAndSettle();

    expect(find.text('e.g. Unit 2::Lesson 26'), findsOneWidget);
    expect(tester.widgetList<TextField>(find.byType(TextField)).length, 2);
    final markdownInput = tester
        .widgetList<TextField>(find.byType(TextField))
        .last;
    expect(markdownInput.maxLines, isNull);
    expect(markdownInput.expands, isTrue);
    expect(markdownInput.style?.fontFamily, 'monospace');
    expect(markdownInput.controller?.text, isEmpty);
    expect(
      markdownInput.decoration!.hintText,
      contains('  nouns:  # Replace with a part of speech'),
    );
    final parsedHint = YamlParserService.parseLessonYaml(
      markdownInput.decoration!.hintText!,
    );
    expect(parsedHint.lesson.title, 'Lesson 26');
    expect(parsedHint.lesson.vocabularies, hasLength(1));
    expect(parsedHint.lesson.vocabularies.single.targetWord, 'Korean word');
    expect(parsedHint.sentences, hasLength(2));
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

  testWidgets('prefills the lesson name and YAML when adding to a lesson', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      const MaterialApp(
        home: YamlImportView(
          initialLessonName: 'Unit 2::Lesson 26',
          initialYaml: 'vocabulary:\n  nouns:\n    - ko: "새"\n      en: "new"\n',
        ),
      ),
    );
    await tester.pumpAndSettle();

    final fields = tester
        .widgetList<TextField>(find.byType(TextField))
        .map((field) => field.controller?.text)
        .toList();
    expect(fields, contains('Unit 2::Lesson 26'));
    expect(fields.any((text) => text?.contains('vocabulary:') ?? false), isTrue);
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
}
