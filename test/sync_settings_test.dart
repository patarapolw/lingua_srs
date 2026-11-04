import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/providers/app_provider.dart';
import 'package:lingua_srs/services/storage_service.dart';
import 'package:lingua_srs/services/sync_account_service.dart';
import 'package:lingua_srs/services/sync_client.dart';
import 'package:lingua_srs/services/sync_pairing.dart';
import 'package:lingua_srs/views/settings_dialog.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'secret_storage_mock.dart';

const _email = 'reader@example.com';
const _password = 'TEST-ONLY-SYNC-PASSWORD';
final _server = Uri.parse('https://sync.example.com');

class _FakeSyncAccountService extends SyncAccountService {
  _FakeSyncAccountService({
    this.pairingLink,
    this.unconfirmed = false,
    this.validateError,
    this.confirmError,
    this.redeemedPairing,
  });

  final String? pairingLink;
  bool unconfirmed;
  final SyncException? validateError;
  final SyncException? confirmError;
  final SyncPairing? redeemedPairing;
  bool accountDeleted = false;
  bool credentialsValidated = false;
  String? confirmedCode;
  String? redeemedLink;

  @override
  Future<void> validateCredentials(SyncPairing pairing) async {
    final refused = validateError;
    if (refused != null) throw refused;
    if (unconfirmed) {
      throw const SyncException(
        'Sync request failed (403): {"error":"email_not_confirmed"}',
        statusCode: 403,
      );
    }
    credentialsValidated = true;
  }

  @override
  Future<void> createAccount(SyncPairing pairing) async {}

  @override
  Future<void> confirmAccount(SyncPairing pairing, String code) async {
    final refused = confirmError;
    if (refused != null) throw refused;
    confirmedCode = code;
  }

  @override
  Future<String> generatePassphrase() async =>
      'tongue glide bleak ancient chase';

  @override
  Future<String> createPairingLink(SyncPairing pairing) async =>
      pairingLink ?? 'linguasrs://pair?token=${'a' * 64}#${'b' * 43}';

  @override
  Future<SyncPairing> redeemPairingLink(String link) async {
    redeemedLink = link;
    return redeemedPairing ??
        SyncPairing(endpoint: _server, email: _email, password: _password);
  }

  @override
  Future<void> deleteAccount(SyncPairing pairing) async {
    accountDeleted = true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(setUpSecretStorage);
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory storageDirectory;
  String? copied;
  String? clipboardText;

  late SyncPairing pairing;

  setUp(() {
    SyncPairing.defaultEndpoint = _server;
    pairing = SyncPairing(email: _email, password: _password);
    copied = null;
    clipboardText = null;
    storageDirectory = Directory.systemTemp.createTempSync(
      'lingua_srs_sync_settings_test_',
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(pathProviderChannel, (call) async {
      if (call.method == 'getApplicationSupportDirectory') {
        return storageDirectory.path;
      }
      throw MissingPluginException('Unexpected method: ${call.method}');
    });
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String?;
      } else if (call.method == 'Clipboard.getData') {
        return clipboardText == null ? null : {'text': clipboardText};
      }
      return null;
    });
  });

  tearDown(() async {
    SyncPairing.defaultEndpoint = null;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(pathProviderChannel, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    if (storageDirectory.existsSync()) {
      await storageDirectory.delete(recursive: true);
    }
  });

  group('sync pairing storage', () {
    test('is unpaired by default', () async {
      SharedPreferences.setMockInitialValues({});

      expect(await StorageService.loadSyncPairing(), isNull);
    });

    test('a keychain that cannot be read counts as signed out', () async {
      SharedPreferences.setMockInitialValues({});
      StorageService.secretStorageForTesting = const BrokenSecretStorage();

      expect(await StorageService.loadSyncPairing(), isNull);
      expect(await StorageService.loadDeepSeekApiKey(), '');
    });

    test('a sign-in stays in preferences while the keychain fails', () async {
      SharedPreferences.setMockInitialValues({
        'lingua_srs_sync_pairing': pairing.link,
      });
      StorageService.secretStorageForTesting = const BrokenSecretStorage(
        failReads: false,
      );

      // It cannot be moved to the keychain yet, so it is used from where it is.
      expect(await StorageService.loadSyncPairing(), pairing);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('lingua_srs_sync_pairing'), pairing.link);

      // Once the keychain works, it is moved there and removed from preferences.
      final working = MemorySecretStorage();
      StorageService.secretStorageForTesting = working;
      expect(await StorageService.loadSyncPairing(), pairing);
      expect(prefs.getString('lingua_srs_sync_pairing'), isNull);
      expect(working.values['lingua_srs_sync_pairing'], pairing.link);
    });

    test('saves, loads and clears the pairing', () async {
      SharedPreferences.setMockInitialValues({});

      await StorageService.saveSyncPairing(pairing);
      expect(await StorageService.loadSyncPairing(), pairing);

      await StorageService.saveSyncPairing(null);
      expect(await StorageService.loadSyncPairing(), isNull);
    });

    test('an unreadable stored link counts as unpaired', () async {
      SharedPreferences.setMockInitialValues({
        'lingua_srs_syncpairing': 'garbage',
      });

      expect(await StorageService.loadSyncPairing(), isNull);
    });
  });

  group('Settings dialog sync section', () {
    Future<AppProvider> loadedProvider(
      WidgetTester tester, [
      Map<String, Object> prefs = const {},
    ]) async {
      SharedPreferences.setMockInitialValues({
        'lingua_srs_windows_legacy_migration_complete': true,
        ...prefs,
      });
      final provider = AppProvider();
      addTearDown(provider.dispose);
      for (var i = 0; i < 100 && provider.isLoading; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(provider.isLoading, isFalse, reason: 'provider never loaded');
      return provider;
    }

    Future<void> openSettings(
      WidgetTester tester,
      AppProvider provider, {
      SyncAccountService? syncAccountService,
    }) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppProvider>.value(
          value: provider,
          child: MaterialApp(
            theme: ThemeData(splashFactory: NoSplash.splashFactory),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => SettingsDialog(
                      syncAccountService:
                          syncAccountService ?? _FakeSyncAccountService(),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    final emailField = find.widgetWithText(TextField, 'Sync email');
    final passwordField = find.widgetWithText(TextField, 'Sync password');

    Future<void> tapText(WidgetTester tester, String text) async {
      final finder = find.text(text);
      await tester.ensureVisible(finder);
      await tester.tap(finder);
      await tester.pumpAndSettle();
    }

    testWidgets('DeepSeek key removal is beside its field', (tester) async {
      final provider = await loadedProvider(tester, {
        'lingua_srs_deepseek_api_key': 'existing-key',
      });
      await openSettings(tester, provider);

      final apiKeyField = find.widgetWithText(TextField, 'DeepSeek API key');
      expect(
        find.descendant(
          of: apiKeyField,
          matching: find.byTooltip('Remove API key'),
        ),
        findsOneWidget,
      );
      expect(find.text('Remove key'), findsNothing);
      await tester.ensureVisible(find.byTooltip('Remove API key'));
      await tester.tap(find.byTooltip('Remove API key'));
      await tester.pumpAndSettle();

      expect(provider.deepSeekApiKey, isEmpty);
      expect(find.byTooltip('Remove API key'), findsNothing);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('lingua_srs_deepseek_api_key'), isNull);
    });

    Future<void> typeCredentials(
      WidgetTester tester, {
      String email = _email,
      String password = _password,
    }) async {
      await tester.ensureVisible(emailField);
      await tester.enterText(emailField, email);
      await tester.enterText(passwordField, password);
    }

    testWidgets('a signed-out device can sign in with email and password', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      final service = _FakeSyncAccountService();
      await openSettings(tester, provider, syncAccountService: service);

      expect(emailField, findsOneWidget);
      expect(find.text('Copy sign-in link'), findsNothing);

      await typeCredentials(tester, email: ' Reader@Example.com ');
      expect(tester.widget<TextField>(passwordField).autofillHints, [
        AutofillHints.password,
      ]);
      await tapText(tester, 'Sign in');

      expect(service.credentialsValidated, isTrue);
      expect(provider.syncPairing, pairing);
      expect(await tester.runAsync(StorageService.loadSyncPairing), pairing);
      expect(emailField, findsNothing);
      expect(find.text('Signed in as reader@example.com'), findsOneWidget);
      expect(find.textContaining('Server '), findsNothing);
    });

    testWidgets('the password is hidden until shown', (tester) async {
      final provider = await loadedProvider(tester);
      await openSettings(tester, provider);

      expect(tester.widget<TextField>(passwordField).obscureText, isTrue);

      await tester.ensureVisible(find.byTooltip('Show password'));
      await tester.tap(find.byTooltip('Show password'));
      await tester.pump();

      expect(tester.widget<TextField>(passwordField).obscureText, isFalse);
    });

    testWidgets('a bad email or an empty password is rejected', (tester) async {
      final provider = await loadedProvider(tester);
      await openSettings(tester, provider);

      await typeCredentials(tester, email: 'not an email');
      await tapText(tester, 'Sign in');
      expect(find.text('Email is missing or invalid.'), findsOneWidget);

      await typeCredentials(tester, password: '');
      await tapText(tester, 'Sign in');
      expect(find.text('Password is missing.'), findsOneWidget);

      expect(provider.syncPairing, isNull);
      expect(await tester.runAsync(StorageService.loadSyncPairing), isNull);
    });

    testWidgets('a short password still signs in to an existing account', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      await openSettings(tester, provider);

      await typeCredentials(tester, password: 'old1');
      await tapText(tester, 'Sign in');

      expect(provider.syncPairing?.password, 'old1');
    });

    testWidgets('account creation enforces the new-password minimum', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      await openSettings(tester, provider);
      await tapText(tester, 'Create a sync account');

      await tester.enterText(emailField, _email);
      await tester.enterText(
        find.widgetWithText(TextField, 'New sync password'),
        'short',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Confirm sync password'),
        'short',
      );
      await tapText(tester, 'Create account');

      expect(find.text('Use at least 15 characters.'), findsOneWidget);
      expect(provider.syncPairing, isNull);
    });

    testWidgets('invalid password policy and confirmation are shown inline', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      await openSettings(tester, provider);
      await tapText(tester, 'Create a sync account');
      await tester.enterText(emailField, _email);
      await tester.enterText(
        find.widgetWithText(TextField, 'New sync password'),
        'short',
      );
      await tester.pumpAndSettle();

      expect(find.text('Use at least 15 characters.'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Create account'),
            )
            .onPressed,
        isNull,
      );
    });

    testWidgets('generated passphrase fills both account password fields', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      await openSettings(
        tester,
        provider,
        syncAccountService: _FakeSyncAccountService(),
      );
      await tapText(tester, 'Create a sync account');
      await tapText(tester, 'Generate passphrase');

      final password = tester
          .widget<TextField>(
            find.widgetWithText(TextField, 'New sync password'),
          )
          .controller!
          .text;
      final confirmation = tester
          .widget<TextField>(
            find.widgetWithText(TextField, 'Confirm sync password'),
          )
          .controller!
          .text;
      expect(password, isNotEmpty);
      expect(confirmation, password);
    });

    testWidgets('account password and confirmation reveal independently', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      await openSettings(tester, provider);
      await tapText(tester, 'Create a sync account');

      final passwordField = find.widgetWithText(TextField, 'New sync password');
      final confirmationField = find.widgetWithText(
        TextField,
        'Confirm sync password',
      );
      expect(tester.widget<TextField>(passwordField).obscureText, isTrue);
      expect(tester.widget<TextField>(confirmationField).obscureText, isTrue);

      await tester.tap(
        find.descendant(
          of: confirmationField,
          matching: find.byTooltip('Show password'),
        ),
      );
      await tester.pump();

      expect(tester.widget<TextField>(passwordField).obscureText, isTrue);
      expect(tester.widget<TextField>(confirmationField).obscureText, isFalse);
    });

    testWidgets('signed-in users can open the password-change form', (
      tester,
    ) async {
      final provider = await loadedProvider(tester, {
        'lingua_srs_sync_pairing': pairing.link,
      });
      await openSettings(tester, provider);
      await tapText(tester, 'Change password');

      expect(find.text('New sync password'), findsOneWidget);
      expect(find.text('Confirm new sync password'), findsOneWidget);
      expect(find.text('Save new password'), findsOneWidget);

      final passwordField = find.widgetWithText(TextField, 'New sync password');
      final confirmationField = find.widgetWithText(
        TextField,
        'Confirm new sync password',
      );
      expect(tester.widget<TextField>(passwordField).obscureText, isTrue);
      expect(tester.widget<TextField>(confirmationField).obscureText, isTrue);
      await tester.tap(
        find.descendant(
          of: passwordField,
          matching: find.byTooltip('Show password'),
        ),
      );
      await tester.pump();
      expect(tester.widget<TextField>(passwordField).obscureText, isFalse);
      expect(tester.widget<TextField>(confirmationField).obscureText, isTrue);

      await tester.enterText(passwordField, 'short');
      await tester.pumpAndSettle();
      expect(find.text('Use at least 15 characters.'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Save new password'),
            )
            .onPressed,
        isNull,
      );
    });

    testWidgets('generated passphrase fills both password-change fields', (
      tester,
    ) async {
      final provider = await loadedProvider(tester, {
        'lingua_srs_sync_pairing': pairing.link,
      });
      await openSettings(
        tester,
        provider,
        syncAccountService: _FakeSyncAccountService(),
      );
      await tapText(tester, 'Change password');
      await tapText(tester, 'Generate passphrase');

      final password = tester
          .widget<TextField>(
            find.widgetWithText(TextField, 'New sync password'),
          )
          .controller!
          .text;
      final confirmation = tester
          .widget<TextField>(
            find.widgetWithText(TextField, 'Confirm new sync password'),
          )
          .controller!
          .text;
      expect(password, isNotEmpty);
      expect(confirmation, password);
    });

    testWidgets('pair another device displays and copies a QR invite', (
      tester,
    ) async {
      final provider = await loadedProvider(tester, {
        'lingua_srs_sync_pairing': pairing.link,
      });
      final service = _FakeSyncAccountService(
        pairingLink: 'linguasrs://pair?token=${'c' * 64}#${'d' * 43}',
      );
      await openSettings(tester, provider, syncAccountService: service);
      await tapText(tester, 'Pair another device');

      expect(find.text('Pair another device'), findsNWidgets(2));
      expect(find.text('Copy one-time link'), findsOneWidget);
      expect(find.byType(QrImageView), findsOneWidget);
      await tapText(tester, 'Copy one-time link');
      expect(copied, service.pairingLink);
    });

    testWidgets('deleting the account requires confirmation and signs out', (
      tester,
    ) async {
      final provider = await loadedProvider(tester, {
        'lingua_srs_sync_pairing': pairing.link,
      });
      final service = _FakeSyncAccountService();
      await openSettings(tester, provider, syncAccountService: service);
      await tapText(tester, 'Delete account');
      expect(find.text('Delete sync account?'), findsOneWidget);
      expect(service.accountDeleted, isFalse);
      final confirmDelete = find.text('Delete account').last;
      await tester.ensureVisible(confirmDelete);
      await tester.tap(confirmDelete);
      await tester.pumpAndSettle();

      expect(service.accountDeleted, isTrue);
      expect(provider.syncPairing, isNull);
    });

    testWidgets('a copied sign-in link signs in', (tester) async {
      clipboardText = '${pairing.link}\n';
      final provider = await loadedProvider(tester);
      await openSettings(tester, provider);

      await tapText(tester, 'Use copied link');

      expect(provider.syncPairing, pairing);
      expect(find.text('Signed in as reader@example.com'), findsOneWidget);
    });

    testWidgets('sign-in sends unconfirmed accounts to email confirmation', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      final service = _FakeSyncAccountService(unconfirmed: true);
      await openSettings(tester, provider, syncAccountService: service);
      await typeCredentials(tester);
      await tapText(tester, 'Sign in');

      expect(provider.syncPairing, isNull);
      expect(find.text('Email confirmation code'), findsOneWidget);
      expect(
        find.text(
          'This account still needs email confirmation. Enter the code from '
          'your email, then tap Confirm email.',
        ),
        findsOneWidget,
      );

      final codeField = find.widgetWithText(
        TextField,
        'Email confirmation code',
      );
      expect(tester.widget<TextField>(codeField).autofillHints, [
        AutofillHints.oneTimeCode,
      ]);
      final confirmButton = find.widgetWithText(FilledButton, 'Confirm email');
      expect(tester.widget<FilledButton>(confirmButton).onPressed, isNull);
      await tester.enterText(codeField, '1234 5678-9');
      await tester.pumpAndSettle();

      expect(service.confirmedCode, '12345678');
      expect(provider.syncPairing, pairing);
    });

    testWidgets('a wrong email or password is explained plainly', (tester) async {
      final provider = await loadedProvider(tester);
      final service = _FakeSyncAccountService(
        validateError: const SyncException(
          'Sync request failed (401): {"error":"invalid_credentials"}',
          statusCode: 401,
        ),
      );
      await openSettings(tester, provider, syncAccountService: service);
      await typeCredentials(tester);
      await tapText(tester, 'Sign in');

      expect(
        find.textContaining('Wrong email or password, or this account'),
        findsOneWidget,
      );
      expect(provider.syncPairing, isNull);
    });

    testWidgets('a signed-in device can check that the server accepts it', (
      tester,
    ) async {
      final provider = await loadedProvider(tester, {
        'lingua_srs_sync_pairing': pairing.link,
      });
      final service = _FakeSyncAccountService();
      await openSettings(tester, provider, syncAccountService: service);

      await tapText(tester, 'Check sign-in');

      expect(service.credentialsValidated, isTrue);
      expect(find.text('The server accepts this sign-in.'), findsOneWidget);
    });

    testWidgets('a sign-in the server rejects is explained, not removed', (
      tester,
    ) async {
      final provider = await loadedProvider(tester, {
        'lingua_srs_sync_pairing': pairing.link,
      });
      final service = _FakeSyncAccountService(
        validateError: const SyncException(
          'Sync request failed (401): {"error":"invalid_credentials"}',
          statusCode: 401,
        ),
      );
      await openSettings(tester, provider, syncAccountService: service);

      await tapText(tester, 'Check sign-in');

      expect(
        find.textContaining('no longer accepts this sign-in'),
        findsOneWidget,
      );
      expect(find.textContaining('still on this device'), findsOneWidget);
      // The person decides: nothing signs this device out by itself.
      expect(provider.syncPairing, pairing);
      expect(find.text('Sign out'), findsOneWidget);
    });

    testWidgets('a refused code signs in if the account is already confirmed', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      final service = _FakeSyncAccountService(
        unconfirmed: true,
        confirmError: const SyncException(
          'Sync request failed (400): {"error":"invalid_code"}',
          statusCode: 400,
        ),
      );
      await openSettings(tester, provider, syncAccountService: service);
      await typeCredentials(tester);
      await tapText(tester, 'Sign in');
      // The account is confirmed after all (a first attempt got through, but
      // this device never saw the answer), so the credentials now work.
      service.unconfirmed = false;

      await tester.enterText(
        find.widgetWithText(TextField, 'Email confirmation code'),
        '12345678',
      );
      await tester.pumpAndSettle();

      expect(provider.syncPairing, pairing);
    });

    testWidgets('a wrong code is reported as a wrong code', (tester) async {
      final provider = await loadedProvider(tester);
      final service = _FakeSyncAccountService(
        unconfirmed: true,
        confirmError: const SyncException(
          'Sync request failed (400): {"error":"invalid_code"}',
          statusCode: 400,
        ),
      );
      await openSettings(tester, provider, syncAccountService: service);
      await typeCredentials(tester);
      await tapText(tester, 'Sign in');

      await tester.enterText(
        find.widgetWithText(TextField, 'Email confirmation code'),
        '12345678',
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('wrong or has expired'), findsOneWidget);
      expect(provider.syncPairing, isNull);
    });

    testWidgets('an unconfirmed account can be deleted from confirmation', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      final service = _FakeSyncAccountService(unconfirmed: true);
      await openSettings(tester, provider, syncAccountService: service);
      await typeCredentials(tester);
      await tapText(tester, 'Sign in');
      await tapText(tester, 'Delete unconfirmed account');

      expect(find.text('Delete unconfirmed account?'), findsOneWidget);
      await tapText(tester, 'Delete account');

      expect(service.accountDeleted, isTrue);
      expect(provider.syncPairing, isNull);
      expect(find.text('Unconfirmed account deleted.'), findsOneWidget);
    });

    testWidgets('a copied link to another server keeps that server', (
      tester,
    ) async {
      final local = SyncPairing(
        endpoint: Uri.parse('http://localhost:8787'),
        email: _email,
        password: _password,
      );
      clipboardText = 'linguasrs://pair?token=${'a' * 64}#${'b' * 43}';
      final provider = await loadedProvider(tester);
      final service = _FakeSyncAccountService(redeemedPairing: local);
      await openSettings(tester, provider, syncAccountService: service);

      await tapText(tester, 'Use copied link');
      // The server is shown before anything is saved.
      expect(find.textContaining('localhost:8787'), findsOneWidget);
      await tapText(tester, 'Pair');

      expect(provider.syncPairing, local);
      expect(find.text('Server http://localhost:8787'), findsOneWidget);
    });

    testWidgets('a copied pairing link asks before it signs in', (
      tester,
    ) async {
      final link = 'linguasrs://pair?token=${'a' * 64}#${'b' * 43}';
      clipboardText = link;
      final provider = await loadedProvider(tester);
      final service = _FakeSyncAccountService();
      await openSettings(tester, provider, syncAccountService: service);

      await tapText(tester, 'Use copied link');

      expect(service.redeemedLink, link);
      expect(find.text('Pair this device?'), findsOneWidget);
      expect(find.textContaining('reader@example.com'), findsOneWidget);
      expect(find.textContaining('sync.example.com'), findsOneWidget);
      expect(provider.syncPairing, isNull);

      await tapText(tester, 'Pair');

      expect(provider.syncPairing, pairing);
      expect(find.text('Signed in as reader@example.com'), findsOneWidget);
    });

    testWidgets('a pairing link that is declined signs nobody in', (
      tester,
    ) async {
      clipboardText = 'linguasrs://pair?token=${'a' * 64}#${'b' * 43}';
      final provider = await loadedProvider(tester);
      await openSettings(tester, provider);

      await tapText(tester, 'Use copied link');
      await tester.tap(find.widgetWithText(TextButton, 'Cancel').last);
      await tester.pumpAndSettle();

      expect(find.text('Pair this device?'), findsNothing);
      expect(provider.syncPairing, isNull);
      expect(emailField, findsOneWidget);
    });

    testWidgets('a link that carries the password itself is not accepted', (
      tester,
    ) async {
      clipboardText = pairing.link;
      final provider = await loadedProvider(tester);
      await openSettings(tester, provider);

      await tapText(tester, 'Use copied link');

      expect(find.text('Not a LinguaSRS pairing link.'), findsOneWidget);
      expect(provider.syncPairing, isNull);
    });

    testWidgets('copied text that is not a sign-in link is rejected', (
      tester,
    ) async {
      clipboardText = 'https://example.com';
      final provider = await loadedProvider(tester);
      await openSettings(tester, provider);

      await tapText(tester, 'Use copied link');

      expect(find.text('Not a LinguaSRS pairing link.'), findsOneWidget);
      expect(provider.syncPairing, isNull);
    });

    testWidgets('an empty clipboard is rejected', (tester) async {
      final provider = await loadedProvider(tester);
      await openSettings(tester, provider);

      await tapText(tester, 'Use copied link');

      expect(find.text('Not a LinguaSRS pairing link.'), findsOneWidget);
      expect(provider.syncPairing, isNull);
    });

    testWidgets('a signed-in device can copy a one-time pairing link', (
      tester,
    ) async {
      final provider = await loadedProvider(tester, {
        'lingua_srs_sync_pairing': pairing.link,
      });
      final service = _FakeSyncAccountService(
        pairingLink: 'linguasrs://pair?token=${'e' * 64}#${'f' * 43}',
      );
      await openSettings(tester, provider, syncAccountService: service);

      expect(emailField, findsNothing);
      expect(find.text('Signed in as reader@example.com'), findsOneWidget);
      expect(find.text('Copy password'), findsNothing);

      await tapText(tester, 'Pair another device');
      await tapText(tester, 'Copy one-time link');

      expect(copied, service.pairingLink);
      expect(
        find.textContaining('One-time pairing link copied'),
        findsOneWidget,
      );
    });

    testWidgets('signing out asks first and keeps the sign-in on Cancel', (
      tester,
    ) async {
      final provider = await loadedProvider(tester, {
        'lingua_srs_sync_pairing': pairing.link,
      });
      await openSettings(tester, provider);

      await tapText(tester, 'Sign out');
      expect(find.text('Sign out of sync?'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel').last);
      await tester.pumpAndSettle();

      expect(find.text('Sign out of sync?'), findsNothing);
      expect(provider.syncPairing, pairing);
    });

    testWidgets('confirming Sign out forgets the account', (tester) async {
      final provider = await loadedProvider(tester, {
        'lingua_srs_sync_pairing': pairing.link,
      });
      await openSettings(tester, provider);

      await tapText(tester, 'Sign out');
      await tester.tap(find.widgetWithText(FilledButton, 'Sign out'));
      await tester.pumpAndSettle();

      expect(provider.syncPairing, isNull);
      expect(await tester.runAsync(StorageService.loadSyncPairing), isNull);
      expect(emailField, findsOneWidget);
    });

    testWidgets('a build without a sync server has no Sync section', (
      tester,
    ) async {
      SyncPairing.defaultEndpoint = null;
      final provider = await loadedProvider(tester);
      await openSettings(tester, provider);

      expect(find.text('Sync'), findsNothing);
      expect(emailField, findsNothing);
    });

    testWidgets('a signed-in device keeps its Sync section without a server', (
      tester,
    ) async {
      final provider = await loadedProvider(tester, {
        'lingua_srs_sync_pairing': pairing.link,
      });
      SyncPairing.defaultEndpoint = null;
      await openSettings(tester, provider);

      expect(find.text('Sync'), findsOneWidget);
      expect(find.text('Signed in as reader@example.com'), findsOneWidget);
    });
  });
}
