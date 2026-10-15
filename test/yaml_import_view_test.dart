import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/services/yaml_parser_service.dart';
import 'package:lingua_srs/views/yaml_import_view.dart';

void main() {
  testWidgets('starts with empty YAML input and import disabled', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const MaterialApp(home: YamlImportView()));
    await tester.pumpAndSettle();

    expect(find.text('e.g. Unit 2 / Lesson 26'), findsOneWidget);
    expect(tester.widgetList<TextField>(find.byType(TextField)).length, 2);
    final yamlInput = tester.widgetList<TextField>(find.byType(TextField)).last;
    expect(yamlInput.maxLines, isNull);
    expect(yamlInput.expands, isTrue);
    expect(yamlInput.style?.fontFamily, 'monospace');
    expect(
      yamlInput.decoration!.hintText,
      contains('Replace with a part of speech or section name'),
    );
    expect(yamlInput.decoration!.hintText, contains('sentence-audio.mp3'));
    final parsedHint = YamlParserService.parseLessonYaml(
      yamlInput.decoration!.hintText!,
    );
    expect(parsedHint.lesson.vocabularies, hasLength(1));
    expect(parsedHint.sentences, hasLength(2));
    expect(
      parsedHint.sentences.last.audioUrl,
      'https://example.com/sentence-audio.mp3',
    );
    expect(find.text('Enter YAML to see preview'), findsOneWidget);

    final importButton = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('Import YAML'),
        matching: find.byType(FilledButton),
      ),
    );
    expect(importButton.onPressed, isNull);
  });
}
