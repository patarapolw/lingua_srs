import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/main.dart';
import 'package:lingua_srs/providers/app_provider.dart';
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
