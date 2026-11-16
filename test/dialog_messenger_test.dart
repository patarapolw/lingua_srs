import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/widgets/dialog_messenger.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  /// A page with a button that opens [dialog], with the app's own messenger
  /// above it, as in the app.
  Future<void> openDialog(
    WidgetTester tester,
    Widget Function(BuildContext) dialog, {
    bool barrierDismissible = true,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                barrierDismissible: barrierDismissible,
                builder: dialog,
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

  Widget snackbarDialog(BuildContext _) => AlertDialog(
    content: Builder(
      builder: (context) => TextButton(
        onPressed: () =>
            ScaffoldMessenger.of(context)
                .showSnackBar(const SnackBar(content: Text('note'))),
        child: const Text('show'),
      ),
    ),
  );

  testWidgets('without it, a snackbar from a dialog is under the barrier', (
    tester,
  ) async {
    await openDialog(tester, snackbarDialog);

    await tester.tap(find.text('show'));
    await tester.pumpAndSettle();

    // This is the bug in #246: it is there, but the barrier covers it.
    expect(find.text('note'), findsOneWidget);
    expect(find.text('note').hitTestable(), findsNothing);
  });

  testWidgets('a snackbar from inside the dialog shows on top of it', (
    tester,
  ) async {
    await openDialog(
      tester,
      (context) => DialogMessenger(child: snackbarDialog(context)),
    );

    await tester.tap(find.text('show'));
    await tester.pumpAndSettle();

    expect(find.text('note').hitTestable(), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(DialogMessenger),
        matching: find.byType(SnackBar),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a tap outside closes it, like the barrier', (tester) async {
    await openDialog(
      tester,
      (context) => DialogMessenger(child: snackbarDialog(context)),
    );

    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    expect(find.text('show'), findsNothing);
  });

  testWidgets('a tap outside does nothing when it is not dismissible', (
    tester,
  ) async {
    await openDialog(
      tester,
      (context) =>
          DialogMessenger(dismissible: false, child: snackbarDialog(context)),
      barrierDismissible: false,
    );

    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    expect(find.text('show'), findsOneWidget);
  });

  testWidgets('a tap inside the dialog does not close it', (tester) async {
    await openDialog(
      tester,
      (context) =>
          DialogMessenger(child: const AlertDialog(content: Text('inside'))),
    );

    await tester.tap(find.text('inside'));
    await tester.pumpAndSettle();

    expect(find.text('inside'), findsOneWidget);
  });

  testWidgets('a snackbar for after the dialog closes stays on the page', (
    tester,
  ) async {
    await openDialog(
      tester,
      (_) => DialogMessenger(
        child: AlertDialog(
          content: Builder(
            builder: (context) => TextButton(
              onPressed: () {
                DialogMessenger.parentOf(context)
                    .showSnackBar(const SnackBar(content: Text('done')));
                Navigator.of(context).pop();
              },
              child: const Text('finish'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('finish'));
    await tester.pumpAndSettle();

    expect(find.text('finish'), findsNothing);
    expect(find.text('done').hitTestable(), findsOneWidget);
  });

  testWidgets('parentOf falls back to the nearest messenger', (tester) async {
    late ScaffoldMessengerState found;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              found = DialogMessenger.parentOf(context);
              return const SizedBox();
            },
          ),
        ),
      ),
    );

    expect(found, tester.state(find.byType(ScaffoldMessenger)));
  });
}
