import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/typed_question.dart';
import 'package:lingua_srs/providers/app_provider.dart';
import 'package:lingua_srs/services/storage_service.dart';
import 'package:lingua_srs/services/sync_records.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'secret_storage_mock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(setUpSecretStorage);

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

  tearDown(() {
    provider.dispose();
  });

  Future<void> ask(String question, String word) =>
      provider.recordTypedQuestion(
        question: question,
        subject: word,
        language: 'ko',
        scope: TypedQuestionScope.word,
        now: DateTime.utc(2026, 11, 1),
      );

  test('keeps a typed question, saves it and syncs it', () async {
    await ask('Is 먹다 formal or casual?', '먹다');
    await ask('Is 가다 formal or casual?', '가다');

    final question = provider.typedQuestions.values.single;
    expect(question.template, 'Is {word} formal or casual?');
    expect(question.uses, 2);

    final saved = await StorageService.loadTypedQuestions();
    expect(saved.values.single.toJson(), question.toJson());

    final records = provider.syncSnapshot('device-a');
    final key = SyncRecordKey(
      SyncKinds.question,
      provider.typedQuestions.keys.single,
    );
    expect(records[key], question.toJson());
  });

  test('does not keep a question about one card', () async {
    await ask('What does 맛있게 mean here?', '먹다');
    expect(provider.typedQuestions, isEmpty);
  });

  test('removes a typed question so it is no longer offered', () async {
    await ask('Is 먹다 formal or casual?', '먹다');
    final id = provider.typedQuestions.keys.single;

    await provider.removeTypedQuestion(id);

    expect(provider.typedQuestions, isEmpty);
    expect(await StorageService.loadTypedQuestions(), isEmpty);
    expect(
      provider.syncSnapshot('device-a').keys.map((key) => key.kind),
      isNot(contains(SyncKinds.question)),
    );
  });
}
