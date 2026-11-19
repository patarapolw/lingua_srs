import 'dart:convert';

import 'package:yaml/yaml.dart';
import 'package:yaml_edit/yaml_edit.dart';

import '../models/ai_discussion_message.dart';
import '../models/lesson.dart';
import '../models/vocab_item.dart';
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
  ) => _unseen(preview.lesson.vocabularies, words);

  /// [words] whose word none of [have] is, each word once.
  static List<SectionWord> _unseen(
    Iterable<VocabItem> have,
    List<SectionWord> words,
  ) {
    final seen = {
      for (final word in have) YamlParserService.vocabularyKey(word.targetWord),
    };
    return [
      for (final word in words)
        if (seen.add(YamlParserService.vocabularyKey(word.word))) word,
    ];
  }

  /// [markdown] with the words of [reading] added to its frontmatter's
  /// `vocabulary:`, under their part-of-speech sections, and its
  /// `## Vocabulary` section replaced by [VocabularySectionReading.notes]
  /// under a `## Vocabulary notes` heading, or removed when it has none. The
  /// rest of the file stays as it is.
  ///
  /// An example whose sentence does not mark the word in `**`, and in which
  /// the word cannot be found to mark it, becomes a note of the word.
  ///
  /// Throws a [FormatException] when [markdown] is not a Markdown lesson, or
  /// when the words cannot be added safely.
  static VocabularySectionMove apply(
    String markdown,
    VocabularySectionReading reading,
  ) {
    if (YamlParserService.frontmatterSpan(markdown) == null) {
      // Markdown without frontmatter: give it one, naming the language its
      // words were read in, so they can be written there.
      final guessed = YamlParserService.parseLessonYaml(markdown);
      if (!guessed.wordsFromSection) {
        throw const FormatException('The lesson has no frontmatter.');
      }
      markdown =
          '---\ntarget: ${guessed.lesson.targetLanguage}\nvocabulary:\n---\n\n'
          '${markdown.trimLeft()}';
    }
    final span = YamlParserService.frontmatterSpan(markdown)!;
    final before = YamlParserService.parseLessonYaml(markdown);
    final lesson = before.lesson;
    final toAdd = newWords(before, reading.words);

    final editor = YamlEditor(markdown.substring(span.$1, span.$2));
    if (toAdd.isNotEmpty) {
      final bySection = <String, List<Map<String, Object>>>{};
      for (final word in toAdd) {
        bySection
            .putIfAbsent(word.section, () => [])
            .add(entryYaml(word, lesson));
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
    var rest = YamlParserService.withVocabularyNotes(
      markdown.substring(span.$2),
      reading.notes,
    );
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
      skipped: reading.words.length - toAdd.length,
    );
  }

  /// The heading the text of a `## Vocabulary` section that is not about one
  /// word is kept under.
  static const notesHeading = YamlParserService.vocabularyNotesHeading;

  /// The frontmatter entry for [word] in [lesson]
  /// ([YamlParserService.sectionWordYaml]).
  static Map<String, Object> entryYaml(SectionWord word, Lesson lesson) =>
      YamlParserService.sectionWordYaml(
        word,
        targetLanguage: lesson.targetLanguage,
        nativeLanguage: lesson.nativeLanguage,
      );

  /// The key entries are written under for [language]
  /// ([YamlParserService.languageKey]).
  static String languageKey(String language) =>
      YamlParserService.languageKey(language);

  /// Asks an AI for the words of [section], a lesson's `## Vocabulary`
  /// section; [parseReply] reads its answer.
  static List<AiDiscussionMessage> prompt(String section, Lesson lesson) {
    final target = lesson.targetLanguage;
    final native = lesson.nativeLanguage;
    final base = languageKey(target);
    final forms = switch (base) {
      'zh' =>
        '- "reading": the pinyin, with tone marks, when the section gives '
            'it.\n'
            '- "simplified" and "traditional": the word\'s Simplified and '
            'Traditional Chinese forms, when the section gives them.\n',
      'ko' =>
        '- "hanja": the Hanja of a Sino-Korean word, when the section '
            'gives it.\n',
      'ja' => '- "reading": the kana reading, when the section gives it.\n',
      _ => '',
    };
    return [
      AiDiscussionMessage(
        role: 'system',
        content:
            'You turn the "## Vocabulary" section of a language lesson into '
            'a list of words. The lesson teaches the language "$target" to '
            'speakers of "$native". Reply with only a JSON object: '
            '{"words": [{"section": "nouns", "word": "…", "meaning": "…", '
            '"reading": "…", "simplified": "…", "traditional": "…", '
            '"hanja": "…", "notes": ["…"], "examples": [{"sentence": "…", '
            '"translation": "…", "notes": ["…"]}]}], "notes": "…"}.\n'
            '- "word": the word or phrase being taught, in "$target", as '
            'written in the section, without Markdown.\n'
            '- "meaning": its meaning in "$native", as the section gives '
            'it. Only when the section gives none, write a short one.\n'
            '- "section": the part of speech, as a lowercase plural English '
            'word (nouns, verbs, adjectives, adverbs, particles, '
            'expressions…), from the section\'s headings when it has them, '
            'otherwise from the word.\n'
            '$forms'
            '- "notes": paragraphs the section has about the word (usage, '
            'grammar), as Markdown.\n'
            '- "examples": the example sentences the section gives for the '
            'word, in "$target", with the word as it appears in the sentence '
            'wrapped in **double asterisks**, their "$native" translation '
            'when given, and notes about the sentence.\n'
            'Leave out any field the section does not give. List every word '
            'of the section once, in its order, and do not add words, '
            'examples or notes that are not in it.\n'
            '- The top-level "notes": the section\'s Markdown that is not '
            'about one word, such as an introduction or a note under a '
            'heading, with the "###" headings it is under; an empty string '
            'when there is none.',
      ),
      AiDiscussionMessage(role: 'user', content: section),
    ];
  }

  /// The words of an AI's answer to [prompt]. Throws a [FormatException]
  /// when it is not the JSON asked for.
  static VocabularySectionReading parseReply(String reply) {
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
    List<String> notes(Object? value) {
      final values = value is List ? value : [value];
      return [
        for (final note in values)
          if (note != null && note.toString().trim().isNotEmpty)
            note.toString().trim(),
      ];
    }

    final words = [
      for (final entry in list)
        if (entry is Map &&
            field(entry, 'word').isNotEmpty &&
            field(entry, 'meaning').isNotEmpty)
          SectionWord(
            section: _sectionName(field(entry, 'section')),
            word: field(entry, 'word'),
            meaning: field(entry, 'meaning'),
            reading: field(entry, 'reading'),
            forms: {
              for (final key in ['simplified', 'traditional', 'hanja'])
                if (field(entry, key).isNotEmpty) key: field(entry, key),
            },
            notes: notes(entry['notes']),
            examples: [
              if (entry['examples'] case final List examples)
                for (final example in examples)
                  if (example is Map && field(example, 'sentence').isNotEmpty)
                    SectionExample(
                      sentence: field(example, 'sentence'),
                      translation: field(example, 'translation'),
                      notes: notes(example['notes']),
                    ),
            ],
          ),
    ];
    return VocabularySectionReading(
      words: words,
      notes: decoded is Map ? notes(decoded['notes']).join('\n\n') : '',
    );
  }

  static String _sectionName(String value) {
    final name = value
        .toLowerCase()
        .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    return name.isEmpty ? 'words' : name;
  }
}
