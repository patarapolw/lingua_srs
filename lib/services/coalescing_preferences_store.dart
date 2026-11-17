import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart'
    show AppLifecycleListener, AppLifecycleState;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

/// The preferences store on Windows and Linux.
///
/// There the shared_preferences plugins keep every value in one JSON file and,
/// for each value set, encode and write the whole file on the UI isolate. The
/// app keeps its lessons, vocabulary and sync state in preferences, so the
/// file is tens of megabytes, and a review, which saves about nine values,
/// stalled the app for seconds.
///
/// This store keeps the same file in the same format, so nothing is migrated,
/// but writes it once for a burst of changes. It re-encodes only the values
/// that changed, on a background isolate, writes asynchronously, and replaces
/// the file only once the new one is complete.
class CoalescingPreferencesStore extends SharedPreferencesStorePlatform {
  CoalescingPreferencesStore({
    required this._load,
    required this._file,
    this.delay = defaultDelay,
  });

  /// How long after the first change of a burst the file is written. A
  /// review's saves take longer than one frame, since lessons are encoded
  /// between them, so this covers them all.
  static const defaultDelay = Duration(milliseconds: 500);

  /// The longest an exit waits for the last write.
  static const _exitTimeout = Duration(seconds: 10);

  /// Puts this store in front of the platform's on Windows and Linux. It
  /// reads the plugin's file through the plugin once, then writes that file
  /// itself.
  static void install() {
    if (kIsWeb || !(Platform.isWindows || Platform.isLinux)) return;
    final platform = SharedPreferencesStorePlatform.instance;
    final store = CoalescingPreferencesStore(
      load: () => platform.getAllWithParameters(
        GetAllParameters(filter: PreferencesFilter(prefix: '')),
      ),
      // Where both plugins keep it.
      file: () async {
        final directory = await getApplicationSupportDirectory();
        return File(
          '${directory.path}${Platform.pathSeparator}shared_preferences.json',
        );
      },
    );
    SharedPreferencesStorePlatform.instance = store;
    store._lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        if (state != AppLifecycleState.resumed &&
            state != AppLifecycleState.inactive) {
          unawaited(store.flush());
        }
      },
      onExitRequested: () async {
        await store.flush().timeout(_exitTimeout, onTimeout: () {});
        return AppExitResponse.exit;
      },
    );
  }

  final Future<Map<String, Object>> Function() _load;
  final Future<File> Function() _file;
  final Duration delay;

  // Kept so the exit and pause flushes stay registered.
  // ignore: unused_field
  AppLifecycleListener? _lifecycle;

  Future<Map<String, Object>>? _loaded;
  Future<Map<String, Object>> get _values => _loaded ??= _load();

  /// Each value's `"key":value` JSON as UTF-8, for every key not in [_dirty].
  final _entries = <String, Uint8List>{};

  /// Keys set since their entry was last encoded. Every key is dirty until
  /// the first write.
  Set<String>? _dirty;

  bool _changed = false;
  Timer? _timer;
  Future<void>? _writing;

  /// Values encoded so far, to check that a write re-encodes only what
  /// changed.
  @visibleForTesting
  int encodedValues = 0;

  /// Files written so far.
  @visibleForTesting
  int writes = 0;

  Future<Set<String>> get _dirtyKeys async =>
      _dirty ??= (await _values).keys.toSet();

  Future<void> _changedKeys(Iterable<String> keys) async {
    (await _dirtyKeys).addAll(keys);
    _changed = true;
    _timer ??= Timer(delay, () => unawaited(flush()));
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    final values = await _values;
    final old = values[key];
    // A review saves lessons and sentences again unchanged.
    if (old == value ||
        (old is List && value is List && listEquals(old, value))) {
      return true;
    }
    values[key] = value;
    await _changedKeys([key]);
    return true;
  }

  @override
  Future<bool> remove(String key) async {
    (await _values).remove(key);
    _entries.remove(key);
    await _changedKeys(const []);
    return true;
  }

  @override
  Future<bool> clear() => clearWithPrefix('flutter.');

  @override
  Future<bool> clearWithPrefix(String prefix) => clearWithParameters(
    ClearParameters(filter: PreferencesFilter(prefix: prefix)),
  );

  @override
  Future<bool> clearWithParameters(ClearParameters parameters) async {
    final values = await _values;
    final removed = values.keys.where(_matches(parameters.filter)).toList();
    for (final key in removed) {
      values.remove(key);
      _entries.remove(key);
    }
    await _changedKeys(const []);
    return true;
  }

  @override
  Future<Map<String, Object>> getAll() => getAllWithPrefix('flutter.');

  @override
  Future<Map<String, Object>> getAllWithPrefix(String prefix) =>
      getAllWithParameters(
        GetAllParameters(filter: PreferencesFilter(prefix: prefix)),
      );

  @override
  Future<Map<String, Object>> getAllWithParameters(
    GetAllParameters parameters,
  ) async {
    final values = await _values;
    return {
      for (final key in values.keys.where(_matches(parameters.filter)))
        key: values[key]!,
    };
  }

  static bool Function(String) _matches(PreferencesFilter filter) =>
      (key) =>
          key.startsWith(filter.prefix) &&
          (filter.allowList?.contains(key) ?? true);

  /// Writes the changes not written yet, waiting for a write in progress
  /// first. A change made during a write is left to the next one.
  Future<void> flush() async {
    _timer?.cancel();
    _timer = null;
    while (_writing != null) {
      await _writing;
    }
    if (!_changed) return;
    final writing = _write();
    _writing = writing;
    try {
      await writing;
    } finally {
      _writing = null;
    }
  }

  Future<void> _write() async {
    _changed = false;
    final values = await _values;
    final dirty = await _dirtyKeys;
    final changed = {
      for (final key in dirty)
        if (values.containsKey(key)) key: values[key]!,
    };
    dirty.clear();
    try {
      if (changed.isNotEmpty) {
        // Isolate.run hands the result back without copying it.
        _entries.addAll(await Isolate.run(() => _encode(changed)));
        encodedValues += changed.length;
      }
      final file = await _file();
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.tmp');
      final sink = temporary.openWrite();
      sink.add(const [0x7b]); // {
      var first = true;
      for (final key in values.keys) {
        // A key set while its value was encoded is left to the next write.
        final entry = _entries[key];
        if (entry == null) continue;
        if (!first) sink.add(const [0x2c]); // ,
        first = false;
        sink.add(entry);
      }
      sink.add(const [0x7d]); // }
      await sink.flush();
      await sink.close();
      await temporary.rename(file.path);
      writes++;
    } catch (error) {
      debugPrint('Saving preferences failed: $error');
      // Encode them again and try with the next change or flush.
      dirty.addAll(changed.keys);
      _changed = true;
    }
  }

  static Map<String, Uint8List> _encode(Map<String, Object> values) => {
    for (final entry in values.entries)
      entry.key: utf8.encode(
        '${jsonEncode(entry.key)}:${jsonEncode(entry.value)}',
      ),
  };
}
