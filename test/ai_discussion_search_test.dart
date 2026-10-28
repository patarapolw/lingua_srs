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
    test('builds one vocabulary discussion id, whatever the sentence', () {
      expect(AiDiscussionIds.forVocab('v1'), 'v1:no-sentence');
    });

    test('canonical maps a per-sentence id onto the vocabulary one', () {
      expect(AiDiscussionIds.canonical('v1:s1'), 'v1:no-sentence');
      expect(AiDiscussionIds.canonical('v1:no-sentence'), 'v1:no-sentence');
      expect(AiDiscussionIds.canonical('book:3:s9'), 'book:3:no-sentence');
      expect(
        AiDiscussionIds.canonical('book:3:no-sentence'),
        'book:3:no-sentence',
      );
    });

    test('canonical leaves a lesson discussion alone', () {
      final id = LessonAiPrompt.discussionId('L1');
      expect(AiDiscussionIds.canonical(id), id);
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
      const id = 'book:3:s9';
      expect(AiDiscussionIds.vocabIdFrom(id), 'book:3');
      expect(AiDiscussionIds.sentenceIdFrom(id), 's9');
      expect(AiDiscussionIds.forVocab('book:3'), 'book:3:no-sentence');
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

  group('AiDiscussionMessages.join', () {
    final base = DateTime.utc(2026, 1, 1);
    AiDiscussionMessage at(String content, int minutes) => AiDiscussionMessage(
      role: 'user',
      content: content,
      createdAt: base.add(Duration(minutes: minutes)),
    );

    test('puts dated messages oldest first across threads', () {
      final joined = AiDiscussionMessages.join([
        [at('b', 2), at('d', 4)],
        [at('a', 1), at('c', 3)],
      ]);
      expect(joined.map((m) => m.content), ['a', 'b', 'c', 'd']);
    });

    test('keeps the given order for equal times', () {
      final joined = AiDiscussionMessages.join([
        [at('first', 1)],
        [at('second', 1)],
      ]);
      expect(joined.map((m) => m.content), ['first', 'second']);
    });

    test('keeps threads whole when a message has no time', () {
      const untimed = AiDiscussionMessage(role: 'user', content: 'untimed');
      final joined = AiDiscussionMessages.join([
        [at('late', 9)],
        [untimed, at('early', 1)],
      ]);
      expect(joined.map((m) => m.content), ['late', 'untimed', 'early']);
    });

    test('joining nothing gives an empty conversation', () {
      expect(AiDiscussionMessages.join(const []), isEmpty);
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
      expect(gone.title, 'Word not found');
      expect(goneLesson.lesson, isNull);
      expect(goneLesson.title, 'Lesson not found');
    });

    test('knows which discussions have lost their word or lesson', () {
      AiDiscussionSummary resolve(String id) => AiDiscussionSummary.resolve(
        id: id,
        messages: [_msg('user', 'Why?')],
        lessons: [lesson],
        sentenceById: (_) => null,
      );

      expect(resolve('v1:s1').isOrphaned, isFalse);
      expect(resolve('missing:s1').isOrphaned, isTrue);
      expect(
        resolve(LessonAiPrompt.discussionId(lesson.id)).isOrphaned,
        isFalse,
      );
      expect(
        resolve(LessonAiPrompt.discussionId('missing')).isOrphaned,
        isTrue,
      );
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

  group('OrphanedAiPrompt', () {
    test('tells the AI the lesson is gone and not to guess at it', () {
      final prompt = OrphanedAiPrompt.forLesson(
        targetLanguage: 'ko',
        nativeLanguage: 'en',
      );

      expect(prompt, contains('studying ko with en support'));
      expect(prompt, contains('lesson that is no longer available'));
      expect(prompt, contains('instead of guessing'));
      expect(prompt, contains('Markdown'));
    });

    test('tells the AI the word is gone', () {
      final prompt = OrphanedAiPrompt.forWord(
        targetLanguage: 'ko',
        nativeLanguage: 'en',
      );

      expect(prompt, contains('vocabulary word that is no longer available'));
      expect(prompt, contains('instead of guessing'));
      expect(prompt, isNot(contains('lesson that is no longer')));
    });
  });

  group('AiDiscussionRelated', () {
    final apple = _word('v1', '사과', 'apple');
    final appleForm = _word('v5', '사과를', 'apple');
    final appleTwin = _word('v2', '애플', 'apple');
    final school = _word('v3', '학교', 'school');
    final groups = [apple, appleForm, appleTwin, school].map(_group).toList();

    AiDiscussionSummary talk(
      String id,
      int minutes, {
      VocabItem? vocab,
      String? said,
    }) => _talk(id, [
      _msg('user', said ?? 'Question for $id', minutes: minutes),
    ], vocab: vocab);

    final same = talk('v1:s1', 10, vocab: apple);
    final twin = talk('v2:s1', 30, vocab: appleTwin);
    final schoolTalk = talk('v3:s1', 40, vocab: school);
    final mention = talk('v3:s2', 3, vocab: school, said: 'Compare it with 사과');
    final empty = _talk('v1:s9', const [], vocab: apple);
    final lessonTalk = _talk(LessonAiPrompt.discussionId('L1'), [
      _msg('user', 'Summarise', minutes: 50),
    ]);
    final all = [same, twin, schoolTalk, mention, empty, lessonTalk];

    List<AiDiscussionSuggestion> panel(
      String query, {
      String id = 'v1:s3',
      int limit = 30,
    }) => AiDiscussionRelated.forPanel(
      discussionId: id,
      query: query,
      suggestedQuery: '사과',
      groups: groups,
      discussions: all,
      limit: limit,
    );

    List<String> idsOf(List<AiDiscussionSuggestion> list) => [
      for (final suggestion in list) suggestion.discussion.id,
    ];

    test('starts with the suggestions, then others that mention the word', () {
      final result = panel('사과');

      expect(idsOf(result), ['v1:s1', 'v2:s1', 'v3:s2']);
      expect(result.map((s) => s.label), ['Same word', 'Same meaning', null]);
    });

    test('lists a discussion once even when it is also a search hit', () {
      final ids = idsOf(panel('사과'));

      expect(ids.toSet(), hasLength(ids.length));
    });

    test('once the box is edited it is a plain search', () {
      final result = panel('school');

      expect(idsOf(result), ['v3:s1', 'v3:s2']);
      expect(result.every((s) => s.label == null), isTrue);
    });

    test('an emptied box lists everything else, newest first', () {
      expect(idsOf(panel('')), [
        lessonTalk.id,
        'v3:s1',
        'v2:s1',
        'v1:s1',
        'v3:s2',
      ]);
    });

    test('spaces around the suggested word do not count as an edit', () {
      expect(idsOf(panel('  사과 ')), idsOf(panel('사과')));
    });

    test('never lists the discussion being viewed or an empty one', () {
      final ids = idsOf(panel('', id: 'v1:s1'));

      expect(ids, isNot(contains('v1:s1')));
      expect(ids, isNot(contains('v1:s9')));
    });

    test('keeps the limit', () {
      expect(panel('', limit: 2), hasLength(2));
      expect(panel('사과', limit: 1), hasLength(1));
    });

    test('says nothing when nothing matches', () {
      expect(panel('zebra'), isEmpty);
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
        'b:no-sentence': [at('about b', t1)],
      });

      await merge(provider);

      final saved = provider.aiDiscussions;
      expect(saved.keys, ['a:no-sentence']);
      expect(saved['a:no-sentence']!.single.content, 'about b');
    });

    test('joins the threads of both words, oldest message first', () async {
      final provider = await providerWith({
        'a:no-sentence': [at('first', t1), at('third', t3)],
        'b:no-sentence': [at('second', t2)],
      });

      await merge(provider);

      expect(provider.aiDiscussions.keys, ['a:no-sentence']);
      expect(provider.aiDiscussions['a:no-sentence']!.map((m) => m.content), [
        'first',
        'second',
        'third',
      ]);
    });

    test('appends instead of sorting when a message has no time', () async {
      final provider = await providerWith({
        'a:no-sentence': [at('kept', null)],
        'b:no-sentence': [at('moved', t1)],
      });

      await merge(provider);

      expect(provider.aiDiscussions['a:no-sentence']!.map((m) => m.content), [
        'kept',
        'moved',
      ]);
    });

    test('leaves other words and lesson discussions alone', () async {
      final provider = await providerWith({
        'b:no-sentence': [at('about b', t1)],
        'c:no-sentence': [at('about c', t1)],
        'lesson:b': [at('lesson whose id starts like b', t1)],
      });

      await merge(provider);

      expect(
        provider.aiDiscussions.keys,
        unorderedEquals(['a:no-sentence', 'c:no-sentence', 'lesson:b']),
      );
    });

    test('saves the moved discussions', () async {
      final provider = await providerWith({
        'b:no-sentence': [at('about b', t1)],
      });

      await merge(provider);

      final stored = await StorageService.loadAiDiscussions();
      expect(stored.keys, ['a:no-sentence']);
    });

    test('merged discussions find their word again', () async {
      final provider = await providerWith({
        'b:no-sentence': [at('about b', t1)],
      });
      expect(provider.aiDiscussionSummaries.single.vocab, isNotNull);

      await merge(provider);

      final summary = provider.aiDiscussionSummaries.single;
      expect(summary.id, 'a:no-sentence');
      expect(summary.vocab?.id, 'a');
      expect(
        AiDiscussionSearch.search('사과', provider.aiDiscussionSummaries),
        hasLength(1),
      );
    });

    test('merging words without discussions changes none', () async {
      final provider = await providerWith({
        'c:no-sentence': [at('about c', t1)],
      });

      await merge(provider);

      expect(provider.aiDiscussions.keys, ['c:no-sentence']);
    });
  });

  group('a word that gets a new id', () {
    final t1 = _base.add(const Duration(minutes: 1));
    final t2 = _base.add(const Duration(minutes: 2));
    final t3 = _base.add(const Duration(minutes: 3));

    AiDiscussionMessage at(String text, DateTime? time) =>
        AiDiscussionMessage(role: 'user', content: text, createdAt: time);

    Future<AppProvider> providerWith(
      Map<String, List<AiDiscussionMessage>> discussions,
      List<Lesson> lessons,
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
        ..addAll(lessons);
      return provider;
    }

    const fruitYaml =
        '---\nvocabulary:\n  nouns:\n    - ko: 사과\n      en: apple\n---\n# Fruit\n';
    const editedYaml =
        '---\nvocabulary:\n  nouns:\n    - ko: 사과\n      en: apple fruit\n---\n# Fruit\n';
    const headwordYaml =
        '---\nvocabulary:\n  nouns:\n    - ko: 능금\n      en: apple\n---\n# Fruit\n';
    const bothYaml =
        '---\nvocabulary:\n  nouns:\n    - ko: 능금\n      en: crab apple\n---\n# Fruit\n';

    test('editing the id of a word moves its discussions', () async {
      final apple = _word('a', '사과', 'apple');
      final provider = await providerWith(
        {
          'a:no-sentence': [at('about a', t1)],
        },
        [
          Lesson(title: 'Fruit', vocabularies: [apple]),
        ],
      );

      apple
        ..id = 'fruit-apple'
        ..idIsExplicit = true;
      await provider.updateVocab(apple, previousId: 'a');

      expect(provider.aiDiscussions.keys, ['fruit-apple:no-sentence']);
      expect(
        provider.aiDiscussions['fruit-apple:no-sentence']!.single.content,
        'about a',
      );
    });

    test('saves the moved discussions', () async {
      final apple = _word('a', '사과', 'apple');
      final provider = await providerWith(
        {
          'a:no-sentence': [at('about a', t1)],
        },
        [
          Lesson(title: 'Fruit', vocabularies: [apple]),
        ],
      );

      apple.id = 'renamed';
      await provider.updateVocab(apple, previousId: 'a');

      expect((await StorageService.loadAiDiscussions()).keys, [
        'renamed:no-sentence',
      ]);
    });

    test('a found word still resolves from its moved discussion', () async {
      final apple = _word('a', '사과', 'apple');
      final provider = await providerWith(
        {
          'a:no-sentence': [at('about a', t1)],
        },
        [
          Lesson(title: 'Fruit', vocabularies: [apple]),
        ],
      );

      apple.id = 'renamed';
      await provider.updateVocab(apple, previousId: 'a');

      final summary = provider.aiDiscussionSummaries.single;
      expect(summary.vocab, same(apple));
      expect(AiDiscussionSearch.search('사과', [summary]), hasLength(1));
    });

    test('the same word in another lesson keeps the old id and its chats', () async {
      final here = _word('a', '사과', 'apple');
      final there = _word('a', '사과', 'apple');
      final provider = await providerWith(
        {
          'a:no-sentence': [at('about a', t1)],
        },
        [
          Lesson(title: 'One', vocabularies: [here]),
          Lesson(title: 'Two', vocabularies: [there]),
        ],
      );

      // An explicit id is kept, so this word really is split off from `there`.
      here
        ..id = 'split-off'
        ..idIsExplicit = true;
      await provider.updateVocab(here, previousId: 'a');
      expect(here.id, 'split-off');

      expect(provider.aiDiscussions.keys, ['a:no-sentence']);
    });

    test('adopting the id of another word joins their chats', () async {
      final a = _word('a', '사과', 'apple');
      final b = _word('b', '애플', 'apple');
      final provider = await providerWith(
        {
          'a:no-sentence': [at('first', t1), at('third', t3)],
          'b:no-sentence': [at('second', t2)],
        },
        [
          Lesson(title: 'Fruit', vocabularies: [a, b]),
        ],
      );

      b.id = 'a';
      await provider.updateVocab(b, previousId: 'b');

      expect(provider.aiDiscussions.keys, ['a:no-sentence']);
      expect(provider.aiDiscussions['a:no-sentence']!.map((m) => m.content), [
        'first',
        'second',
        'third',
      ]);
    });

    test('does not move chats when another word took the old id', () async {
      final a = _word('a', '사과', 'apple');
      final b = _word('b', '애플', 'apple');
      final provider = await providerWith(
        {
          'a:no-sentence': [at('about a', t1)],
          'b:no-sentence': [at('about b', t2)],
        },
        [
          Lesson(title: 'Fruit', vocabularies: [a, b]),
        ],
      );

      a.id = 'b';
      b.id = 'a';
      await provider.updateVocab(a, previousId: 'a');

      expect(
        provider.aiDiscussions['a:no-sentence']!.single.content,
        'about a',
      );
      expect(
        provider.aiDiscussions['b:no-sentence']!.single.content,
        'about b',
      );
    });

    test('leaves other words and lesson chats alone', () async {
      final a = _word('a', '사과', 'apple');
      final c = _word('c', '학교', 'school');
      final provider = await providerWith(
        {
          'a:no-sentence': [at('about a', t1)],
          'c:no-sentence': [at('about c', t2)],
          'lesson:a': [at('lesson whose id starts like a', t3)],
        },
        [
          Lesson(title: 'Fruit', vocabularies: [a, c]),
        ],
      );

      a.id = 'renamed';
      await provider.updateVocab(a, previousId: 'a');

      expect(
        provider.aiDiscussions.keys,
        unorderedEquals(['renamed:no-sentence', 'c:no-sentence', 'lesson:a']),
      );
    });

    test(
      'editing a word then re-importing the lesson keeps its chats',
      () async {
        final provider = await providerWith(const {}, const []);
        final lesson = await provider.importYaml(fruitYaml);
        final vocab = lesson.vocabularies.single;
        final oldId = vocab.id;
        await provider.addAiDiscussionMessage(
          AiDiscussionIds.forVocab(oldId),
          at('about apple', t1),
        );

        // Editing in the dialog leaves the id alone...
        vocab.translation = 'apple fruit';
        await provider.updateVocab(vocab, previousId: oldId);
        expect(vocab.id, oldId);
        expect(provider.aiDiscussions.keys, [AiDiscussionIds.forVocab(oldId)]);

        // ...but importing the same text again matches it by meaning and gives
        // it the id of the edited text.
        await provider.importYaml(editedYaml);

        final newId = provider.lessons.single.vocabularies.single.id;
        expect(newId, isNot(oldId));
        expect(provider.aiDiscussions.keys, [AiDiscussionIds.forVocab(newId)]);
        final summary = provider.aiDiscussionSummaries.single;
        expect(summary.vocab?.translation, 'apple fruit');
      },
    );

    test(
      'editing the Korean headword then re-importing keeps the chats',
      () async {
        final provider = await providerWith(const {}, const []);
        final lesson = await provider.importYaml(fruitYaml);
        final vocab = lesson.vocabularies.single;
        final oldId = vocab.id;
        await provider.addAiDiscussionMessage(
          AiDiscussionIds.forVocab(oldId),
          at('about apple', t1),
        );

        vocab.targetWord = '능금';
        await provider.updateVocab(vocab, previousId: oldId);
        // Like the translation, the headword does not change the id by itself.
        expect(vocab.id, oldId);
        expect(provider.aiDiscussions.keys, [AiDiscussionIds.forVocab(oldId)]);

        await provider.importYaml(headwordYaml);

        final newId = provider.lessons.single.vocabularies.single.id;
        expect(newId, isNot(oldId));
        expect(provider.aiDiscussions.keys, [AiDiscussionIds.forVocab(newId)]);
        final summary = provider.aiDiscussionSummaries.single;
        expect(summary.vocab?.targetWord, '능금');
        // ...and the chat is found by the new headword, not the old one.
        expect(AiDiscussionSearch.search('능금', [summary]), hasLength(1));
        expect(AiDiscussionSearch.search('사과', [summary]), isEmpty);
      },
    );

    test(
      'editing the headword and the translation together keeps the chats',
      () async {
        final provider = await providerWith(const {}, const []);
        final lesson = await provider.importYaml(fruitYaml);
        final vocab = lesson.vocabularies.single;
        final oldId = vocab.id;
        await provider.addAiDiscussionMessage(
          AiDiscussionIds.forVocab(oldId),
          at('about apple', t1),
        );

        vocab
          ..targetWord = '능금'
          ..translation = 'crab apple';
        await provider.updateVocab(vocab, previousId: oldId);
        await provider.importYaml(bothYaml);

        final newId = provider.lessons.single.vocabularies.single.id;
        expect(newId, isNot(oldId));
        expect(provider.aiDiscussions.keys, [AiDiscussionIds.forVocab(newId)]);
        final summary = provider.aiDiscussionSummaries.single;
        expect(summary.vocab?.targetWord, '능금');
        expect(summary.vocab?.translation, 'crab apple');
      },
    );

    test(
      'a headword edited in the dialog keeps its chats with no re-import',
      () async {
        final provider = await providerWith(const {}, const []);
        final lesson = await provider.importYaml(fruitYaml);
        final vocab = lesson.vocabularies.single;
        await provider.addAiDiscussionMessage(
          AiDiscussionIds.forVocab(vocab.id),
          at('about apple', t1),
        );

        vocab
          ..targetWord = '능금'
          ..translation = 'crab apple';
        await provider.updateVocab(vocab, previousId: vocab.id);

        final summary = provider.aiDiscussionSummaries.single;
        expect(summary.isOrphaned, isFalse);
        expect(summary.title, '능금');
      },
    );

    test('importing unchanged text again changes nothing', () async {
      final provider = await providerWith(const {}, const []);
      final lesson = await provider.importYaml(fruitYaml);
      final id = lesson.vocabularies.single.id;
      await provider.addAiDiscussionMessage(
        AiDiscussionIds.forVocab(id),
        at('about apple', t1),
      );

      await provider.importYaml(fruitYaml);

      expect(provider.aiDiscussions.keys, [AiDiscussionIds.forVocab(id)]);
    });
  });

  group('discussions saved per sentence', () {
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
      return provider;
    }

    test('are joined into one discussion per word on load', () async {
      final provider = await providerWith({
        'a:s1': [at('first', t1), at('third', t3)],
        'a:s2': [at('second', t2)],
        'b:s1': [at('about b', t1)],
      });

      expect(
        provider.aiDiscussions.keys,
        unorderedEquals(['a:no-sentence', 'b:no-sentence']),
      );
      expect(provider.aiDiscussions['a:no-sentence']!.map((m) => m.content), [
        'first',
        'second',
        'third',
      ]);
      expect(
        provider.aiDiscussions['b:no-sentence']!.single.content,
        'about b',
      );
    });

    test('join the discussion that had no sentence', () async {
      final provider = await providerWith({
        'a:no-sentence': [at('first', t1)],
        'a:s1': [at('second', t2)],
      });

      expect(provider.aiDiscussions.keys, ['a:no-sentence']);
      expect(provider.aiDiscussions['a:no-sentence']!.map((m) => m.content), [
        'first',
        'second',
      ]);
    });

    test('are saved joined, so the next start has nothing to join', () async {
      await providerWith({
        'a:s1': [at('first', t1)],
        'a:s2': [at('second', t2)],
      });

      final stored = await StorageService.loadAiDiscussions();
      expect(stored.keys, ['a:no-sentence']);
      expect(stored['a:no-sentence']!.map((m) => m.content), [
        'first',
        'second',
      ]);
    });

    test('keep a word whose id holds a colon', () async {
      final provider = await providerWith({
        'book:3:s1': [at('first', t1)],
        'book:3:s2': [at('second', t2)],
      });

      expect(provider.aiDiscussions.keys, ['book:3:no-sentence']);
    });

    test('leave lesson discussions and joined ones alone', () async {
      final provider = await providerWith({
        'lesson:L1': [at('about the lesson', t1)],
        'a:no-sentence': [at('about a', t2)],
      });

      expect(
        provider.aiDiscussions.keys,
        unorderedEquals(['lesson:L1', 'a:no-sentence']),
      );
    });

    test('are one discussion to the list and the search', () async {
      final provider = await providerWith({
        'a:s1': [at('about 사과 here', t1)],
        'a:s2': [at('about 사과 there', t2)],
      });
      provider.lessons.add(
        Lesson(title: 'Fruit', vocabularies: [_word('a', '사과', 'apple')]),
      );

      final summaries = provider.aiDiscussionSummaries;

      expect(summaries, hasLength(1));
      expect(summaries.single.vocab?.id, 'a');
      expect(summaries.single.messages, hasLength(2));
    });

    test('a new message goes to the shared discussion of the word', () async {
      final provider = await providerWith({
        'a:s1': [at('earlier', t1)],
      });

      await provider.addAiDiscussionMessage(
        AiDiscussionIds.forVocab('a'),
        at('later', t2),
      );

      expect(provider.aiDiscussions.keys, ['a:no-sentence']);
      expect(provider.aiDiscussions['a:no-sentence']!.map((m) => m.content), [
        'earlier',
        'later',
      ]);
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
        'a:no-sentence': [_msg('user', 'Earlier about a', minutes: 1)],
        'b:no-sentence': [_msg('user', 'Earlier about b', minutes: 2)],
        'c:no-sentence': [_msg('user', 'Earlier about c', minutes: 3)],
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

      expect(result.map((s) => s.discussion.id), [
        'a:no-sentence',
        'b:no-sentence',
      ]);
      expect(result.map((s) => s.label), ['Same word', 'Same meaning']);
    });
  });
}
