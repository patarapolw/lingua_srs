import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/main.dart';
import 'package:lingua_srs/providers/app_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('App renders LinguaSRS scaffold', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({
      'lingua_srs_windows_legacy_migration_complete': true,
    });

    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => AppProvider(),
        child: const LinguaSrsApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('LinguaSRS'), findsWidgets);
  });
}
