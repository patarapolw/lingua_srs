import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/services/coalescing_preferences_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

void main() {
  late Directory directory;
  late File file;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('prefs_store_test');
    file = File('${directory.path}${Platform.pathSeparator}prefs.json');
  });

  tearDown(() async {
    await directory.delete(recursive: true);
  });

  CoalescingPreferencesStore store([Map<String, Object>? stored]) =>
      CoalescingPreferencesStore(
        load: () async => {...?stored},
        file: () async => file,
        // Long enough that a test's burst of saves is in one write.
        delay: const Duration(seconds: 30),
      );

  Future<Map<String, Object?>> written() async =>
      jsonDecode(await file.readAsString()) as Map<String, Object?>;

  test('writes a burst of saves once, with every value', () async {
    final prefs = store({'flutter.kept': 'old'});
    await prefs.setValue('String', 'flutter.lessons', '[{"id":"a"}]');
    await prefs.setValue('Int', 'flutter.count', 3);
    await prefs.setValue('Bool', 'flutter.on', true);
    await prefs.setValue('StringList', 'flutter.list', ['x', 'y']);
    expect(file.existsSync(), isFalse);

    await prefs.flush();

    expect(prefs.writes, 1);
    expect(await written(), {
      'flutter.kept': 'old',
      'flutter.lessons': '[{"id":"a"}]',
      'flutter.count': 3,
      'flutter.on': true,
      'flutter.list': ['x', 'y'],
    });
    expect(File('${file.path}.tmp').existsSync(), isFalse);
  });

  test(
    're-encodes only the values that changed since the last write',
    () async {
      final prefs = store({
        'flutter.lessons': 'big',
        'flutter.sentences': 'big too',
      });
      await prefs.setValue('Int', 'flutter.count', 1);
      await prefs.flush();
      expect(prefs.encodedValues, 3);

      await prefs.setValue('Int', 'flutter.count', 2);
      await prefs.flush();

      expect(prefs.encodedValues, 4);
      expect(prefs.writes, 2);
      expect(await written(), {
        'flutter.lessons': 'big',
        'flutter.sentences': 'big too',
        'flutter.count': 2,
      });
    },
  );

  test('leaves out removed and cleared values', () async {
    final prefs = store({'flutter.a': 'a', 'flutter.b': 'b', 'other.c': 'c'});
    await prefs.flush();
    await prefs.remove('flutter.a');
    await prefs.flush();
    expect(await written(), {'flutter.b': 'b', 'other.c': 'c'});

    await prefs.clear();
    await prefs.flush();

    expect(await written(), {'other.c': 'c'});
    expect(await prefs.getAll(), isEmpty);
  });

  test('a flush with nothing changed writes nothing', () async {
    final prefs = store({
      'flutter.a': 'a',
      'flutter.list': ['x'],
    });
    await prefs.flush();
    await prefs.setValue('String', 'flutter.a', 'a');
    await prefs.setValue('StringList', 'flutter.list', ['x']);
    await prefs.flush();
    expect(prefs.writes, 0);
  });

  test('a change made during a write goes in the next one', () async {
    final prefs = store();
    await prefs.setValue('Int', 'flutter.count', 1);
    final first = prefs.flush();
    await prefs.setValue('Int', 'flutter.count', 2);
    final second = prefs.flush();
    await Future.wait([first, second]);

    expect(prefs.writes, 2);
    expect(await written(), {'flutter.count': 2});
  });

  test('writes on its own after the delay', () async {
    final prefs = CoalescingPreferencesStore(
      load: () async => {},
      file: () async => file,
      delay: const Duration(milliseconds: 10),
    );
    await prefs.setValue('Int', 'flutter.count', 1);
    await prefs.setValue('Int', 'flutter.count', 2);

    for (var i = 0; i < 200 && prefs.writes == 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    expect(prefs.writes, 1);
    expect(await written(), {'flutter.count': 2});
  });

  test(
    'serves SharedPreferences, which reads its own writes at once',
    () async {
      final prefs = store({'flutter.name': 'kept'});
      SharedPreferencesStorePlatform.instance = prefs;
      SharedPreferences.resetStatic();
      addTearDown(SharedPreferences.resetStatic);

      final shared = await SharedPreferences.getInstance();
      expect(shared.getString('name'), 'kept');
      await shared.setString('lessons', '[]');
      await shared.setInt('count', 4);
      expect(shared.getInt('count'), 4);

      await prefs.flush();
      expect(await written(), {
        'flutter.name': 'kept',
        'flutter.lessons': '[]',
        'flutter.count': 4,
      });

      await shared.reload();
      expect(shared.getString('lessons'), '[]');
    },
  );
}
