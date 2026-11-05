import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/providers/app_provider.dart';
import 'package:lingua_srs/services/backup_service.dart';
import 'package:lingua_srs/services/storage_service.dart';
import 'package:lingua_srs/services/sync_pairing.dart';
import 'package:lingua_srs/services/sync_records.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'secret_storage_mock.dart';

const _stateKey = 'lingua_srs_sync_state';
const _settings = SyncRecordKey('settings', 'settings');
const _lessonOrder = SyncRecordKey('lesson_order', 'lesson_order');

final _pairing = SyncPairing(
  endpoint: Uri.parse('https://sync.example.com'),
  email: 'reader@example.com',
  password: 'correct horse battery staple',
);

Future<AppProvider> _loadedProvider() async {
  final provider = AppProvider();
  while (provider.isLoading) {
    await Future<void>.delayed(Duration.zero);
  }
  return provider;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final storageDirectory = Directory.systemTemp.createTempSync(
    'lingua_srs_sync_tracking_test_',
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

  setUp(() {
    setUpSecretStorage();
    SharedPreferences.setMockInitialValues({
      'lingua_srs_windows_legacy_migration_complete': true,
    });
  });

  test('does nothing while signed out', () async {
    final provider = await _loadedProvider();

    expect(await provider.trackSyncChanges(), isEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(_stateKey), isNull);
  });

  test('notes every record once after signing in, then only changes', () async {
    final provider = await _loadedProvider();
    await provider.setSyncPairing(_pairing);

    final first = await provider.trackSyncChanges(
      now: DateTime.utc(2026, 11, 5, 12),
    );
    expect(first, containsAll([_settings, _lessonOrder]));
    expect(await provider.trackSyncChanges(), isEmpty);

    await provider.toggleAutoplay();
    final changed = await provider.trackSyncChanges(
      now: DateTime.utc(2026, 11, 5, 13),
    );

    expect(changed, [_settings]);
    final tracker = await StorageService.loadSyncChangeTracker();
    expect(
      tracker.records[_settings]!.updatedAt,
      DateTime.utc(2026, 11, 5, 13).millisecondsSinceEpoch,
    );
    expect(tracker.pending, containsAll([_settings, _lessonOrder]));
  });

  test('signing out forgets the records but keeps the device id', () async {
    final provider = await _loadedProvider();
    await provider.setSyncPairing(_pairing);
    await provider.trackSyncChanges();
    final deviceId = (await StorageService.loadSyncChangeTracker()).deviceId;

    await provider.setSyncPairing(null);

    final tracker = await StorageService.loadSyncChangeTracker();
    expect(tracker.records, isEmpty);
    expect(tracker.deviceId, deviceId);
  });

  test('an unreadable sync state starts again', () async {
    SharedPreferences.setMockInitialValues({_stateKey: 'not json'});

    final tracker = await StorageService.loadSyncChangeTracker();

    expect(tracker.records, isEmpty);
    expect(tracker.cursor, 0);
  });

  test('backup leaves out the sync state and restore keeps it', () async {
    final provider = await _loadedProvider();
    await provider.setSyncPairing(_pairing);
    await provider.trackSyncChanges();
    final prefs = await SharedPreferences.getInstance();
    final state = prefs.getString(_stateKey);
    expect(state, isNotNull);

    final backup = await BackupService.createBackup();
    expect(
      (jsonDecode(backup) as Map)['preferences'] as Map,
      isNot(contains(_stateKey)),
    );

    await BackupService.restoreBackup(backup);
    expect(prefs.getString(_stateKey), state);
  });
}
