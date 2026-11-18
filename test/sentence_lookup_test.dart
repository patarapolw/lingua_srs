import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/sentence.dart';
import 'package:lingua_srs/providers/app_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'secret_storage_mock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(setUpSecretStorage);

  group('AppProvider.getSentenceById', () {
    late AppProvider provider;

    setUp(() async {
      SharedPreferences.setMockInitialValues({
        'lingua_srs_windows_legacy_migration_complete': true,
      });
      provider = AppProvider();
      for (var attempt = 0; attempt < 100 && provider.isLoading; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(provider.isLoading, isFalse);
    });

    tearDown(() => provider.dispose());

    Future<Sentence> add(String text) => provider.addSentenceToPool(
      Sentence(targetText: text, translationText: text),
    );

    test('finds a pool sentence and returns null for a missing id', () async {
      final apple = await add('사과');
      final pear = await add('배');

      expect(provider.getSentenceById(apple.id), same(apple));
      expect(provider.getSentenceById(pear.id), same(pear));
      expect(provider.getSentenceById('missing'), isNull);
    });

    test('keeps up as sentences are added, moved and deleted', () async {
      final apple = await add('사과');
      final pear = await add('배');
      expect(provider.getSentenceById(pear.id), same(pear));

      // Shift every position after the lookups above built the index.
      final grape = Sentence(targetText: '포도', translationText: 'grape');
      provider.sentences.insert(0, grape);
      expect(provider.getSentenceById(grape.id), same(grape));
      expect(provider.getSentenceById(apple.id), same(apple));
      expect(provider.getSentenceById(pear.id), same(pear));

      await provider.deleteSentenceFromPool(apple);
      expect(provider.getSentenceById(apple.id), isNull);
      expect(provider.getSentenceById(pear.id), same(pear));

      final peach = await add('복숭아');
      expect(provider.getSentenceById(peach.id), same(peach));
    });

    test('finds the first of two sentences with the same id', () async {
      final apple = await add('사과');
      final copy = Sentence(
        id: apple.id,
        targetText: '사과',
        translationText: 'apple',
      );
      provider.sentences.add(copy);

      expect(provider.getSentenceById(apple.id), same(apple));
      provider.sentences.remove(apple);
      expect(provider.getSentenceById(apple.id), same(copy));
    });
  });
}
