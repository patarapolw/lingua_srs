// Runs in a browser: `flutter test --platform chrome test/web_smoke_test.dart`.
// The VM run of `flutter test` skips it. It catches code that only fails on
// the web, such as `Platform` checks, which throw there (#277).
@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/providers/app_provider.dart';
import 'package:lingua_srs/services/web_demo.dart';
import 'package:lingua_srs/views/settings_dialog.dart';
import 'package:lingua_srs/views/yaml_import_view.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<AppProvider> loadedProvider(WidgetTester tester) async {
    // Browser tests serve no assets, so the sample lessons are left out;
    // test/web_demo_test.dart covers them.
    SharedPreferences.setMockInitialValues({'web_demo_seeded': true});
    final provider = AppProvider();
    for (var i = 0; i < 200 && provider.isLoading; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(provider.isLoading, isFalse, reason: 'provider never loaded');
    return provider;
  }

  Future<void> show(WidgetTester tester, AppProvider provider, Widget page) =>
      tester.pumpWidget(
        ChangeNotifierProvider<AppProvider>.value(
          value: provider,
          child: MaterialApp(home: page),
        ),
      );

  testWidgets('the app loads as the demo', (tester) async {
    expect(WebDemo.enabled, isTrue);
    final provider = await loadedProvider(tester);
    expect(provider.showAi, isFalse);
    expect(provider.syncPairing, isNull);
  });

  testWidgets('Add Lessons opens', (tester) async {
    final provider = await loadedProvider(tester);
    await show(tester, provider, const YamlImportView());
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('Files'), findsOneWidget);
  });

  testWidgets('Settings opens', (tester) async {
    final provider = await loadedProvider(tester);
    await show(tester, provider, const Scaffold(body: SettingsDialog()));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('Web demo'), findsOneWidget);
  });
}
