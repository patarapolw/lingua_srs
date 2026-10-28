import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/widgets/folder_picker_dialog.dart';

Future<void> _openPicker(
  WidgetTester tester,
  void Function(List<String>?) onResult, {
  List<List<String>> folderPaths = const [],
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async => onResult(
              await showFolderPickerDialog(
                context,
                title: 'Move lesson',
                folderPaths: folderPaths,
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('choosing an existing folder returns its path', (tester) async {
    List<String>? result;
    await _openPicker(
      tester,
      (value) => result = value,
      folderPaths: [
        ['Unit 1'],
        ['Unit 1', 'Grammar'],
      ],
    );

    await tester.tap(find.text('Unit 1 › Grammar'));
    await tester.pumpAndSettle();
    expect(result, ['Unit 1', 'Grammar']);
  });

  testWidgets('root still returns an empty path', (tester) async {
    List<String>? result;
    await _openPicker(tester, (value) => result = value);

    await tester.tap(find.text('Root (no folder)'));
    await tester.pumpAndSettle();
    expect(result, isEmpty);
  });

  testWidgets('New folder... returns a path that does not exist yet', (
    tester,
  ) async {
    List<String>? result;
    await _openPicker(
      tester,
      (value) => result = value,
      folderPaths: [
        ['Unit 1'],
      ],
    );

    await tester.tap(find.byKey(const ValueKey('new-folder-tile')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('new-folder-field')),
      ' Unit 3 :: Grammar ',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('new-folder-create')));
    await tester.pumpAndSettle();

    expect(result, ['Unit 3', 'Grammar']);
  });

  testWidgets('Create is disabled while the name is blank', (tester) async {
    List<String>? result = ['sentinel'];
    await _openPicker(tester, (value) => result = value);

    await tester.tap(find.byKey(const ValueKey('new-folder-tile')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('new-folder-field')),
      ' :: ',
    );
    await tester.pump();

    final create = tester.widget<FilledButton>(
      find.byKey(const ValueKey('new-folder-create')),
    );
    expect(create.onPressed, isNull);
    expect(result, ['sentinel']);
  });

  testWidgets('cancel returns null', (tester) async {
    List<String>? result = ['sentinel'];
    await _openPicker(tester, (value) => result = value);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(result, isNull);
  });
}
