import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lingua_srs/models/lesson.dart';
import 'package:lingua_srs/providers/app_provider.dart';
import 'package:lingua_srs/services/storage_service.dart';
import 'package:lingua_srs/services/sync_client.dart';
import 'package:lingua_srs/services/sync_engine.dart';
import 'package:lingua_srs/services/sync_pairing.dart';
import 'package:lingua_srs/services/sync_record_cipher.dart';
import 'package:lingua_srs/services/sync_records.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_sync_worker.dart';
import 'secret_storage_mock.dart';

final _endpoint = Uri.parse('https://sync.example.com');
final _dataKey = List<int>.generate(32, (i) => i);
final _pairing = SyncPairing(
  endpoint: _endpoint,
  email: 'reader@example.com',
  password: 'correct horse battery staple',
);

Future<AppProvider> _signedIn(FakeWorker worker) async {
  final provider = AppProvider();
  while (provider.isLoading) {
    await Future<void>.delayed(Duration.zero);
  }
  await provider.setSyncPairing(_pairing);
  // Saved after signing in, which removes any earlier key.
  await StorageService.saveSyncDataKey(
    SyncDataKey(
      endpoint: _endpoint,
      email: _pairing.email,
      createdAt: worker.createdAt,
      key: _dataKey,
      authKey: 'test-auth-key',
    ),
  );
  provider.syncHttpClient = worker.client;
  return provider;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final storageDirectory = Directory.systemTemp.createTempSync(
    'lingua_srs_sync_now_test_',
  );
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(pathProviderChannel, (call) async {
        if (call.method == 'getApplicationSupportDirectory') {
          return storageDirectory.path;
        }
        throw MissingPluginException('Unexpected method: ${call.method}');
      });
  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    await storageDirectory.delete(recursive: true);
  });

  late FakeWorker worker;
  setUp(() {
    setUpSecretStorage();
    SharedPreferences.setMockInitialValues({
      'lingua_srs_windows_legacy_migration_complete': true,
    });
    worker = FakeWorker();
  });

  test('does nothing while signed out', () async {
    final provider = AppProvider();
    while (provider.isLoading) {
      await Future<void>.delayed(Duration.zero);
    }

    expect(await provider.syncNow(), isNull);
    expect(provider.lastSyncedAt, isNull);
  });

  test('pushes local records and remembers when it synced', () async {
    final provider = await _signedIn(worker);

    final result = await provider.syncNow();

    expect(result?.outcome, SyncOutcome.synced);
    expect(provider.syncProblem, isNull);
    expect(provider.isSyncing, isFalse);
    expect(provider.lastSyncedAt, isNotNull);
    expect(await StorageService.loadLastSyncedAt(), provider.lastSyncedAt);
    final cipher = await SyncRecordCipher.create(_dataKey);
    final settingsId = await cipher.recordId(
      const SyncRecordKey('settings', 'settings'),
    );
    expect(worker.rows.containsKey('settings/$settingsId'), isTrue);
  });

  test('pulls a lesson from another device into the app', () async {
    final cipher = await SyncRecordCipher.create(_dataKey);
    final lesson = Lesson(id: 'remote', title: 'From the phone');
    final records = await cipher.encode(
      const SyncRecordKey('lesson', 'remote'),
      lesson.toJson(),
      updatedAt: 1000,
    );
    await SyncClient(
      endpoint: _endpoint,
      email: _pairing.email,
      authKey: 'test-auth-key',
      client: worker.client(),
    ).push(records);
    final provider = await _signedIn(worker);

    await provider.syncNow();

    expect(provider.lessons.map((l) => l.title), contains('From the phone'));
  });

  test('a rejected sign-in is explained and changes nothing', () async {
    final provider = await _signedIn(worker);
    worker.rejectSignIn = true;

    final result = await provider.syncNow();

    expect(result?.outcome, SyncOutcome.signInRejected);
    expect(provider.syncProblem, contains('no longer accepts this sign-in'));
    expect(provider.lastSyncedAt, isNull);
  });

  test('a re-created account pauses sync', () async {
    final provider = await _signedIn(worker);
    worker.createdAt = 2000;

    final result = await provider.syncNow();

    expect(result?.outcome, SyncOutcome.accountChanged);
    expect(provider.syncProblem, contains('deleted and created again'));
    expect(worker.rows, isEmpty);
  });

  test('no connection is explained and keeps the data', () async {
    final provider = await _signedIn(worker);
    provider.syncHttpClient = () =>
        MockClient((_) async => throw http.ClientException('offline'));

    final result = await provider.syncNow();

    expect(result, isNull);
    expect(provider.syncProblem, contains('Could not reach the sync server'));
    expect(provider.isSyncing, isFalse);
  });

  test('signing out clears the sync status', () async {
    final provider = await _signedIn(worker);
    await provider.syncNow();

    await provider.setSyncPairing(null);

    expect(provider.lastSyncedAt, isNull);
    expect(await StorageService.loadLastSyncedAt(), isNull);
  });
}
