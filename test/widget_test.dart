import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/main.dart';
import 'package:lingua_srs/providers/app_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('App renders LinguaSRS scaffold', (WidgetTester tester) async {
    // The debug seed lesson has Markdown content, which is stored on disk.
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
    // The seed has 5 due cards, so tomorrow's count is hidden.
    expect(find.textContaining('5 cards due today'), findsOneWidget);
    expect(find.textContaining('due tomorrow'), findsNothing);
    expect(find.textContaining('in 24h'), findsNothing);
    expect(find.textContaining('24h Limit'), findsNothing);

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Max reviews per 24 hours'), findsOneWidget);
    expect(find.text('DeepSeek API key'), findsOneWidget);
  });
}
