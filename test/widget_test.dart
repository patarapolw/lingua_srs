import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/main.dart';
import 'package:lingua_srs/models/vocab_item.dart';
import 'package:lingua_srs/models/vocab_merge_record.dart';
import 'package:lingua_srs/providers/app_provider.dart';
import 'package:lingua_srs/views/vocab_edit_dialog.dart';
import 'package:lingua_srs/views/vocab_merge_dialogs.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory storageDirectory;

  setUp(() {
    storageDirectory = Directory.systemTemp.createTempSync('lingua_srs_widget_test_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (call) async {
          if (call.method == 'getApplicationSupportDirectory') {
            return storageDirectory.path;
          }
          throw MissingPluginException('Unexpected method: ${call.method}');
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    if (storageDirectory.existsSync()) {
      await storageDirectory.delete(recursive: true);
    }
  });

  /// Pumps the app and waits until the provider has really finished loading.
  Future<AppProvider> pumpApp(
    WidgetTester tester, [
    Map<String, Object> prefs = const {},
  ]) async {
    SharedPreferences.setMockInitialValues({
      'lingua_srs_windows_legacy_migration_complete': true,
      ...prefs,
    });
    final provider = AppProvider();
    await tester.pumpWidget(
      ChangeNotifierProvider(create: (_) => provider, child: const LinguaSrsApp()),
    );
    // File I/O completes on the real event loop; init() also waits on a fake
    // Future.delayed(Duration.zero), so both clocks have to advance.
    for (var i = 0; i < 100 && provider.isLoading; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(provider.isLoading, isFalse, reason: 'provider never finished loading');
    await tester.pumpAndSettle();
    return provider;
  }

  VocabGroup vg(String id, String ko, String en, {int reviews = 0}) => VocabGroup(
        id: id,
        entry: VocabItem(id: id, targetWord: ko, translation: en, pos: 'adjectives'),
        reviews: reviews,
      )..lessonTitles.add('L');

  Future<void> openDialog(WidgetTester tester, Widget Function() dialog,
      void Function(Object?) onResult) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async =>
              onResult(await showDialog<Object>(context: context, builder: (_) => dialog())),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('Merge confirmation is disabled until acknowledged; most reviewed survives by default',
      (tester) async {
    Object? result;
    await openDialog(
      tester,
      () => ConfirmMergeDialog(
        a: vg('a', '아름답다', 'beautiful', reviews: 1),
        b: vg('b', '아름답다', 'to be beautiful', reviews: 5),
      ),
      (r) => result = r,
    );
    final merge = find.widgetWithText(FilledButton, 'Merge');
    expect(tester.widget<FilledButton>(merge).onPressed, isNull);
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    expect(tester.widget<FilledButton>(merge).onPressed, isNotNull);
    await tester.tap(merge);
    await tester.pumpAndSettle();
    expect(result, 'b');
  });

  testWidgets('Merge confirmation lets you keep the other one, and Cancel returns null',
      (tester) async {
    Object? result = 'unset';
    await openDialog(
      tester,
      () => ConfirmMergeDialog(
        a: vg('a', '아름답다', 'beautiful', reviews: 1),
        b: vg('b', '아름답다', 'to be beautiful', reviews: 5),
      ),
      (r) => result = r,
    );
    await tester.tap(find.text('Keep progress of 아름답다 — beautiful'));
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Merge'));
    await tester.pumpAndSettle();
    expect(result, 'a');

    result = 'unset';
    await openDialog(
      tester,
      () => ConfirmMergeDialog(a: vg('a', '가', 'x'), b: vg('b', '나', 'y')),
      (r) => result = r,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(result, isNull);
  });

  testWidgets('Merge picker lists same-spelling words first and filters by search', (tester) async {
    Object? result;
    final current = vg('c', '크다', 'big');
    await openDialog(
      tester,
      () => MergePickerDialog(current: current, groups: [
        current,
        vg('z', '작다', 'small'),
        vg('s', '크다', 'to be big'),
        vg('t', '큰', 'large'),
      ]),
      (r) => result = r,
    );
    final titles = tester.widgetList<ListTile>(find.byType(ListTile))
        .map((t) => (t.title as Text).data).toList();
    expect(titles, ['크다 — to be big', '작다 — small', '큰 — large']);

    await tester.enterText(find.byType(TextField), 'small');
    await tester.pump();
    expect(find.byType(ListTile), findsOneWidget);
    await tester.tap(find.byType(ListTile));
    await tester.pumpAndSettle();
    expect((result as VocabGroup).id, 'z');
  });

  testWidgets('Edit dialog has both hint fields; AI buttons only with a DeepSeek key',
      (tester) async {
    Future<void> open(Map<String, Object> prefs) async {
      await pumpApp(tester, prefs);
      unawaited(VocabEditDialog.show(
        tester.element(find.byType(Scaffold).first),
        VocabItem(targetWord: '배', translation: 'pear', pos: 'nouns'),
      ));
      await tester.pumpAndSettle();
    }

    await open({});
    expect(find.text('KO ➔ EN front hint', skipOffstage: false), findsOneWidget);
    expect(find.text('EN ➔ KO front hint', skipOffstage: false), findsOneWidget);
    expect(find.byIcon(Icons.auto_awesome, skipOffstage: false), findsNothing);
  });

  testWidgets('Edit dialog shows one AI button per direction with a key', (tester) async {
    await pumpApp(tester, {'lingua_srs_deepseek_api_key': 'test-key'});
    unawaited(VocabEditDialog.show(
      tester.element(find.byType(Scaffold).first),
      VocabItem(targetWord: '배', translation: 'pear', pos: 'nouns'),
    ));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.auto_awesome, skipOffstage: false), findsNWidgets(2));
  });

  testWidgets('App renders LinguaSRS scaffold', (tester) async {
    await pumpApp(tester);
    expect(find.text('LinguaSRS'), findsWidgets);
    expect(find.textContaining('24h Limit'), findsNothing);

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Max reviews per 24 hours'), findsOneWidget);
    expect(find.text('DeepSeek API key'), findsOneWidget);
  });

  testWidgets('Merge menu is hidden without a DeepSeek key or history', (tester) async {
    await pumpApp(tester);
    expect(find.byTooltip('Vocabulary merging'), findsNothing);
  });

  testWidgets('Merge menu offers AI only with a DeepSeek key', (tester) async {
    await pumpApp(tester, {
      'lingua_srs_deepseek_api_key': 'test-key',
    });
    await tester.tap(find.byTooltip('Vocabulary merging'));
    await tester.pumpAndSettle();
    expect(find.text('Suggest merges with AI'), findsOneWidget);
  });
}
