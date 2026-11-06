import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/lesson.dart';
import 'package:lingua_srs/models/sentence.dart';
import 'package:lingua_srs/models/vocab_item.dart';
import 'package:lingua_srs/providers/app_provider.dart';
import 'package:lingua_srs/services/sync_records.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'secret_storage_mock.dart';

/// A lesson whose only word links [sentenceIds].
Lesson _lesson(List<String> sentenceIds) => Lesson(
  id: 'lesson',
  title: 'Boats',
  vocabularies: [
    VocabItem(
      id: 'boat',
      targetWord: '배',
      translation: 'boat',
      pos: 'nouns',
      sentenceIds: sentenceIds,
    ),
  ],
);

Sentence _sentence(String id, {String? audioUrl, String notes = ''}) =>
    Sentence(
      id: id,
      targetText: '저는 배를 탔어요',
      translationText: 'I took the boat.',
      audioUrl: audioUrl,
      notes: notes,
    );

Future<AppProvider> _load(Lesson lesson, List<Sentence> sentences) async {
  SharedPreferences.setMockInitialValues({
    'lingua_srs_windows_legacy_migration_complete': true,
    'lingua_srs_lessons': jsonEncode([lesson.toJson()]),
    'lingua_srs_sentences': jsonEncode([
      for (final sentence in sentences) sentence.toJson(),
    ]),
  });
  final provider = AppProvider();
  while (provider.isLoading) {
    await Future<void>.delayed(Duration.zero);
  }
  return provider;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final storageDirectory = Directory.systemTemp.createTempSync(
    'lingua_srs_sentence_merge_test_',
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
  setUp(setUpSecretStorage);

  test('keeps the same copy of a duplicate whatever the order', () async {
    for (final order in [
      ['b-from-this-device', 'a-from-another'],
      ['a-from-another', 'b-from-this-device'],
    ]) {
      final provider = await _load(_lesson(order), [
        for (final id in order) _sentence(id),
      ]);

      expect(provider.sentences.map((s) => s.id), [
        'a-from-another',
      ], reason: '$order');
      expect(provider.lessons.single.vocabularies.single.sentenceIds, [
        'a-from-another',
      ], reason: '$order');
      provider.dispose();
    }
  });

  test('keeps the copy with a recording, with the notes of the other', () async {
    final provider = await _load(_lesson(['a-plain', 'z-recorded']), [
      _sentence('a-plain', notes: 'Said on a ferry.'),
      _sentence('z-recorded', audioUrl: 'https://example.com/boat.mp3'),
    ]);

    final kept = provider.sentences.single;
    expect(kept.id, 'z-recorded');
    expect(kept.audioUrl, 'https://example.com/boat.mp3');
    expect(kept.notes, 'Said on a ferry.');
    provider.dispose();
  });

  test('merges a pulled duplicate at once, onto the same copy', () async {
    final provider = await _load(_lesson(['z-local']), [_sentence('z-local')]);

    await provider.apply('this-device', {
      const SyncRecordKey('sentence', 'a-pulled'): _sentence(
        'a-pulled',
      ).toJson(),
    });

    expect(provider.sentences.map((s) => s.id), ['a-pulled']);
    expect(provider.lessons.single.vocabularies.single.sentenceIds, [
      'a-pulled',
    ]);
    // The merge is saved, not only made in memory.
    final prefs = await SharedPreferences.getInstance();
    final saved = jsonDecode(prefs.getString('lingua_srs_sentences')!) as List;
    expect(saved.map((s) => (s as Map)['id']), ['a-pulled']);
    provider.dispose();
  });
}
