import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/widgets/sync_scheduler.dart';

class _Host extends ChangeNotifier {
  bool signedIn = true;
  bool changed = false;
  int syncs = 0;
  int checks = 0;

  void edit() => notifyListeners();
}

Future<_Host> _pump(WidgetTester tester, {bool signedIn = true}) async {
  final host = _Host()..signedIn = signedIn;
  await tester.pumpWidget(
    SyncScheduler(
      changes: host,
      canSync: () => host.signedIn,
      hasChanges: () async {
        host.checks++;
        return host.changed;
      },
      sync: () async => host.syncs++,
      editDelay: const Duration(seconds: 20),
      child: const SizedBox(),
    ),
  );
  await tester.pump();
  return host;
}

void main() {
  testWidgets('syncs once when the app starts signed in', (tester) async {
    final host = await _pump(tester);

    expect(host.syncs, 1);
  });

  testWidgets('does nothing while signed out', (tester) async {
    final host = await _pump(tester, signedIn: false);
    host.edit();
    await tester.pump(const Duration(minutes: 1));

    expect(host.syncs, 0);
    expect(host.checks, 0);
  });

  testWidgets('syncs right away after signing in', (tester) async {
    final host = await _pump(tester, signedIn: false);

    host
      ..signedIn = true
      ..edit();
    await tester.pump();

    expect(host.syncs, 1);
  });

  testWidgets('syncs a while after the last edit, if a record changed', (
    tester,
  ) async {
    final host = await _pump(tester);
    host.changed = true;

    host.edit();
    await tester.pump(const Duration(seconds: 10));
    host.edit(); // A new edit starts the wait again.
    await tester.pump(const Duration(seconds: 15));
    expect(host.syncs, 1);

    await tester.pump(const Duration(seconds: 6));
    expect(host.checks, 1);
    expect(host.syncs, 2);
  });

  testWidgets('does not sync after edits that changed no record', (
    tester,
  ) async {
    final host = await _pump(tester);

    host.edit();
    await tester.pump(const Duration(seconds: 21));

    expect(host.checks, 1);
    expect(host.syncs, 1);
  });

  testWidgets('syncs when the app comes back to the foreground', (
    tester,
  ) async {
    final host = await _pump(tester);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();

    expect(host.syncs, 2);
  });

  testWidgets('stops waiting when the widget goes away', (tester) async {
    final host = await _pump(tester);
    host.changed = true;
    host.edit();

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));

    expect(host.checks, 0);
    expect(host.syncs, 1);
  });
}
