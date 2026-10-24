import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/ai_discussion_message.dart';
import '../models/lesson.dart';
import '../models/sentence.dart';
import '../models/vocab_item.dart';
import '../providers/app_provider.dart';
import '../services/lesson_ai_prompt.dart';
import '../widgets/markdown_content.dart';
import 'ai_discussion_dialog.dart';

class RecentAiDiscussionsView extends StatelessWidget {
  const RecentAiDiscussionsView({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppProvider>();
    final discussions =
        provider.aiDiscussions.entries
            .map((entry) => _DiscussionSummary.fromEntry(entry, provider))
            .toList()
          ..sort((a, b) {
            final aTime = a.updatedAt;
            final bTime = b.updatedAt;
            if (aTime == null) return bTime == null ? 0 : 1;
            if (bTime == null) return -1;
            return bTime.compareTo(aTime);
          });

    return Scaffold(
      appBar: AppBar(title: const Text('Recent Discussions')),
      body: provider.isLoading
          ? const Center(child: CircularProgressIndicator())
          : discussions.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.forum_outlined,
                      size: 48,
                      color: Theme.of(context).colorScheme.outline,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'No discussions yet',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Ask AI about a vocabulary word while studying to start a discussion.',
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: discussions.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final discussion = discussions[index];
                return Card(
                  child: ListTile(
                    leading: const CircleAvatar(
                      child: Icon(Icons.forum_outlined),
                    ),
                    title: Text(
                      discussion.vocab?.targetWord ??
                          discussion.lesson?.displayTitle ??
                          'AI discussion',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (discussion.vocab?.translation case final translation
                            when translation != null &&
                                translation.trim().isNotEmpty)
                          Text(
                            translation,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        if (discussion.sentence?.targetText.trim() case final s?
                            when s.isNotEmpty)
                          Padding(
                            padding: const EdgeInsetsGeometry.only(
                              top: 2,
                              bottom: 2,
                            ),
                            child: MarkdownContent(
                              content: s,
                              style: const TextStyle(
                                fontStyle: FontStyle.italic,
                              ),
                            ),
                          ),
                        Text(
                          discussion.preview,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                    trailing: SizedBox(
                      width: 78,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            _formatUpdatedAt(discussion.updatedAt),
                            style: Theme.of(context).textTheme.labelSmall,
                            textAlign: TextAlign.end,
                          ),
                          const Icon(Icons.chevron_right),
                        ],
                      ),
                    ),
                    onTap: () => _openDiscussion(context, discussion),
                  ),
                );
              },
            ),
    );
  }

  void _openDiscussion(BuildContext context, _DiscussionSummary discussion) {
    final isLesson = LessonAiPrompt.isLessonDiscussion(discussion.id);
    // The lesson this discussion belonged to was deleted.
    if (isLesson && discussion.lesson == null) return;
    showDialog<void>(
      context: context,
      builder: (_) => AiDiscussionDialog(
        discussionId: discussion.id,
        targetWord:
            discussion.vocab?.targetWord ??
            (isLesson ? discussion.lesson!.displayTitle : discussion.id),
        translation: discussion.vocab?.translation ?? '',
        targetLanguage: discussion.lesson?.targetLanguage ?? 'ko',
        nativeLanguage: discussion.lesson?.nativeLanguage ?? 'en',
        sentenceTarget: discussion.sentence?.targetText,
        sentenceTranslation: discussion.sentence?.translationText,
        lesson: isLesson ? discussion.lesson : null,
      ),
    );
  }

  String _formatUpdatedAt(DateTime? updatedAt) {
    if (updatedAt == null) return 'Saved';
    final date = updatedAt.toLocal();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final dateDay = DateTime(date.year, date.month, date.day);
    final dayDifference = today.difference(dateDay).inDays;
    if (dayDifference == 0) {
      return '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    }
    if (dayDifference == 1) return 'Yesterday';
    return '${date.month}/${date.day}/${date.year}';
  }
}

class _DiscussionSummary {
  final String id;
  final List<AiDiscussionMessage> messages;
  final Lesson? lesson;
  final VocabItem? vocab;
  final Sentence? sentence;

  const _DiscussionSummary({
    required this.id,
    required this.messages,
    required this.lesson,
    required this.vocab,
    required this.sentence,
  });

  DateTime? get updatedAt {
    for (final message in messages.reversed) {
      if (message.createdAt != null) return message.createdAt;
    }
    return null;
  }

  String get preview {
    for (final message in messages.reversed) {
      if (message.role == 'user' && message.content.trim().isNotEmpty) {
        return message.content.trim();
      }
    }
    if (messages.isNotEmpty) return messages.last.content.trim();
    return 'No messages';
  }

  factory _DiscussionSummary.fromEntry(
    MapEntry<String, List<AiDiscussionMessage>> entry,
    AppProvider provider,
  ) {
    if (LessonAiPrompt.isLessonDiscussion(entry.key)) {
      final lessonId = LessonAiPrompt.lessonIdFrom(entry.key);
      Lesson? lesson;
      for (final candidate in provider.lessons) {
        if (candidate.id == lessonId) {
          lesson = candidate;
          break;
        }
      }
      return _DiscussionSummary(
        id: entry.key,
        messages: entry.value,
        lesson: lesson,
        vocab: null,
        sentence: null,
      );
    }
    final idParts = entry.key.split(':');
    final vocabId = idParts.first;
    Lesson? lesson;
    VocabItem? vocab;
    for (final candidateLesson in provider.lessons) {
      for (final candidateVocab in candidateLesson.vocabularies) {
        if (candidateVocab.id == vocabId) {
          lesson = candidateLesson;
          vocab = candidateVocab;
          break;
        }
      }
      if (vocab != null) break;
    }
    final sentenceId = idParts.length > 1 ? idParts[1] : 'no-sentence';
    return _DiscussionSummary(
      id: entry.key,
      messages: entry.value,
      lesson: lesson,
      vocab: vocab,
      sentence: sentenceId == 'no-sentence'
          ? null
          : provider.getSentenceById(sentenceId),
    );
  }
}
