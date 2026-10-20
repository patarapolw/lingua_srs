import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/main.dart';
import 'package:lingua_srs/providers/app_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final markdownStorageDirectory = Directory.systemTemp.createTempSync(
    'lingua_srs_markdown_test_',
  );
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(pathProviderChannel, (call) async {
        if (call.method == 'getApplicationSupportDirectory') {
          return markdownStorageDirectory.path;
        }
        throw MissingPluginException('Unexpected method: ${call.method}');
      });
  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    await markdownStorageDirectory.delete(recursive: true);
  });

  Future<void> pumpApp(
    WidgetTester tester,
    Map<String, Object> prefs,
  ) async {
    SharedPreferences.setMockInitialValues(prefs);

    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => AppProvider(),
        child: const LinguaSrsApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('App renders LinguaSRS scaffold', (WidgetTester tester) async {
    final storageDirectory = Directory.systemTemp.createTempSync(
      'lingua_srs_widget_test_',
    );
    const pathProviderChannel = MethodChannel(
      'plugins.flutter.io/path_provider',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (call) async {
          if (call.method == 'getApplicationSupportDirectory') {
            return storageDirectory.path;
          }
          throw MissingPluginException('Unexpected method: ${call.method}');
        });
    addTearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProviderChannel, null);
      await storageDirectory.delete(recursive: true);
    });

    SharedPreferences.setMockInitialValues({
      'lingua_srs_windows_legacy_migration_complete': true,
    });

    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => AppProvider(),
        child: const LinguaSrsApp(),
      ),
    );
    // File I/O completes on the real event loop, not in fake async.
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();
    expect(find.text('LinguaSRS'), findsWidgets);
    expect(find.textContaining('24h Limit'), findsNothing);

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Max reviews per 24 hours'), findsOneWidget);
    expect(find.text('DeepSeek API key'), findsOneWidget);
  });

  testWidgets('Merge menu is hidden without a DeepSeek key or history', (tester) async {
    await pumpApp(tester, {'lingua_srs_windows_legacy_migration_complete': true});
    expect(find.byTooltip('Vocabulary merging'), findsNothing);
  });

  testWidgets('Merge menu offers AI only with a DeepSeek key', (tester) async {
    await pumpApp(tester, {
      'lingua_srs_windows_legacy_migration_complete': true,
      'lingua_srs_deepseek_api_key': 'test-key',
    });
    await tester.tap(find.byTooltip('Vocabulary merging'));
    await tester.pumpAndSettle();
    expect(find.text('Suggest merges with AI'), findsOneWidget);
  });
}
