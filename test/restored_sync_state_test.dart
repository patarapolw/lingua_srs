import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/services/storage_service.dart';
import 'package:lingua_srs/services/sync_change_tracker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'debug_print_capture.dart';
import 'secret_storage_mock.dart';

const _stateKey = 'lingua_srs_sync_state';
const _lastSyncedKey = 'lingua_srs_sync_last_synced_at';
const _markKey = 'lingua_srs_sync_device_mark';
const _pairingKey = 'lingua_srs_sync_pairing';

/// Preferences as Android restores them from its backup on a new phone, or
/// as they are on the device that synced: the same sync state either way.
void _preferencesWithSyncState() {
  SharedPreferences.setMockInitialValues({
    _stateKey: jsonEncode(
      SyncChangeTracker(deviceId: 'old-phone', cursor: 42).toJson(),
    ),
    _lastSyncedKey: '2026-11-01T10:00:00.000Z',
  });
}

/// A new start of the app: the restore check runs again.
void _restart() {
  StorageService.detectsRestoredSyncStateForTesting = true;
}

/// Android restores preferences from its backup, but never secure storage
/// (android/app/src/main/res/xml/data_extraction_rules.xml). A restored copy
/// must not keep the old device's sync state and device id.
void main() {
  late MemorySecretStorage secrets;

  setUp(() {
    secrets = MemorySecretStorage();
    StorageService.secretStorageForTesting = secrets;
    _restart();
  });

  tearDown(() {
    StorageService.detectsRestoredSyncStateForTesting = null;
  });

  test('a restored copy starts sync again with a new device id', () async {
    _preferencesWithSyncState();
    final printed = captureDebugPrints();

    final tracker = await StorageService.loadSyncChangeTracker();

    expect(tracker.deviceId, isNot('old-phone'));
    expect(tracker.cursor, 0);
    expect(tracker.records, isEmpty);
    expect(await StorageService.loadLastSyncedAt(), isNull);
    expect(secrets.values[_markKey], tracker.deviceId);
    expect(printed, [contains('restored from another device')]);

    // The new id is saved, so it stays the same, also after a restart.
    expect(
      (await StorageService.loadSyncChangeTracker()).deviceId,
      tracker.deviceId,
    );
    _restart();
    expect(
      (await StorageService.loadSyncChangeTracker()).deviceId,
      tracker.deviceId,
    );
  });

  test('sync state marked with its own device id is kept', () async {
    _preferencesWithSyncState();
    secrets.values[_markKey] = 'old-phone';

    final tracker = await StorageService.loadSyncChangeTracker();

    expect(tracker.deviceId, 'old-phone');
    expect(tracker.cursor, 42);
    expect(await StorageService.loadLastSyncedAt(), isNotNull);
  });

  test('sync state marked for another device id starts again', () async {
    _preferencesWithSyncState();
    secrets.values[_markKey] = 'another-phone';
    captureDebugPrints();

    final tracker = await StorageService.loadSyncChangeTracker();

    expect(tracker.deviceId, isNot('old-phone'));
    expect(tracker.deviceId, isNot('another-phone'));
    expect(secrets.values[_markKey], tracker.deviceId);
  });

  test(
    'a device signed in from before marks keeps its sync state and is marked',
    () async {
      _preferencesWithSyncState();
      secrets.values[_pairingKey] = 'linguasrs://pair#signed-in';

      final tracker = await StorageService.loadSyncChangeTracker();

      expect(tracker.deviceId, 'old-phone');
      expect(tracker.cursor, 42);
      expect(secrets.values[_markKey], 'old-phone');
    },
  );

  test(
    'saving the sync state marks the device, so signing out keeps the id',
    () async {
      SharedPreferences.setMockInitialValues({});
      final tracker = SyncChangeTracker(deviceId: 'this-phone', cursor: 7);
      await StorageService.saveSyncChangeTracker(tracker);
      expect(secrets.values[_markKey], 'this-phone');

      // Signed out: the sign-in is gone, the state is reset but kept.
      tracker.reset();
      await StorageService.saveSyncChangeTracker(tracker);
      _restart();

      expect(
        (await StorageService.loadSyncChangeTracker()).deviceId,
        'this-phone',
      );
    },
  );

  test('keeps the sync state when secure storage cannot be read', () async {
    _preferencesWithSyncState();
    StorageService.secretStorageForTesting = const BrokenSecretStorage();
    final printed = captureDebugPrints();

    final tracker = await StorageService.loadSyncChangeTracker();

    expect(tracker.deviceId, 'old-phone');
    expect(tracker.cursor, 42);
    expect(printed, contains(contains('Could not read the sync device mark')));
  });

  test('without sync state nothing is marked', () async {
    SharedPreferences.setMockInitialValues({});

    await StorageService.loadSyncChangeTracker();

    expect(secrets.values, isEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(_stateKey), isNull);
  });

  test('off Android, the sync state is neither checked nor marked', () async {
    StorageService.detectsRestoredSyncStateForTesting = false;
    _preferencesWithSyncState();

    final tracker = await StorageService.loadSyncChangeTracker();
    await StorageService.saveSyncChangeTracker(tracker);

    expect(tracker.deviceId, 'old-phone');
    expect(secrets.values, isEmpty);
  });
}
