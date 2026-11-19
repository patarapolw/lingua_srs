import 'dart:convert';

import 'package:yaml/yaml.dart';
import 'package:yaml_edit/yaml_edit.dart';

import '../models/ai_discussion_message.dart';
import '../models/lesson.dart';
import 'yaml_parser_service.dart';

/// Moves the words of a lesson's `## Vocabulary` section into its
/// frontmatter, which import reads words from, and removes the section,
/// which import leaves out (docs/lesson-format.md).
///
/// The words come from [YamlParserService.parseVocabularySection], or from
/// an AI ([prompt] and [parseReply]) when the section is not a plain list.
class VocabularySectionMove {
  /// The lesson's new text.
  final String text;

  /// Words added to the frontmatter, and words left out because the
  /// frontmatter (or the section, further up) already has them.
  final int added;
  final int skipped;

  const VocabularySectionMove({
    required this.text,
    required this.added,
    required this.skipped,
  });

  /// [words] that the lesson parsed as [preview] does not have yet, each
  /// word once.
  static List<SectionWord> newWords(
    YamlParseResult preview,
    List<SectionWord> words,
  ) {
    final seen = {
      for (final word in preview.lesson.vocabularies)
        YamlParserService.vocabularyKey(word.targetWord),
    };
    return [
      for (final word in words)
        if (seen.add(YamlParserService.vocabularyKey(word.word))) word,
    ];
  }

  /// [markdown] with [words] added to its frontmatter's `vocabulary:`, under
  /// their part-of-speech sections, and its `## Vocabulary` section removed.
  /// The rest of the file stays as it is.
  ///
  /// Throws a [FormatException] when [markdown] is not a Markdown lesson, or
  /// when the words cannot be added safely.
  static VocabularySectionMove apply(String markdown, List<SectionWord> words) {
    final span = YamlParserService.frontmatterSpan(markdown);
    if (span == null) {
      throw const FormatException('The lesson has no frontmatter.');
    }
    final before = YamlParserService.parseLessonYaml(markdown);
    final lesson = before.lesson;
    final targetKey = languageKey(lesson.targetLanguage);
    final nativeKey = languageKey(lesson.nativeLanguage);
    final toAdd = newWords(before, words);

    final editor = YamlEditor(markdown.substring(span.$1, span.$2));
    if (toAdd.isNotEmpty) {
      final bySection = <String, List<Map<String, String>>>{};
      for (final word in toAdd) {
        bySection.putIfAbsent(word.section, () => []).add({
          targetKey: word.word,
          nativeKey: word.meaning,
          if (word.notes.trim().isNotEmpty) 'notes': word.notes.trim(),
        });
      }
      final vocabulary = (loadYaml(editor.toString()) as Map)['vocabulary'];
      if (vocabulary is! Map || vocabulary.isEmpty) {
        editor.update(['vocabulary'], bySection);
      } else {
        for (final MapEntry(key: section, value: entries)
            in bySection.entries) {
          final existing = vocabulary[section];
          if (existing == null) {
            editor.update(['vocabulary', section], entries);
          } else if (existing is List) {
            for (final entry in entries) {
              editor.appendToList(['vocabulary', section], entry);
            }
          } else {
            throw FormatException(
              'The frontmatter\'s "$section" is not a list of words, so '
              'words cannot be added to it.',
            );
          }
        }
      }
    }

    var yaml = editor.toString();
    if (!yaml.endsWith('\n')) yaml = '$yaml\n';
    var rest = markdown
        .substring(span.$2)
        .replaceAll(YamlParserService.vocabularySectionPattern, '');
    if (markdown.endsWith('\n') && !rest.endsWith('\n')) rest = '$rest\n';
    final text = markdown.substring(0, span.$1) + yaml + rest;

    final after = YamlParserService.parseLessonYaml(text);
    if (after.lesson.vocabularies.length !=
            lesson.vocabularies.length + toAdd.length ||
        after.vocabularySection != null) {
      throw const FormatException(
        'The words could not be moved into the frontmatter safely.',
      );
    }
    return VocabularySectionMove(
      text: text,
      added: toAdd.length,
      skipped: words.length - toAdd.length,
    );
  }

  /// The key entries are written under for [language]: the language alone,
  /// `zh` for `zh-TW` (docs/lesson-format.md).
  static String languageKey(String language) =>
      language.split(RegExp('[-_]')).first.trim().toLowerCase();

  /// Asks an AI for the words of [section], a lesson's `## Vocabulary`
  /// section; [parseReply] reads its answer.
  static List<AiDiscussionMessage> prompt(String section, Lesson lesson) {
    final target = lesson.targetLanguage;
    final native = lesson.nativeLanguage;
    return [
      AiDiscussionMessage(
        role: 'system',
        content:
            'You turn the "## Vocabulary" section of a language lesson into '
            'a list of words. The lesson teaches the language "$target" to '
            'speakers of "$native". Reply with only a JSON object: '
            '{"words": [{"section": "nouns", "word": "…", "meaning": "…", '
            '"notes": "…"}]}.\n'
            '- "word": the word or phrase being taught, in "$target", as '
            'written in the section, without Markdown.\n'
            '- "meaning": its meaning in "$native", as the section gives '
            'it. Only when the section gives none, write a short one.\n'
            '- "section": the part of speech, as a lowercase plural English '
            'word (nouns, verbs, adjectives, adverbs, particles, '
            'expressions…), from the section\'s headings when it has them, '
            'otherwise from the word.\n'
            '- "notes": optional, only for other things the section says '
            'about the word (usage, an example, a reading), as Markdown.\n'
            'List every word of the section once, in its order. Do not add '
            'words that are not in it.',
      ),
      AiDiscussionMessage(role: 'user', content: section),
    ];
  }

  /// The words of an AI's answer to [prompt]. Throws a [FormatException]
  /// when it is not the JSON asked for.
  static List<SectionWord> parseReply(String reply) {
    final Object? decoded;
    try {
      decoded = jsonDecode(reply);
    } on FormatException {
      throw const FormatException('The AI did not answer with JSON.');
    }
    final list = decoded is Map ? decoded['words'] : null;
    if (list is! List) {
      throw const FormatException('The AI\'s answer has no "words" list.');
    }
    String field(Map entry, String key) => entry[key]?.toString().trim() ?? '';
    return [
      for (final entry in list)
        if (entry is Map &&
            field(entry, 'word').isNotEmpty &&
            field(entry, 'meaning').isNotEmpty)
          (
            section: _sectionName(field(entry, 'section')),
            word: field(entry, 'word'),
            meaning: field(entry, 'meaning'),
            notes: field(entry, 'notes'),
          ),
    ];
  }

  static String _sectionName(String value) {
    final name = value
        .toLowerCase()
        .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    return name.isEmpty ? 'words' : name;
  }
}
