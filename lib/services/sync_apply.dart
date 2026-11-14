import '../models/ai_discussion_message.dart';
import '../models/lesson.dart';
import '../models/sentence.dart';
import '../models/shared_vocab.dart';
import '../models/srs_card.dart';
import '../models/typed_question.dart';
import '../models/vocab_merge_record.dart';
import 'sync_records.dart';

/// The parts of the app's state that sync, as [SyncSnapshot.build] reads them
/// and [SyncApplier.apply] changes them.
class SyncAppData {
  SyncAppData({
    required this.deviceId,
    required this.lessons,
    required this.sentences,
    required this.mergeHistory,
    required this.aiDiscussions,
    this.typedQuestions = const {},
    required this.lessonOrder,
    required this.maxReviews24h,
    required this.maxNewCards24h,
    required this.autoplayAudio,
    required this.pronunciationOptions,
    required this.remoteActivity,
  });

  final String deviceId;
  List<Lesson> lessons;
  List<Sentence> sentences;
  List<VocabMergeRecord> mergeHistory;
  Map<String, List<AiDiscussionMessage>> aiDiscussions;

  /// Questions typed in AI chats, by id. See `TypedQuestions`.
  Map<String, TypedQuestion> typedQuestions;
  Map<String, int> lessonOrder;
  int maxReviews24h;
  int maxNewCards24h;
  bool autoplayAudio;
  Set<String> pronunciationOptions;

  /// Other devices' `activity` records, by local id (`<device id>:<day>`).
  Map<String, Map<String, dynamic>> remoteActivity;
}

/// What [SyncApplier.apply] changed, so only those parts are saved.
enum SyncAppPart {
  lessons,
  sentences,
  mergeHistory,
  aiDiscussions,
  typedQuestions,
  lessonOrder,
  settings,
  remoteActivity,
}

/// Applies pulled records to the app's state: the reverse of
/// [SyncSnapshot.build]. See "Records" in `docs/sync.md`.
abstract final class SyncApplier {
  static const maxMergeHistory = 20;

  /// Applies [changes] (new contents, or null for deleted) to [data] and
  /// returns the parts that changed.
  ///
  /// Word details and SRS cards are shared by every entry with the same vocab
  /// id, so they are updated in place, and a lesson pulled in the same batch
  /// as its words gets their details and progress. A `vocab` or `card` record
  /// for a word that no lesson on this device uses is dropped.
  ///
  /// When a word was studied on two devices before they synced, its cards
  /// have different ids; the card reviewed more recently keeps its progress,
  /// under the pulled card's id. On [firstSync], a local lesson with the same
  /// title and folder as a pulled one it does not have is merged into the
  /// pulled one, keeping the words and Markdown blocks only this device has.
  static Set<SyncAppPart> apply(
    SyncAppData data,
    Map<SyncRecordKey, Map<String, dynamic>?> changes, {
    bool firstSync = false,
  }) {
    final changed = <SyncAppPart>{};
    Map<String, Map<String, dynamic>?> ofKind(String kind) => {
      for (final entry in changes.entries)
        if (entry.key.kind == kind) entry.key.localId: entry.value,
    };

    final shared = <String, SharedVocab>{};
    for (final vocab in data.lessons.expand((lesson) => lesson.vocabularies)) {
      shared.putIfAbsent(vocab.id, () => vocab.shared);
    }
    final cards = ofKind(SyncKinds.card);
    final vocabs = ofKind(SyncKinds.vocab);
    if (vocabs.isNotEmpty || cards.isNotEmpty) changed.add(SyncAppPart.lessons);
    final usedCards = <String>{};

    for (final entry in vocabs.entries) {
      final json = entry.value;
      if (json == null) continue;
      final existing = shared[entry.key];
      final settings = json['cards'] is Map ? json['cards'] as Map : const {};
      SrsCard card(CardDirection direction, SrsCard? current) {
        final setting = settings[direction.name] is Map
            ? Map<String, dynamic>.from(settings[direction.name] as Map)
            : <String, dynamic>{};
        final id = setting['id'] as String? ?? current?.id;
        final progress = id == null ? null : cards[id];
        if (id != null) usedCards.add(id);
        final base = current == null
            ? progress ?? <String, dynamic>{}
            : current.id == id
            ? progress ?? current.toJson()
            : _newerProgress(current, progress);
        return _card(current, {
          ...base,
          ...setting,
          'id': id,
          'direction': direction.name,
        });
      }

      final details = Map<String, dynamic>.from(json)..remove('cards');
      if (existing == null) {
        shared[entry.key] = SharedVocab.fromJson({
          ...details,
          'cardTargetToNative': card(
            CardDirection.targetToNative,
            null,
          ).toJson(),
          'cardNativeToTarget': card(
            CardDirection.nativeToTarget,
            null,
          ).toJson(),
        });
        continue;
      }
      final incoming = SharedVocab.fromJson({
        ...details,
        'cardTargetToNative': existing.cardTargetToNative.toJson(),
        'cardNativeToTarget': existing.cardNativeToTarget.toJson(),
      });
      existing
        ..audioUrl = incoming.audioUrl
        ..useAudio = incoming.useAudio
        ..ttsText = incoming.ttsText
        ..notes = incoming.notes
        ..disambiguation = incoming.disambiguation
        ..cardTargetToNative = card(
          CardDirection.targetToNative,
          existing.cardTargetToNative,
        )
        ..cardNativeToTarget = card(
          CardDirection.nativeToTarget,
          existing.cardNativeToTarget,
        );
      existing.meta
        ..clear()
        ..addAll(incoming.meta);
      existing.alternates
        ..clear()
        ..addAll(incoming.alternates);
    }

    // Progress pulled without its word's details: the details did not change.
    for (final entry in cards.entries) {
      final json = entry.value;
      if (json == null || usedCards.contains(entry.key)) continue;
      final owner = shared[json['vocabId']];
      if (owner == null) continue;
      final targetToNative =
          json['direction'] == CardDirection.targetToNative.name;
      final current = targetToNative
          ? owner.cardTargetToNative
          : owner.cardNativeToTarget;
      final next = _card(current, {
        ...(current.id == entry.key ? json : _newerProgress(current, json)),
        'id': entry.key,
        'direction': json['direction'],
        'isEnabled': current.isEnabled,
        'isSuspended': current.isSuspended,
        'frontHint': current.frontHint,
        'backNotes': current.backNotes,
      });
      if (targetToNative) {
        owner.cardTargetToNative = next;
      } else {
        owner.cardNativeToTarget = next;
      }
    }

    final markdown = ofKind(SyncKinds.lessonMarkdown);
    final lessons = ofKind(SyncKinds.lesson);
    if (lessons.isNotEmpty || markdown.isNotEmpty) {
      changed.add(SyncAppPart.lessons);
    }
    final next = [...data.lessons];
    final lessonIndexes = {
      for (var index = 0; index < next.length; index++) next[index].id: index,
    };
    final removedLessons = <String>{};
    final localLessonsByName = <(String, String), List<(Lesson, int)>>{};
    if (firstSync) {
      for (var index = 0; index < next.length; index++) {
        final local = next[index];
        if (lessons.containsKey(local.id)) continue;
        localLessonsByName.putIfAbsent(_sameLessonKey(local), () => []).add((
          local,
          index,
        ));
      }
    }
    final matchedLocalLessons = <String>{};
    // Markdown of local lessons merged into a pulled one, by the pulled id.
    final mergedMarkdown = <String, String>{};
    for (final entry in lessons.entries) {
      final index = lessonIndexes[entry.key] ?? -1;
      final json = entry.value;
      if (json == null) {
        if (index >= 0) {
          removedLessons.add(entry.key);
          lessonIndexes.remove(entry.key);
        }
        continue;
      }
      var previous = index >= 0 ? next[index] : null;
      var at = index;
      final lesson = Lesson.fromJson({...json, 'id': entry.key});
      if (previous == null && firstSync) {
        for (final (local, localIndex)
            in localLessonsByName[_sameLessonKey(lesson)] ?? const []) {
          if (matchedLocalLessons.add(local.id)) {
            at = localIndex;
            break;
          }
        }
        if (at >= 0) {
          previous = next[at];
          lessonIndexes.remove(previous.id);
          lessonIndexes[entry.key] = at;
          final pulled = {for (final vocab in lesson.vocabularies) vocab.id};
          lesson.vocabularies.addAll(
            previous.vocabularies.where((vocab) => !pulled.contains(vocab.id)),
          );
          mergedMarkdown[entry.key] = previous.markdownContent;
        }
      }
      lesson.markdownContent = previous?.markdownContent ?? '';
      for (final vocab in lesson.vocabularies) {
        final existing = shared[vocab.id];
        if (existing != null) {
          vocab.shared = existing;
        } else {
          shared[vocab.id] = vocab.shared;
        }
      }
      if (at >= 0) {
        next[at] = lesson;
        lessonIndexes[entry.key] = at;
      } else {
        lessonIndexes[entry.key] = next.length;
        next.add(lesson);
      }
    }
    for (final entry in markdown.entries) {
      final index = lessonIndexes[entry.key];
      if (index == null) continue;
      final lesson = next[index];
      final pulled = entry.value?['markdown'] as String? ?? '';
      final own = mergedMarkdown[entry.key];
      lesson.markdownContent = own == null
          ? pulled
          : _mergeMarkdown(pulled, own);
    }
    data.lessons = [
      for (final lesson in next)
        if (!removedLessons.contains(lesson.id)) lesson,
    ];

    final sentences = ofKind(SyncKinds.sentence);
    if (sentences.isNotEmpty) {
      changed.add(SyncAppPart.sentences);
      data.sentences = _upsert(
        data.sentences,
        sentences,
        id: (sentence) => sentence.id,
        parse: (id, json) => Sentence.fromJson({...json, 'id': id}),
      );
    }

    final merges = ofKind(SyncKinds.merge);
    if (merges.isNotEmpty) {
      changed.add(SyncAppPart.mergeHistory);
      final records = _upsert(
        data.mergeHistory,
        merges,
        id: (record) => record.id,
        parse: (id, json) => VocabMergeRecord.fromJson(json),
      )..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      data.mergeHistory = records.take(maxMergeHistory).toList();
    }

    final discussions = ofKind(SyncKinds.discussion);
    if (discussions.isNotEmpty) {
      changed.add(SyncAppPart.aiDiscussions);
      final next = {...data.aiDiscussions};
      for (final entry in discussions.entries) {
        final messages = entry.value?['messages'];
        if (messages is! List) {
          next.remove(entry.key);
          continue;
        }
        next[entry.key] = [
          for (final message in messages)
            AiDiscussionMessage.fromJson(
              Map<String, dynamic>.from(message as Map),
            ),
        ];
      }
      data.aiDiscussions = next;
    }

    final questions = ofKind(SyncKinds.question);
    if (questions.isNotEmpty) {
      changed.add(SyncAppPart.typedQuestions);
      final next = {...data.typedQuestions};
      for (final entry in questions.entries) {
        final json = entry.value;
        if (json == null) {
          next.remove(entry.key);
          continue;
        }
        try {
          next[entry.key] = TypedQuestion.fromJson(json);
        } on FormatException {
          // A question that cannot be read is not offered; the rest are.
        }
      }
      data.typedQuestions = next;
    }

    for (final entry in ofKind(SyncKinds.activity).entries) {
      if (entry.key.startsWith('${data.deviceId}:')) continue;
      changed.add(SyncAppPart.remoteActivity);
      final json = entry.value;
      if (json == null) {
        data.remoteActivity.remove(entry.key);
      } else {
        data.remoteActivity[entry.key] = json;
      }
    }

    final order = ofKind(
      SyncKinds.lessonOrder,
    )[SyncKinds.lessonOrder]?['order'];
    if (order is Map) {
      changed.add(SyncAppPart.lessonOrder);
      data.lessonOrder = {
        for (final entry in order.entries)
          entry.key as String: (entry.value as num).toInt(),
      };
    }

    final settings = ofKind(SyncKinds.settings)[SyncKinds.settings];
    if (settings != null) {
      changed.add(SyncAppPart.settings);
      data
        ..maxReviews24h =
            (settings['maxReviews24h'] as num?)?.toInt() ?? data.maxReviews24h
        ..maxNewCards24h =
            (settings['maxNewCards24h'] as num?)?.toInt() ?? data.maxNewCards24h
        ..autoplayAudio =
            settings['autoplayAudio'] as bool? ?? data.autoplayAudio
        ..pronunciationOptions = {
          for (final option
              in settings['pronunciationOptions'] as List? ?? const [])
            option as String,
        };
    }
    return changed;
  }

  /// The progress to keep for a card studied on two devices: this device's
  /// [current] card if it was reviewed more recently than [pulled], or if
  /// [pulled] is not known, else [pulled].
  static Map<String, dynamic> _newerProgress(
    SrsCard current,
    Map<String, dynamic>? pulled,
  ) {
    if (pulled == null) return current.toJson();
    final theirs = DateTime.tryParse('${pulled['lastReviewed']}');
    final mine = current.lastReviewed;
    return mine != null && (theirs == null || mine.isAfter(theirs))
        ? current.toJson()
        : pulled;
  }

  /// The [pulled] Markdown of a lesson merged on the first sync, followed by
  /// the blocks (text between blank lines) of this device's [own] Markdown
  /// that [pulled] does not have, in their order.
  static String _mergeMarkdown(String pulled, String own) {
    List<String> blocks(String markdown) => [
      for (final block in markdown.split(RegExp(r'\n[ \t]*\n')))
        if (block.trim().isNotEmpty) block.trim(),
    ];
    final known = blocks(pulled).toSet();
    final extra = blocks(own).where((block) => !known.contains(block));
    if (extra.isEmpty) return pulled;
    if (pulled.trim().isEmpty) return own;
    return '${pulled.trimRight()}\n\n${extra.join('\n\n')}'
        '${own.endsWith('\n') ? '\n' : ''}';
  }

  static (String, String) _sameLessonKey(Lesson lesson) => (
    hierarchyFolderKey(lesson.folderPath),
    lesson.displayTitle.trim().toLowerCase(),
  );

  /// [current] with every field from [json], or a new card when the ids
  /// differ. Changing the card in place keeps screens that hold it in step.
  static SrsCard _card(SrsCard? current, Map<String, dynamic> json) {
    final incoming = SrsCard.fromJson(json);
    if (current == null || current.id != incoming.id) return incoming;
    return current
      ..isEnabled = incoming.isEnabled
      ..isSuspended = incoming.isSuspended
      ..backNotes = incoming.backNotes
      ..frontHint = incoming.frontHint
      ..interval = incoming.interval
      ..repetitions = incoming.repetitions
      ..easeFactor = incoming.easeFactor
      ..dueDate = incoming.dueDate
      ..lastReviewed = incoming.lastReviewed
      ..status = incoming.status
      ..lapses = incoming.lapses
      ..lastMistakeDate = incoming.lastMistakeDate
      ..lastRating = incoming.lastRating
      ..mistakesClearedAt = incoming.mistakesClearedAt
      ..introducedAt = incoming.introducedAt;
  }

  static List<T> _upsert<T>(
    List<T> items,
    Map<String, Map<String, dynamic>?> changes, {
    required String Function(T) id,
    required T Function(String id, Map<String, dynamic> json) parse,
  }) {
    // Looked up by id, not searched, so a first sync of thousands of items
    // does not compare each one with every other.
    final next = <T?>[...items];
    final indexOf = <String, int>{};
    for (var index = next.length - 1; index >= 0; index--) {
      indexOf[id(next[index] as T)] = index;
    }
    for (final entry in changes.entries) {
      final index = indexOf[entry.key];
      final json = entry.value;
      if (json == null) {
        if (index != null) next[index] = null;
      } else if (index != null) {
        next[index] = parse(entry.key, json);
      } else {
        indexOf[entry.key] = next.length;
        next.add(parse(entry.key, json));
      }
    }
    return next.whereType<T>().toList();
  }
}
