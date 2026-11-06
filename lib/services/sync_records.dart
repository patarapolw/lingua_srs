import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../models/ai_discussion_message.dart';
import '../models/lesson.dart';
import '../models/sentence.dart';
import '../models/shared_vocab.dart';
import '../models/srs_card.dart';
import '../models/vocab_merge_record.dart';

/// One record the app syncs: its kind and its id on this device. The id the
/// server sees is a keyed hash of these, made when the record is encrypted.
/// See "Records" in `docs/sync.md`.
class SyncRecordKey {
  const SyncRecordKey(this.kind, this.localId);

  /// Parses [storageKey]. A kind never contains `/`, so the first one splits.
  factory SyncRecordKey.parse(String storageKey) {
    final slash = storageKey.indexOf('/');
    if (slash <= 0) {
      throw FormatException('Invalid sync record key "$storageKey".');
    }
    return SyncRecordKey(
      storageKey.substring(0, slash),
      storageKey.substring(slash + 1),
    );
  }

  final String kind;
  final String localId;

  String get storageKey => '$kind/$localId';

  @override
  bool operator ==(Object other) =>
      other is SyncRecordKey && other.kind == kind && other.localId == localId;

  @override
  int get hashCode => Object.hash(kind, localId);

  @override
  String toString() => storageKey;
}

/// The record kinds, as named in `docs/sync.md`.
abstract final class SyncKinds {
  static const lesson = 'lesson';
  static const lessonMarkdown = 'lesson_md';
  static const vocab = 'vocab';
  static const card = 'card';
  static const sentence = 'sentence';
  static const merge = 'merge';
  static const discussion = 'discussion';
  static const activity = 'activity';
  static const lessonOrder = 'lesson_order';
  static const settings = 'settings';

  /// Kept when nothing uses them any more: whether a word is still used
  /// depends on every device, so removing one could lose progress.
  static const keptWhenUnused = {vocab, card};

  /// A change made on this device and not pushed yet is kept over a pulled
  /// deletion, however their times compare. Another device deletes a
  /// sentence when it merges duplicates, and an edit of the copy it removed
  /// must not be lost.
  static const editsBeatDeletion = {sentence};
}

/// Study settings that sync. Device-only preferences are not in here.
class SyncSettings {
  const SyncSettings({
    required this.maxReviews24h,
    required this.maxNewCards24h,
    required this.autoplayAudio,
    required this.pronunciationOptions,
  });

  final int maxReviews24h;
  final int maxNewCards24h;
  final bool autoplayAudio;
  final Set<String> pronunciationOptions;

  Map<String, dynamic> toJson() => {
    'maxReviews24h': maxReviews24h,
    'maxNewCards24h': maxNewCards24h,
    'autoplayAudio': autoplayAudio,
    'pronunciationOptions': pronunciationOptions.toList()..sort(),
  };
}

/// Builds the contents of every record from the app's state.
abstract final class SyncSnapshot {
  /// Fields of a vocabulary entry that belong to its shared [SyncKinds.vocab]
  /// and [SyncKinds.card] records instead of the lesson.
  static const _sharedEntryFields = {
    'audioUrl',
    'useAudio',
    SharedVocab.ttsField,
    'notes',
    'disambiguation',
    'cardTargetToNative',
    'cardNativeToTarget',
  };

  /// Card fields that are settings, kept in [SyncKinds.vocab] so that editing
  /// them does not conflict with a review.
  static const _cardSettingFields = {'isEnabled', 'frontHint', 'backNotes'};

  static Map<SyncRecordKey, Map<String, dynamic>> build({
    required List<Lesson> lessons,
    required List<Sentence> sentences,
    required List<VocabMergeRecord> mergeHistory,
    required Map<String, List<AiDiscussionMessage>> aiDiscussions,
    required Map<String, int> lessonOrder,
    required SyncSettings settings,
    required Map<DateTime, int> dailyReviewCounts,
    required List<DateTime> reviewTimestamps,
    required String deviceId,
  }) {
    final records = <SyncRecordKey, Map<String, dynamic>>{};
    void add(String kind, String id, Map<String, dynamic> data) =>
        records[SyncRecordKey(kind, id)] = data;

    for (final lesson in lessons) {
      final json = lesson.toJson();
      json['vocabularies'] = [
        for (final vocab in lesson.vocabularies)
          Map<String, dynamic>.from(vocab.toJson())
            ..removeWhere((key, _) => _sharedEntryFields.contains(key)),
      ];
      add(SyncKinds.lesson, lesson.id, json);
      if (lesson.markdownContent.isNotEmpty) {
        add(SyncKinds.lessonMarkdown, lesson.id, {
          'markdown': lesson.markdownContent,
        });
      }

      for (final vocab in lesson.vocabularies) {
        final key = SyncRecordKey(SyncKinds.vocab, vocab.id);
        if (records.containsKey(key)) continue;
        final shared = Map<String, dynamic>.from(vocab.shared.toJson())
          ..remove('cardTargetToNative')
          ..remove('cardNativeToTarget');
        final cards = [vocab.cardTargetToNative, vocab.cardNativeToTarget];
        shared['cards'] = {
          for (final card in cards) card.direction.name: _cardSettings(card),
        };
        records[key] = shared;
        for (final card in cards) {
          add(SyncKinds.card, card.id, {
            ...Map<String, dynamic>.from(card.toJson())
              ..removeWhere((key, _) => _cardSettingFields.contains(key)),
            'vocabId': vocab.id,
          });
        }
      }
    }

    for (final sentence in sentences) {
      add(SyncKinds.sentence, sentence.id, sentence.toJson());
    }
    for (final record in mergeHistory) {
      add(SyncKinds.merge, record.id, record.toJson());
    }
    for (final entry in aiDiscussions.entries) {
      add(SyncKinds.discussion, entry.key, {
        'messages': [for (final message in entry.value) message.toJson()],
      });
    }

    for (final entry in dailyReviewCounts.entries) {
      final day = _dayKey(entry.key);
      add(SyncKinds.activity, '$deviceId:$day', {
        'day': day,
        'count': entry.value,
        'reviews': [
          for (final time in reviewTimestamps)
            if (_dayKey(time) == day) time.toUtc().toIso8601String(),
        ]..sort(),
      });
    }

    add(SyncKinds.lessonOrder, SyncKinds.lessonOrder, {'order': lessonOrder});
    add(SyncKinds.settings, SyncKinds.settings, settings.toJson());
    return records;
  }

  /// When the record [key] with [data] last really changed, in milliseconds,
  /// as far as its contents tell: a card's last review, or a discussion's
  /// last message. 0 when they do not tell, so a copy already on the server
  /// wins over it.
  static int knownChangeTime(SyncRecordKey key, Map<String, dynamic> data) {
    int at(Object? value) => value is String
        ? DateTime.tryParse(value)?.millisecondsSinceEpoch ?? 0
        : 0;
    switch (key.kind) {
      case SyncKinds.card:
        return at(data['lastReviewed']);
      case SyncKinds.discussion:
        final messages = data['messages'];
        if (messages is! List) return 0;
        return messages
            .map((message) => message is Map ? at(message['createdAt']) : 0)
            .fold(0, (latest, time) => time > latest ? time : latest);
      default:
        return 0;
    }
  }

  /// A hash of [data] that does not depend on the order of map keys.
  static String hash(Map<String, dynamic> data) =>
      sha256.convert(utf8.encode(jsonEncode(_canonical(data)))).toString();

  static Map<String, dynamic> _cardSettings(SrsCard card) => {
    'id': card.id,
    'isEnabled': card.isEnabled,
    'frontHint': card.frontHint,
    'backNotes': card.backNotes,
  };

  static String _dayKey(DateTime time) {
    final local = time.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${local.year.toString().padLeft(4, '0')}-'
        '${two(local.month)}-${two(local.day)}';
  }

  static Object? _canonical(Object? value) {
    if (value is Map) {
      final keys = value.keys.map((key) => key.toString()).toList()..sort();
      return {for (final key in keys) key: _canonical(value[key])};
    }
    if (value is List) return [for (final item in value) _canonical(item)];
    return value;
  }
}
