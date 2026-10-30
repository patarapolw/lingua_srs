import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/lesson.dart';
import 'package:lingua_srs/models/sentence.dart';
import 'package:lingua_srs/models/srs_card.dart';
import 'package:lingua_srs/models/vocab_item.dart';
import 'package:lingua_srs/providers/app_provider.dart';
import 'package:lingua_srs/services/audio_service.dart';
import 'package:lingua_srs/views/study_view.dart';
import 'package:lingua_srs/views/vocab_edit_dialog.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A study screen must not touch real audio plugins.
class _FakeAudioService extends ChangeNotifier implements AudioService {
  @override
  bool get isPlaying => false;
  @override
  String? get currentlyPlayingKey => null;
  @override
  bool get usesOfflineTts => true;
  @override
  void prefetchAudios(List<String?> urls) {}
  @override
  String getTtsUrl(String text, {String? language}) => '';
  @override
  Future<void> stop() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final storageDirectory = Directory.systemTemp.createTempSync(
    'lingua_srs_review_sentence_refresh_test_',
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

  Future<AppProvider> newProvider() async {
    SharedPreferences.setMockInitialValues({
      'lingua_srs_windows_legacy_migration_complete': true,
      'lingua_srs_lessons': '[]',
      'lingua_srs_sentences': '[]',
    });
    final provider = AppProvider();
    addTearDown(provider.dispose);
    while (provider.isLoading) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    provider.lessons.clear();
    provider.sentences.clear();
    return provider;
  }

  Sentence poolSentence(AppProvider provider, String target) {
    final sentence = Sentence(targetText: target, translationText: target);
    provider.sentences.add(sentence);
    return sentence;
  }

  VocabItem vocabWith(List<Sentence> linked, {String word = 'apple'}) =>
      VocabItem(
        targetWord: word,
        translation: word,
        pos: 'nouns',
        sentenceIds: linked.map((s) => s.id).toList(),
      );

  StudyCardItem itemFor(VocabItem vocab, Sentence? sentence) => StudyCardItem(
    vocab: vocab,
    card: SrsCard(direction: CardDirection.targetToNative),
    lesson: Lesson(title: 'L'),
    sentence: sentence,
  );

  group('AppProvider.refreshSentenceForVocab', () {
    test('keeps the current sentence while it is still linked', () async {
      final provider = await newProvider();
      final a = poolSentence(provider, 'first');
      final b = poolSentence(provider, 'second');
      final vocab = vocabWith([a, b]);

      // Deselecting a sentence that is not on screen leaves the card alone.
      vocab.sentenceIds = [a.id];
      for (var i = 0; i < 20; i++) {
        expect(provider.refreshSentenceForVocab(vocab, a), same(a));
      }
    });

    test('swaps the current sentence out once it is deselected', () async {
      final provider = await newProvider();
      final a = poolSentence(provider, 'first');
      final b = poolSentence(provider, 'second');
      final vocab = vocabWith([a, b]);

      vocab.sentenceIds = [b.id];

      for (var i = 0; i < 20; i++) {
        expect(provider.refreshSentenceForVocab(vocab, a), same(b));
      }
    });

    test('never picks the deselected sentence among several left', () async {
      final provider = await newProvider();
      final a = poolSentence(provider, 'first');
      final b = poolSentence(provider, 'second');
      final c = poolSentence(provider, 'third');
      final vocab = vocabWith([a, b, c]);

      vocab.sentenceIds = [b.id, c.id];

      for (var i = 0; i < 50; i++) {
        final picked = provider.refreshSentenceForVocab(vocab, a);
        expect(picked, anyOf(same(b), same(c)));
      }
    });

    test('swaps the sentence out when it is gone from the pool', () async {
      final provider = await newProvider();
      final a = poolSentence(provider, 'first');
      final b = poolSentence(provider, 'second');
      final vocab = vocabWith([a, b]);

      provider.sentences.remove(a);

      for (var i = 0; i < 20; i++) {
        expect(provider.refreshSentenceForVocab(vocab, a), same(b));
      }
    });

    test('is null when nothing is linked or matches the word', () async {
      final provider = await newProvider();
      final a = poolSentence(provider, 'unrelated');
      final vocab = vocabWith([a]);

      vocab.sentenceIds = [];

      expect(provider.refreshSentenceForVocab(vocab, a), isNull);
    });

    test('falls back to a pool sentence containing the word', () async {
      final provider = await newProvider();
      final a = poolSentence(provider, 'unrelated');
      final fallback = poolSentence(provider, 'I ate an apple');
      final vocab = vocabWith([a]);

      vocab.sentenceIds = [];

      expect(provider.refreshSentenceForVocab(vocab, a), same(fallback));
    });

    test('shows a newly linked sentence on a card that had none', () async {
      final provider = await newProvider();
      final a = poolSentence(provider, 'unrelated');
      final vocab = vocabWith([]);

      vocab.sentenceIds = [a.id];

      expect(provider.refreshSentenceForVocab(vocab, null), same(a));
    });
  });

  group('refreshStaleSentences', () {
    test('replaces the deselected sentence from the current card', () async {
      final provider = await newProvider();
      final a = poolSentence(provider, 'first');
      final b = poolSentence(provider, 'second');
      final vocab = vocabWith([a, b]);
      final answered = itemFor(vocab, a);
      final current = itemFor(vocab, a);
      final requeued = itemFor(vocab, a);
      final queue = [answered, current, requeued];

      vocab.sentenceIds = [b.id];
      final changed = refreshStaleSentences(
        provider: provider,
        queue: queue,
        fromIndex: 1,
        vocab: vocab,
      );

      expect(changed, isTrue);
      expect(current.sentence, same(b));
      expect(requeued.sentence, same(b));
      // A card already answered keeps what was shown when it was answered.
      expect(answered.sentence, same(a));
    });

    test('leaves cards of other vocab alone', () async {
      final provider = await newProvider();
      final a = poolSentence(provider, 'first');
      final b = poolSentence(provider, 'second');
      final vocab = vocabWith([a, b]);
      final other = vocabWith([a, b], word: 'pear');
      final otherItem = itemFor(other, a);
      final current = itemFor(vocab, a);

      vocab.sentenceIds = [b.id];
      refreshStaleSentences(
        provider: provider,
        queue: [current, otherItem],
        fromIndex: 0,
        vocab: vocab,
      );

      expect(current.sentence, same(b));
      expect(otherItem.sentence, same(a));
    });

    test('changes nothing when the shown sentence is still linked', () async {
      final provider = await newProvider();
      final a = poolSentence(provider, 'first');
      final b = poolSentence(provider, 'second');
      final vocab = vocabWith([a, b]);
      final current = itemFor(vocab, a);

      vocab.sentenceIds = [a.id];
      final changed = refreshStaleSentences(
        provider: provider,
        queue: [current],
        fromIndex: 0,
        vocab: vocab,
      );

      expect(changed, isFalse);
      expect(current.sentence, same(a));
    });

    test('drops the sentence when none remain for the word', () async {
      final provider = await newProvider();
      final a = poolSentence(provider, 'unrelated');
      final vocab = vocabWith([a]);
      final current = itemFor(vocab, a);

      vocab.sentenceIds = [];
      final changed = refreshStaleSentences(
        provider: provider,
        queue: [current],
        fromIndex: 0,
        vocab: vocab,
      );

      expect(changed, isTrue);
      expect(current.sentence, isNull);
    });
  });

  group('Editing a card in review', () {
    Future<AppProvider> loadedProvider(WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({
        'lingua_srs_windows_legacy_migration_complete': true,
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

    /// Save when it writes to storage.
    Future<void> saveAndWait(WidgetTester tester) async {
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      for (
        var i = 0;
        i < 50 && find.byType(VocabEditDialog).evaluate().isNotEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pumpAndSettle();
    }

    testWidgets('deselecting the sentence on screen shows the other one', (
      tester,
    ) async {
      final provider = await loadedProvider(tester);
      const yaml =
          '---\nvocabulary:\n  nouns:\n    - ko: 감귤\n      en: tangerine\n'
          '      examples:\n'
          '        - ko: "**감귤** 하나"\n          en: "One tangerine"\n'
          '        - ko: "**감귤** 둘"\n          en: "Two tangerines"\n'
          '---\n# Lesson\n';
      final lesson = (await tester.runAsync(() => provider.importYaml(yaml)))!;
      final vocab = lesson.vocabularies.single;
      final sentences = [
        for (final id in vocab.sentenceIds) provider.getSentenceById(id)!,
      ];
      expect(sentences, hasLength(2));

      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AppProvider>.value(value: provider),
            ChangeNotifierProvider<AudioService>(
              create: (_) => _FakeAudioService(),
            ),
          ],
          child: MaterialApp(home: StudyView(lessonId: lesson.id)),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.tap(find.textContaining('Show Answer'));
      await tester.pumpAndSettle();

      Finder showing(Sentence s) =>
          find.textContaining(s.targetText, findRichText: true);
      // Which of the two the card picked at random.
      final onScreen = sentences.singleWhere(
        (s) => showing(s).evaluate().isNotEmpty,
      );
      final other = sentences.singleWhere((s) => !identical(s, onScreen));

      final toolbarEdit = find.byWidgetPredicate(
        (w) => w is IconButton && (w.tooltip?.startsWith('Edit card') ?? false),
      );
      if (toolbarEdit.evaluate().isNotEmpty) {
        await tester.tap(toolbarEdit);
      } else {
        await tester.tap(find.byTooltip('More'));
        await tester.pumpAndSettle();
        await tester.tap(find.textContaining('Edit card'));
      }
      await tester.pumpAndSettle();
      expect(find.byType(VocabEditDialog), findsOneWidget);

      final unlink = find
          .byTooltip('Unlink from word')
          .at(vocab.sentenceIds.indexOf(onScreen.id));
      await tester.ensureVisible(unlink);
      await tester.tap(unlink);
      await tester.pumpAndSettle();
      await saveAndWait(tester);
      // _disposeAfterRouteExit keeps a 1s timer for the closed dialog.
      await tester.pump(const Duration(seconds: 1));

      expect(vocab.sentenceIds, [other.id]);
      expect(showing(onScreen), findsNothing);
      expect(showing(other), findsWidgets);
    });
  });
}
