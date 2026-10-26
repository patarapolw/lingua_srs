import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/models/ai_discussion_message.dart';
import 'package:lingua_srs/models/lesson.dart';
import 'package:lingua_srs/models/sentence.dart';
import 'package:lingua_srs/models/vocab_item.dart';
import 'package:lingua_srs/models/vocab_merge_record.dart';
import 'package:lingua_srs/providers/app_provider.dart';
import 'package:lingua_srs/services/ai_discussion_search.dart';
import 'package:lingua_srs/services/lesson_ai_prompt.dart';
import 'package:lingua_srs/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _base = DateTime(2026, 1, 10, 12);

AiDiscussionMessage _msg(String role, String content, {int? minutes}) =>
    AiDiscussionMessage(
      role: role,
      content: content,
      createdAt: minutes == null ? null : _base.add(Duration(minutes: minutes)),
    );

VocabItem _word(String id, String ko, String en, {String notes = ''}) =>
    VocabItem(
      id: id,
      targetWord: ko,
      translation: en,
      pos: 'nouns',
      notes: notes,
    );

AiDiscussionSummary _talk(
  String id,
  List<AiDiscussionMessage> messages, {
  VocabItem? vocab,
  Sentence? sentence,
  Lesson? lesson,
}) => AiDiscussionSummary(
  id: id,
  messages: messages,
  vocab: vocab,
  sentence: sentence,
  lesson: lesson,
);

VocabGroup _group(VocabItem vocab) =>
    VocabGroup(id: vocab.id, entry: vocab, reviews: 0);

List<String> _ids(Iterable<AiDiscussionSummary> talks) => [
  for (final talk in talks) talk.id,
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final storageDirectory = Directory.systemTemp.createTempSync(
    'lingua_srs_ai_discussion_test_',
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

  group('AiDiscussionIds', () {
    test('builds a vocabulary discussion id', () {
      expect(AiDiscussionIds.forVocab('v1', 's1'), 'v1:s1');
      expect(AiDiscussionIds.forVocab('v1', null), 'v1:no-sentence');
    });

    test('reads the vocabulary and sentence back', () {
      expect(AiDiscussionIds.vocabIdFrom('v1:s1'), 'v1');
      expect(AiDiscussionIds.sentenceIdFrom('v1:s1'), 's1');
    });

    test('no-sentence means no sentence', () {
      expect(AiDiscussionIds.vocabIdFrom('v1:no-sentence'), 'v1');
      expect(AiDiscussionIds.sentenceIdFrom('v1:no-sentence'), isNull);
    });

    test('splits at the last colon, so explicit ids may hold one', () {
      final id = AiDiscussionIds.forVocab('book:3', 's9');
      expect(id, 'book:3:s9');
      expect(AiDiscussionIds.vocabIdFrom(id), 'book:3');
      expect(AiDiscussionIds.sentenceIdFrom(id), 's9');
    });

    test('an id without a colon is a vocabulary with no sentence', () {
      expect(AiDiscussionIds.vocabIdFrom('v1'), 'v1');
      expect(AiDiscussionIds.sentenceIdFrom('v1'), isNull);
    });

    test('a lesson discussion is about no vocabulary', () {
      final id = LessonAiPrompt.discussionId('L1');
      expect(AiDiscussionIds.vocabIdFrom(id), isNull);
      expect(AiDiscussionIds.sentenceIdFrom(id), isNull);
    });
  });

  group('AiDiscussionSummary', () {
    final apple = _word('v1', '사과', 'apple');
    final lesson = Lesson(title: 'Fruit', vocabularies: [apple]);
    final sentence = Sentence(
      id: 's1',
      targetText: '사과를 먹어요',
      translationText: 'I eat an apple',
    );

    test('resolves the lesson, vocabulary and sentence of a word', () {
      final summary = AiDiscussionSummary.resolve(
        id: 'v1:s1',
        messages: [_msg('user', 'Why?')],
        lessons: [
          Lesson(title: 'Other'),
          lesson,
        ],
        sentenceById: (id) => id == 's1' ? sentence : null,
      );

      expect(summary.vocab, same(apple));
      expect(summary.lesson, same(lesson));
      expect(summary.sentence, same(sentence));
      expect(summary.title, '사과');
      expect(summary.isLesson, isFalse);
      expect(summary.vocabId, 'v1');
    });

    test('does not look a sentence up when there is none', () {
      final asked = <String>[];
      final summary = AiDiscussionSummary.resolve(
        id: 'v1:no-sentence',
        messages: [_msg('user', 'Why?')],
        lessons: [lesson],
        sentenceById: (id) {
          asked.add(id);
          return null;
        },
      );

      expect(summary.sentence, isNull);
      expect(asked, isEmpty);
    });

    test('resolves a lesson discussion', () {
      final summary = AiDiscussionSummary.resolve(
        id: LessonAiPrompt.discussionId(lesson.id),
        messages: [_msg('user', 'Summarise')],
        lessons: [lesson],
        sentenceById: (_) => null,
      );

      expect(summary.isLesson, isTrue);
      expect(summary.lesson, same(lesson));
      expect(summary.vocab, isNull);
      expect(summary.title, lesson.displayTitle);
      expect(summary.vocabId, isNull);
    });

    test('keeps a discussion whose word or lesson was deleted', () {
      final gone = AiDiscussionSummary.resolve(
        id: 'missing:s1',
        messages: [_msg('user', 'Why?')],
        lessons: [lesson],
        sentenceById: (_) => null,
      );
      final goneLesson = AiDiscussionSummary.resolve(
        id: LessonAiPrompt.discussionId('missing'),
        messages: [_msg('user', 'Why?')],
        lessons: [lesson],
        sentenceById: (_) => null,
      );

      expect(gone.vocab, isNull);
      expect(gone.title, 'AI discussion');
      expect(goneLesson.lesson, isNull);
    });

    test('previews the last question and dates the last timed message', () {
      final summary = _talk('v1:s1', [
        _msg('user', 'First question', minutes: 1),
        _msg('assistant', 'Answer', minutes: 2),
        _msg('user', '  Second question  ', minutes: 3),
        _msg('assistant', 'Another answer'),
      ]);

      expect(summary.preview, 'Second question');
      expect(summary.updatedAt, _base.add(const Duration(minutes: 3)));
    });

    test('previews the last message when the learner asked nothing', () {
      expect(_talk('v1:s1', [_msg('assistant', ' Hello ')]).preview, 'Hello');
      expect(_talk('v1:s1', const []).preview, 'No messages');
      expect(_talk('v1:s1', const []).updatedAt, isNull);
    });
  });

  group('AiDiscussionSearch', () {
    final apple = _word('v-apple', '사과', 'apple');
    final appleTree = _word('v-tree', '사과나무', 'apple tree');
    final eat = _word('v-eat', '먹다', 'to eat');
    final school = _word('v-school', '학교', 'school');

    final appleTalk = _talk('v-apple:no-sentence', [
      _msg('user', 'How is this used?', minutes: 10),
      _msg('assistant', 'It is a noun.', minutes: 11),
    ], vocab: apple);
    final eatTalk = _talk('v-eat:no-sentence', [
      _msg('user', 'Is there a polite form?', minutes: 30),
      _msg('assistant', 'Yes, the honorific form is 드시다.', minutes: 31),
    ], vocab: eat);
    final schoolTalk = _talk('v-school:no-sentence', [
      _msg('user', 'What about the tone?', minutes: 20),
    ], vocab: school);

    test('an empty query lists everything, newest first', () {
      final talks = [appleTalk, eatTalk, schoolTalk];

      expect(_ids(AiDiscussionSearch.search('', talks)), [
        eatTalk.id,
        schoolTalk.id,
        appleTalk.id,
      ]);
      expect(_ids(AiDiscussionSearch.search('   ', talks)), [
        eatTalk.id,
        schoolTalk.id,
        appleTalk.id,
      ]);
    });

    test('discussions without a time come last', () {
      final untimed = _talk('v-x:no-sentence', [_msg('user', 'Hi')]);

      expect(_ids(AiDiscussionSearch.search('', [untimed, appleTalk])), [
        appleTalk.id,
        untimed.id,
      ]);
    });

    test('finds a discussion by its Korean word', () {
      final found = AiDiscussionSearch.search('학교', [
        appleTalk,
        eatTalk,
        schoolTalk,
      ]);

      expect(_ids(found), [schoolTalk.id]);
    });

    test('an exact Korean word ranks above one that only contains it', () {
      final treeTalk = _talk('v-tree:no-sentence', [
        _msg('user', 'Why?', minutes: 99),
      ], vocab: appleTree);

      final found = AiDiscussionSearch.search('사과', [treeTalk, appleTalk]);

      expect(_ids(found), [appleTalk.id, treeTalk.id]);
    });

    test('finds another form of a Korean word', () {
      final found = AiDiscussionSearch.search('먹었습니다', [appleTalk, eatTalk]);

      expect(_ids(found), [eatTalk.id]);
    });

    test('finds a discussion by the meaning in English', () {
      expect(_ids(AiDiscussionSearch.search('apple', [appleTalk, eatTalk])), [
        appleTalk.id,
      ]);
      expect(_ids(AiDiscussionSearch.search('eat', [appleTalk, eatTalk])), [
        eatTalk.id,
      ]);
    });

    test('finds words that were only said in the conversation', () {
      final talks = [appleTalk, eatTalk, schoolTalk];

      expect(_ids(AiDiscussionSearch.search('honorific', talks)), [eatTalk.id]);
      expect(_ids(AiDiscussionSearch.search('HONORIFIC', talks)), [eatTalk.id]);
      expect(_ids(AiDiscussionSearch.search('드시다', talks)), [eatTalk.id]);
    });

    test('several words must all appear in one message', () {
      final talks = [appleTalk, eatTalk];

      expect(_ids(AiDiscussionSearch.search('how used', talks)), [
        appleTalk.id,
      ]);
      // "noun" and "used" are said in different messages.
      expect(AiDiscussionSearch.search('noun used', talks), isEmpty);
    });

    test('a word or meaning ranks above something said about it', () {
      final mentionsEat = _talk('v-school:other', [
        _msg('user', 'Does this go with eat?', minutes: 500),
      ], vocab: school);

      final found = AiDiscussionSearch.search('eat', [mentionsEat, eatTalk]);

      expect(_ids(found), [eatTalk.id, mentionsEat.id]);
    });

    test('what the learner asked ranks above what the AI answered', () {
      final asked = _talk('v-a:no-sentence', [
        _msg('user', 'Explain the nuance', minutes: 1),
      ]);
      final answered = _talk('v-b:no-sentence', [
        _msg('assistant', 'The nuance is subtle.', minutes: 900),
      ]);

      final found = AiDiscussionSearch.search('nuance', [answered, asked]);

      expect(_ids(found), [asked.id, answered.id]);
    });

    test('finds a discussion by its sentence when the word is gone', () {
      final orphan = _talk(
        'deleted:s1',
        [_msg('user', 'Why?')],
        sentence: Sentence(
          id: 's1',
          targetText: '저는 사과를 먹어요',
          translationText: 'I eat an apple',
        ),
      );

      expect(_ids(AiDiscussionSearch.search('먹어요', [orphan, appleTalk])), [
        orphan.id,
      ]);
      expect(_ids(AiDiscussionSearch.search('an apple', [orphan, eatTalk])), [
        orphan.id,
      ]);
    });

    test('finds a lesson discussion by the lesson title', () {
      final lesson = Lesson(title: 'Food words');
      final lessonTalk = _talk(LessonAiPrompt.discussionId(lesson.id), [
        _msg('user', 'Summarise'),
      ], lesson: lesson);

      final found = AiDiscussionSearch.search('food', [lessonTalk, appleTalk]);

      expect(_ids(found), [lessonTalk.id]);
    });

    test('nothing matches a word that was never mentioned', () {
      expect(
        AiDiscussionSearch.search('zebra', [appleTalk, eatTalk, schoolTalk]),
        isEmpty,
      );
    });

    test('a query of only punctuation does not throw', () {
      expect(
        () => AiDiscussionSearch.search('?!', [appleTalk, eatTalk]),
        returnsNormally,
      );
    });
  });

  group('AiDiscussionSuggestions', () {
    final apple = _word('v1', '사과', 'apple');
    final appleForm = _word('v5', '사과를', 'apple');
    final appleTwin = _word('v2', '애플', 'apple');
    final school = _word('v3', '학교', 'school');
    final groups = [apple, appleForm, appleTwin, school].map(_group).toList();

    AiDiscussionSummary talk(String id, int minutes, {VocabItem? vocab}) =>
        _talk(id, [
          _msg('user', 'Question for $id', minutes: minutes),
        ], vocab: vocab);

    final older = talk('v1:s1', 10, vocab: apple);
    final newer = talk('v1:s2', 20, vocab: apple);
    final twinNew = talk('v2:s1', 30, vocab: appleTwin);
    final twinOld = talk('v2:s2', 5, vocab: appleTwin);
    final formTalk = talk('v5:s1', 1, vocab: appleForm);
    final unrelated = talk('v3:s1', 40, vocab: school);
    final empty = _talk('v1:s9', const [], vocab: apple);
    final lessonTalk = _talk(LessonAiPrompt.discussionId('L1'), [
      _msg('user', 'Summarise', minutes: 50),
    ]);
    final all = [
      older,
      newer,
      twinNew,
      twinOld,
      formTalk,
      unrelated,
      empty,
      lessonTalk,
    ];

    List<AiDiscussionSuggestion> suggest(
      String id, {
      List<VocabGroup>? groupList,
      int limit = 6,
    }) => AiDiscussionSuggestions.forDiscussion(
      discussionId: id,
      groups: groupList ?? groups,
      discussions: all,
      limit: limit,
    );

    test('other sentences of the same word come first, newest first', () {
      final result = suggest('v1:s3');

      expect(result.take(2).map((s) => s.discussion.id), ['v1:s2', 'v1:s1']);
      expect(result.take(2).every((s) => s.sameWord), isTrue);
      expect(result.first.label, 'Same word');
    });

    test('then the latest discussion of each related word, closest first', () {
      final result = suggest('v1:s3');

      // A form of the same word beats a word with the same meaning.
      expect(result.skip(2).map((s) => s.discussion.id), ['v5:s1', 'v2:s1']);
      expect(result[2].label, 'Similar word');
      expect(result[3].label, 'Same meaning');
      expect(result.skip(2).every((s) => !s.sameWord), isTrue);
    });

    test('never suggests the discussion being opened', () {
      final ids = suggest('v1:s1').map((s) => s.discussion.id);

      expect(ids, isNot(contains('v1:s1')));
      expect(ids, contains('v1:s2'));
    });

    test('skips empty threads, lesson threads and unrelated words', () {
      final ids = suggest('v1:s3').map((s) => s.discussion.id).toList();

      expect(ids, isNot(contains('v1:s9')));
      expect(ids, isNot(contains(lessonTalk.id)));
      expect(ids, isNot(contains('v3:s1')));
      expect(ids, isNot(contains('v2:s2')));
    });

    test('keeps the limit', () {
      expect(suggest('v1:s3', limit: 2).map((s) => s.discussion.id), [
        'v1:s2',
        'v1:s1',
      ]);
      expect(suggest('v1:s3', limit: 0), isEmpty);
    });

    test('offers nothing for a lesson discussion', () {
      expect(suggest(LessonAiPrompt.discussionId('L1')), isEmpty);
    });

    test('still offers the same word when it is no longer in the groups', () {
      final result = suggest(
        'v1:s3',
        groupList: groups.where((group) => group.id != 'v1').toList(),
      );

      expect(result.map((s) => s.discussion.id), ['v1:s2', 'v1:s1']);
    });

    test('an unrelated word gets only its own discussions', () {
      final result = suggest('v3:s2');

      expect(result.map((s) => s.discussion.id), ['v3:s1']);
    });
  });

  group('merging vocabulary', () {
    final t1 = _base.add(const Duration(minutes: 1));
    final t2 = _base.add(const Duration(minutes: 2));
    final t3 = _base.add(const Duration(minutes: 3));

    AiDiscussionMessage at(String text, DateTime? time) =>
        AiDiscussionMessage(role: 'user', content: text, createdAt: time);

    Future<AppProvider> providerWith(
      Map<String, List<AiDiscussionMessage>> discussions,
    ) async {
      SharedPreferences.setMockInitialValues({
        'lingua_srs_windows_legacy_migration_complete': true,
        'lingua_srs_lessons': '[]',
        'lingua_srs_sentences': '[]',
      });
      await StorageService.saveAiDiscussions(discussions);
      final provider = AppProvider();
      while (provider.isLoading) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      provider.lessons
        ..clear()
        ..add(
          Lesson(
            title: 'Fruit',
            vocabularies: [
              _word('a', '사과', 'apple'),
              _word('b', '애플', 'apple'),
              _word('c', '학교', 'school'),
            ],
          ),
        );
      return provider;
    }

    Future<void> merge(AppProvider provider) =>
        provider.mergeVocab(survivorId: 'a', absorbedIds: ['b']);

    test('moves the discussions of a merged word to the survivor', () async {
      final provider = await providerWith({
        'b:s1': [at('about b', t1)],
        'b:no-sentence': [at('no sentence', t2)],
      });

      await merge(provider);

      final saved = provider.aiDiscussions;
      expect(saved.keys, unorderedEquals(['a:s1', 'a:no-sentence']));
      expect(saved['a:s1']!.single.content, 'about b');
      expect(saved['a:no-sentence']!.single.content, 'no sentence');
    });

    test(
      'joins threads about the same sentence, oldest message first',
      () async {
        final provider = await providerWith({
          'a:s1': [at('first', t1), at('third', t3)],
          'b:s1': [at('second', t2)],
        });

        await merge(provider);

        expect(provider.aiDiscussions.keys, ['a:s1']);
        expect(provider.aiDiscussions['a:s1']!.map((m) => m.content), [
          'first',
          'second',
          'third',
        ]);
      },
    );

    test('appends instead of sorting when a message has no time', () async {
      final provider = await providerWith({
        'a:s1': [at('kept', null)],
        'b:s1': [at('moved', t1)],
      });

      await merge(provider);

      expect(provider.aiDiscussions['a:s1']!.map((m) => m.content), [
        'kept',
        'moved',
      ]);
    });

    test('leaves other words and lesson discussions alone', () async {
      final provider = await providerWith({
        'b:s1': [at('about b', t1)],
        'c:s1': [at('about c', t1)],
        'lesson:b': [at('lesson whose id starts like b', t1)],
      });

      await merge(provider);

      expect(
        provider.aiDiscussions.keys,
        unorderedEquals(['a:s1', 'c:s1', 'lesson:b']),
      );
    });

    test('saves the moved discussions', () async {
      final provider = await providerWith({
        'b:s1': [at('about b', t1)],
      });

      await merge(provider);

      final stored = await StorageService.loadAiDiscussions();
      expect(stored.keys, ['a:s1']);
    });

    test('merged discussions find their word again', () async {
      final provider = await providerWith({
        'b:s1': [at('about b', t1)],
      });
      expect(provider.aiDiscussionSummaries.single.vocab, isNotNull);

      await merge(provider);

      final summary = provider.aiDiscussionSummaries.single;
      expect(summary.id, 'a:s1');
      expect(summary.vocab?.id, 'a');
      expect(
        AiDiscussionSearch.search('사과', provider.aiDiscussionSummaries),
        hasLength(1),
      );
    });

    test('merging words without discussions changes none', () async {
      final provider = await providerWith({
        'c:s1': [at('about c', t1)],
      });

      await merge(provider);

      expect(provider.aiDiscussions.keys, ['c:s1']);
    });
  });

  group('AppProvider.relatedAiDiscussions', () {
    test('suggests the same word and related words from saved talks', () async {
      SharedPreferences.setMockInitialValues({
        'lingua_srs_windows_legacy_migration_complete': true,
        'lingua_srs_lessons': '[]',
        'lingua_srs_sentences': '[]',
      });
      await StorageService.saveAiDiscussions({
        'a:old': [_msg('user', 'Earlier about a', minutes: 1)],
        'b:old': [_msg('user', 'Earlier about b', minutes: 2)],
        'c:old': [_msg('user', 'Earlier about c', minutes: 3)],
      });
      final provider = AppProvider();
      while (provider.isLoading) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      provider.lessons
        ..clear()
        ..add(
          Lesson(
            title: 'Fruit',
            vocabularies: [
              _word('a', '사과', 'apple'),
              _word('b', '애플', 'apple'),
              _word('c', '학교', 'school'),
            ],
          ),
        );

      final result = provider.relatedAiDiscussions('a:new');

      expect(result.map((s) => s.discussion.id), ['a:old', 'b:old']);
      expect(result.map((s) => s.label), ['Same word', 'Same meaning']);
    });
  });
}
