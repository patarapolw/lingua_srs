import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:yaml/yaml.dart';

import '../models/lesson.dart';
import '../models/vocab_item.dart';
import '../models/sentence.dart';
import 'lesson_links.dart';

class YamlParseResult {
  final Lesson lesson;
  final List<Sentence> sentences;

  /// Where each word of [lesson] is in the YAML, in the same order as
  /// [Lesson.vocabularies].
  final List<VocabEntryLocation> locations;

  /// Every vocabulary section of the YAML, by its names joined with
  /// [sectionSeparator].
  final Map<String, VocabSectionLocation> sections;

  /// The path of the map that holds the sections: `vocabulary`, or the root
  /// of plain YAML that has no such key.
  final List<Object?> vocabularyPath;

  /// The text of the Markdown body's `## Vocabulary` section, without its
  /// heading and closing comment, which import leaves out of the lesson
  /// (docs/lesson-format.md). Null when the body has no such section.
  final String? vocabularySection;

  /// The lesson is Markdown without frontmatter, so its words were read from
  /// its `## Vocabulary` section ([YamlParserService.parseVocabularySection])
  /// rather than from YAML.
  final bool wordsFromSection;

  YamlParseResult({
    required this.lesson,
    required this.sentences,
    this.locations = const [],
    this.sections = const {},
    this.vocabularyPath = const [],
    this.vocabularySection,
    this.wordsFromSection = false,
  });

  static const sectionSeparator = '\u0000';

  static String sectionKey(Iterable<String> names) =>
      names.map((name) => name.trim()).join(sectionSeparator);
}

/// Where a vocabulary section is in a lesson's YAML: the keys from the root
/// of the document as they are written, and whether it holds entries (a
/// list) or more sections (a map).
class VocabSectionLocation {
  final List<Object?> path;
  final bool isList;

  const VocabSectionLocation(this.path, {required this.isList});
}

/// Where a vocabulary entry is in a lesson's YAML, and the keys it is
/// written with, so that the entry can be changed in place
/// (`LessonFileUpdate`) without reading the lesson syntax again.
class VocabEntryLocation {
  /// From the root of the document to the entry's map.
  final List<Object?> path;
  final Object? targetKey;
  final Object? translationKey;
  final Object? ttsKey;

  /// The keys the entry's reading and other forms are written with, by
  /// [VocabSource.formFields] name. A field the entry does not have has none.
  final Map<String, Object?> formKeys;

  /// The entry's examples that became sentences, in the order of
  /// [VocabItem.sentenceIds] as parsed.
  final List<ExampleLocation> examples;

  /// Whether `examples` is a list in the entry.
  final bool hasExamples;

  const VocabEntryLocation({
    required this.path,
    this.targetKey,
    this.translationKey,
    this.ttsKey,
    this.formKeys = const {},
    this.examples = const [],
    this.hasExamples = false,
  });
}

/// An example of a vocabulary entry: its place in the entry's `examples`
/// list and the keys it is written with.
class ExampleLocation {
  final int index;
  final String sentenceId;
  final Object? targetKey;
  final Object? translationKey;

  const ExampleLocation({
    required this.index,
    required this.sentenceId,
    this.targetKey,
    this.translationKey,
  });
}

/// An example sentence in the target language that has no `**emphasis**`.
typedef MissingEmphasis = ({String word, String sentence});

/// A file with example sentences that have no `**emphasis**`, every one of
/// them, so the file can be fixed in one go. Importing needs the marking to
/// know which part of the sentence a word is about.
class MissingEmphasisException extends FormatException {
  MissingEmphasisException(this.sentences) : super(_describe(sentences));

  final List<MissingEmphasis> sentences;

  static String _describe(List<MissingEmphasis> sentences) {
    final count = sentences.length;
    return '$count example ${count == 1 ? 'sentence has' : 'sentences have'} '
        'no **emphasis**. Wrap the word being studied in ** **, for '
        'example: 저는 **배**를 먹어요.\n'
        '${sentences.map((m) => '  ${m.word}: ${m.sentence}').join('\n')}';
  }
}

/// An entry kept by [YamlParserService.withoutKnownVocabulary].
typedef KeptVocabularyEntry = ({String word, String section});

/// A word the learner has, to compare suggested vocabulary with: its target
/// word, its translation, and, where the target word does not show both how
/// it is written and how it is read, the other one, each of which can be
/// empty:
/// - [hanja], the written form of a Korean word, whose Hangul is its reading:
///   공부 is 工夫;
/// - [reading], how a word written in characters is read, such as the pinyin
///   of a Chinese word: 行 is xíng or háng.
typedef KnownVocabulary = ({
  String word,
  String meaning,
  String hanja,
  String reading,
});

/// How a word is told apart from others written alike: the key it is
/// compared under, its written form and its reading, either of which can be
/// unknown (empty).
typedef _WordIdentity = ({String key, String form, String reading});

/// A kept entry written exactly like another word, but whose translation has
/// no meaning in common with it, so it may be another word that is spelled
/// and read the same (배 "pear" and 배 "ship"), or the same word translated
/// differently.
typedef PossibleDuplicate = ({
  String word,
  String meaning,
  String otherMeaning,

  /// Whether the other word is earlier in the same YAML, rather than a word
  /// the learner has.
  bool inList,
});

/// Vocabulary YAML with the words that are already known left out, from
/// [YamlParserService.withoutKnownVocabulary].
class VocabularyYamlFilter {
  /// The YAML without the left-out entries, as written otherwise.
  final String yaml;

  /// The entries that are kept, in order: each one's target word and the
  /// section (usually a part of speech) it is listed under.
  final List<KeptVocabularyEntry> keptEntries;

  /// The target words of the entries that are kept, in order.
  List<String> get kept => [for (final entry in keptEntries) entry.word];

  /// The target words of the entries that were left out, in order.
  final List<String> removed;

  /// Kept entries that may still be duplicates, in order.
  final List<PossibleDuplicate> possibleDuplicates;

  const VocabularyYamlFilter({
    required this.yaml,
    required this.keptEntries,
    required this.removed,
    this.possibleDuplicates = const [],
  });
}

/// An example sentence of a [SectionWord]: the sentence with the word
/// marked in `**`, once [YamlParserService.emphasizeWord] could find it, its
/// translation (may be empty) and its notes.
class SectionExample {
  final String sentence;
  final String translation;
  final List<String> notes;

  SectionExample({
    required this.sentence,
    this.translation = '',
    List<String>? notes,
  }) : notes = notes ?? [];
}

/// A word read from a `## Vocabulary` section of a lesson's Markdown body
/// ([YamlParserService.parseVocabularySection]), with what the section says
/// about it, to be written into the frontmatter.
class SectionWord {
  /// The part of speech it is listed under: a frontmatter section name such
  /// as `nouns`.
  final String section;
  final String word;
  final String meaning;

  /// How it is read: pinyin for Chinese, kana for Japanese. May be empty.
  final String reading;

  /// Its other written forms, by frontmatter key: `simplified`,
  /// `traditional` or `hanja`.
  final Map<String, String> forms;

  /// Paragraphs of notes.
  final List<String> notes;
  final List<SectionExample> examples;

  SectionWord({
    required this.section,
    required this.word,
    required this.meaning,
    this.reading = '',
    Map<String, String>? forms,
    List<String>? notes,
    List<SectionExample>? examples,
  }) : forms = forms ?? {},
       notes = notes ?? [],
       examples = examples ?? [];
}

/// What [YamlParserService.parseVocabularySection] read from a
/// `## Vocabulary` section.
class VocabularySectionReading {
  final List<SectionWord> words;

  /// Lines that look like a word but could not be read as one, such as a
  /// list item without a meaning. They are kept in [notes] too.
  final List<String> unread;

  /// The Markdown of the section that is not about one word, such as text
  /// under a `###` heading, with the headings it is under. It cannot go into
  /// the frontmatter, so it is kept in the lesson's text.
  final String notes;

  const VocabularySectionReading({
    required this.words,
    this.unread = const [],
    this.notes = '',
  });
}

/// An example sentence for a word: the plain sentence for the Sentence Pool,
/// and the word's own `**` marking of it.
typedef ExampleSentence = ({Sentence sentence, SentenceEmphasis emphasis});

class YamlParserService {
  /// Known language keys for auto-detection
  static const List<String> knownLangKeys = [
    'ko',
    'ja',
    'zh',
    'es',
    'fr',
    'de',
    'ru',
    'it',
    'pt',
    'ar',
    'target',
    'term',
    'word',
  ];

  static const List<String> knownNativeKeys = [
    'en',
    'eng',
    'native',
    'translation',
    'meaning',
    'trans',
  ];

  /// The fields of one example of a word: its sentence and translation as
  /// written (with any `**`), the keys they are under, and its recording,
  /// text-to-speech text and notes.
  static ({
    String target,
    String translation,
    Object? targetKey,
    Object? translationKey,
    String? audio,
    String? tts,
    String notes,
  })
  _exampleFields(Map example) {
    var target = '';
    var translation = '';
    Object? targetKey;
    Object? translationKey;
    String? tts;
    for (final field in example.entries) {
      final key = field.key.toString().trim().toLowerCase();
      final value = field.value?.toString().trim() ?? '';
      if (knownLangKeys.contains(key) && target.isEmpty) {
        target = value;
        if (value.isNotEmpty) targetKey = field.key;
      } else if (knownNativeKeys.contains(key) && translation.isEmpty) {
        translation = value;
        if (value.isNotEmpty) translationKey = field.key;
      } else if (_isTtsKey(key) && value.isNotEmpty) {
        tts = value;
      }
    }
    return (
      target: target,
      translation: translation,
      targetKey: targetKey,
      translationKey: translationKey,
      audio: example['audio']?.toString().trim(),
      tts: tts,
      notes: example['notes'] == null ? '' : _notesText(example['notes']),
    );
  }

  /// Example sentences for one word, as an AI chat about the word gives them:
  /// YAML with an `examples:` list at its root, each example written as in a
  /// word's `examples` in a lesson (see docs/lesson-format.md). An example
  /// without a sentence is skipped. Each [ExampleSentence.sentence] is plain
  /// text, and its [ExampleSentence.emphasis] keeps the `**` as written,
  /// which may be none. Throws a [FormatException] for YAML that is not that.
  static List<ExampleSentence> parseExampleSentences(String yaml) {
    final doc = loadYaml(yaml);
    final examples = doc is Map ? doc['examples'] : null;
    if (examples is! List) {
      throw const FormatException('Expected an "examples:" list.');
    }
    return [
      for (final example in examples)
        if (example is Map)
          if (_exampleFields(example) case final fields
              when fields.target.isNotEmpty)
            (
              sentence: Sentence(
                targetText: Sentence.stripEmphasis(fields.target),
                translationText: Sentence.stripEmphasis(fields.translation),
                audioUrl: fields.audio,
                ttsText: fields.tts,
                notes: fields.notes,
              ),
              emphasis: SentenceEmphasis(
                target: fields.target,
                translation: fields.translation,
              ),
            ),
    ];
  }

  /// The error for Markdown given to [parseLessonYaml] with `allowMarkdown`
  /// false.
  static const markdownNotAllowed =
      'Only vocabulary can be added here, as plain YAML starting with '
      '"vocabulary:". Markdown (a "---" frontmatter block and lesson text) '
      'is not allowed: it would replace the lesson\'s text. Edit the lesson '
      'to change its text.';

  /// Parses a lesson: Markdown with YAML frontmatter, or plain YAML. With
  /// [allowMarkdown] false, as when only vocabulary is added to a lesson,
  /// Markdown is a [FormatException] ([markdownNotAllowed]).
  static YamlParseResult parseLessonYaml(
    String yamlString, {
    String? defaultTitle,
    String? defaultUnitTitle,
    bool allowMarkdown = true,
    String? sourcePath,
  }) {
    final source = yamlString.trim();
    // Markdown without frontmatter is a lesson when it has a `## Vocabulary`
    // section: its words are read from the section.
    final wordsFromSection =
        !source.startsWith('---') && isSectionOnlyMarkdown(source);
    var frontMatter = wordsFromSection ? '---\n---\n$source' : source;
    String? markdownTitle;
    String markdownContent = '';
    String? removedVocabularySection;
    VocabularySectionReading? sectionReading;
    String? sectionLanguage;
    final isMarkdown = frontMatter.startsWith('---');
    if (isMarkdown && !allowMarkdown) {
      throw const FormatException(markdownNotAllowed);
    }
    if (isMarkdown) {
      final frontMatterParts = _splitMarkdownFrontmatter(frontMatter);
      final markdownBody = frontMatterParts.$2;
      final vocabularySection = vocabularySectionPattern;
      removedVocabularySection = vocabularySectionOf(markdownBody);
      if (wordsFromSection) {
        sectionLanguage = guessSectionLanguage(removedVocabularySection ?? '');
        sectionReading = parseVocabularySection(
          removedVocabularySection ?? '',
          targetLanguage: sectionLanguage,
        );
      }
      markdownContent = withVocabularyNotes(
        markdownBody,
        sectionReading?.notes ?? '',
      ).trim();
      final bodyLines = markdownContent
          .split(RegExp(r'\r?\n'))
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty)
          .toList();
      if (vocabularySection.hasMatch(markdownBody) &&
          bodyLines.length == 1 &&
          RegExp(r'^#\s+.+$').hasMatch(bodyLines.single)) {
        markdownContent = '';
      }
      final headingTitle = RegExp(
        r'^#\s+(.+)$',
        multiLine: true,
      ).firstMatch(markdownBody)?.group(1)?.trim();
      markdownTitle = headingTitle == null
          ? null
          : LessonLink.splitHeadingAttributes(headingTitle).$1
                .replaceAll(r'\~', '~');
      frontMatter = frontMatterParts.$1;
    }

    final doc = sectionReading == null
        ? loadYaml(frontMatter)
        : {
            'target': sectionLanguage,
            'vocabulary': {
              for (final word in sectionReading.words) word.section: <Object>[],
            },
          };
    if (sectionReading != null) {
      final vocabulary = (doc as Map)['vocabulary'] as Map;
      for (final word in sectionReading.words) {
        (vocabulary[word.section] as List).add(
          sectionWordYaml(word, targetLanguage: sectionLanguage!),
        );
      }
    }
    if (doc is! Map) {
      throw const FormatException('YAML root must be a map/dictionary.');
    }
    if (isMarkdown &&
        (!doc.containsKey('vocabulary') ||
            (doc['vocabulary'] != null && doc['vocabulary'] is! Map))) {
      throw const FormatException(
        'Markdown frontmatter must contain a vocabulary map.',
      );
    }

    String title = defaultTitle ?? markdownTitle ?? 'Imported Lesson';
    String? unitTitle = defaultUnitTitle;
    String targetLang = 'ko';
    String nativeLang = 'en';
    // The `target:` of the file, if it has one.
    String? statedTargetLang;

    // 1. Detect lesson title & languages if present at root
    for (final key in doc.keys) {
      final keyStr = key.toString().trim();
      final lowerKey = keyStr.toLowerCase();
      if (lowerKey == 'lesson' || lowerKey == 'title' || lowerKey == 'name') {
        if (defaultTitle == null && markdownTitle == null) {
          title = doc[key].toString().trim();
        }
      } else if (lowerKey == 'target' ||
          lowerKey == 'target_lang' ||
          lowerKey == 'language') {
        targetLang = doc[key].toString().trim();
        statedTargetLang = targetLang;
      } else if (lowerKey == 'native' || lowerKey == 'native_lang') {
        nativeLang = doc[key].toString().trim();
      } else if (lowerKey == 'unit' || lowerKey == 'unit_title') {
        unitTitle ??= doc[key].toString().trim();
      }
    }

    final vocabulary = doc['vocabulary'];
    final vocabularyDoc = isMarkdown
        ? (vocabulary as Map? ?? const <dynamic, dynamic>{})
        : vocabulary is Map
        ? vocabulary
        : doc;
    final List<VocabItem> vocabList = [];
    final List<Sentence> allSentences = [];
    final List<MissingEmphasis> missingEmphasis = [];
    final locations = <VocabEntryLocation>[];
    final sentenceById = <String, Sentence>{};
    final sections = <String, VocabSectionLocation>{};
    final vocabularyPath = <Object?>[
      if (isMarkdown || vocabulary is Map) 'vocabulary',
    ];

    void parseSection(
      String sectionName,
      dynamic value,
      List<String> parent,
      List<Object?> yamlPath,
    ) {
      final sectionPath = [...parent, sectionName];
      if (value is Map) {
        sections.putIfAbsent(
          YamlParseResult.sectionKey(sectionPath),
          () => VocabSectionLocation(yamlPath, isList: false),
        );
        for (final child in value.entries) {
          parseSection(child.key.toString().trim(), child.value, sectionPath, [
            ...yamlPath,
            child.key,
          ]);
        }
        return;
      }
      if (value is! List) return;
      sections.putIfAbsent(
        YamlParseResult.sectionKey(sectionPath),
        () => VocabSectionLocation(yamlPath, isList: true),
      );

      for (var itemIndex = 0; itemIndex < value.length; itemIndex++) {
        final item = value[itemIndex];
        if (item is! Map) continue;
        Object? targetKey;
        Object? translationKey;
        Object? ttsKey;
        final formKeys = <String, Object?>{};
        final exampleLocations = <ExampleLocation>[];
        String targetWord = '';
        String translation = '';
        String reading = '';
        String simplified = '';
        String traditional = '';
        String hanja = '';
        String? vocabId;
        String? vocabAudio;
        String? ttsText;
        String notes = '';
        String disambiguation = '';
        final List<String> itemSentenceIds = [];
        final Map<String, SentenceEmphasis> itemEmphasis = {};

        for (final field in item.entries) {
          final key = field.key.toString().trim().toLowerCase();
          if (['id', 'vocab_id', 'vocabid'].contains(key)) {
            final value = field.value?.toString().trim();
            if (value != null && value.isNotEmpty) vocabId = value;
          }
        }

        if (item['audio'] != null) {
          vocabAudio = item['audio'].toString().trim();
        }
        if (item['notes'] != null) {
          notes = _notesText(item['notes']);
        }
        if (item['disambiguation'] != null) {
          disambiguation = item['disambiguation'].toString().trim();
        }

        for (final field in item.entries) {
          final fKey = field.key.toString().trim().toLowerCase();
          final fVal = field.value?.toString().trim() ?? '';

          if (knownLangKeys.contains(fKey) && targetWord.isEmpty) {
            targetWord = fVal;
            if (fVal.isNotEmpty) targetKey = field.key;
            if (fKey != 'target' && fKey != 'term' && fKey != 'word') {
              targetLang = fKey; // Infer target lang from key
            }
          } else if (knownNativeKeys.contains(fKey) && translation.isEmpty) {
            translation = fVal;
            if (fVal.isNotEmpty) translationKey = field.key;
            if (fKey == 'en' || fKey == 'eng') {
              nativeLang = 'en';
            }
          } else if (_isTtsKey(fKey) && fVal.isNotEmpty) {
            ttsText = fVal; // tts: alternate text for TTS
            ttsKey = field.key;
          } else if (readingKeys.contains(fKey) && reading.isEmpty) {
            reading = formText(field.value); // pinyin, or another reading
            if (reading.isNotEmpty) {
              formKeys[VocabSource.readingField] = field.key;
            }
          } else if (simplifiedKeys.contains(fKey) && simplified.isEmpty) {
            simplified = formText(field.value);
            if (simplified.isNotEmpty) {
              formKeys[VocabSource.simplifiedField] = field.key;
            }
          } else if (traditionalKeys.contains(fKey) && traditional.isEmpty) {
            traditional = formText(field.value);
            if (traditional.isNotEmpty) {
              formKeys[VocabSource.traditionalField] = field.key;
            }
          } else if (hanjaKeys.contains(fKey) && hanja.isEmpty) {
            hanja = formText(field.value);
            if (hanja.isNotEmpty) {
              formKeys[VocabSource.hanjaField] = field.key;
            }
          }
        }

        if (item['examples'] is List) {
          final examples = item['examples'] as List;
          for (var exIndex = 0; exIndex < examples.length; exIndex++) {
            final ex = examples[exIndex];
            if (ex is! Map) continue;
            final (
              target: exTarget,
              translation: exTrans,
              targetKey: exTargetKey,
              translationKey: exTransKey,
              audio: exAudio,
              tts: exTts,
              notes: exNotes,
            ) = _exampleFields(
              ex,
            );

            if (exTarget.isNotEmpty || exTrans.isNotEmpty) {
              // The sentence is shared and kept plain; the `**` marking is
              // this word's own.
              if (exTarget.isNotEmpty && !Sentence.hasEmphasis(exTarget)) {
                // Keep going: the whole file is reported at once.
                missingEmphasis.add((word: targetWord, sentence: exTarget));
                continue;
              }
              final sentence = Sentence(
                targetText: Sentence.stripEmphasis(exTarget),
                translationText: Sentence.stripEmphasis(exTrans),
                audioUrl: exAudio,
                ttsText: exTts,
                notes: exNotes,
              );
              allSentences.add(sentence);
              sentenceById[sentence.id] = sentence;
              itemSentenceIds.add(sentence.id);
              exampleLocations.add(
                ExampleLocation(
                  index: exIndex,
                  sentenceId: sentence.id,
                  targetKey: exTargetKey,
                  translationKey: exTransKey,
                ),
              );
              itemEmphasis[sentence.id] = SentenceEmphasis(
                target: exTarget,
                translation: exTrans,
              );
            }
          }
        }

        if (targetWord.isNotEmpty || translation.isNotEmpty) {
          final id =
              vocabId ?? _generatedVocabId(targetLang, targetWord, translation);
          final vocab = VocabItem(
            id: id,
            idIsExplicit: vocabId != null,
            targetWord: targetWord,
            translation: translation,
            reading: reading,
            simplified: simplified,
            traditional: traditional,
            hanja: hanja,
            pos: sectionPath.last,
            sectionPath: sectionPath,
            audioUrl: vocabAudio,
            ttsText: ttsText,
            notes: notes,
            disambiguation: disambiguation,
            sentenceIds: itemSentenceIds,
            sentenceEmphasis: itemEmphasis,
          );
          vocab.source = VocabSource(
            targetWord: targetWord,
            translation: translation,
            reading: reading,
            simplified: simplified,
            traditional: traditional,
            hanja: hanja,
            sectionPath: sectionPath,
            examples: [
              for (final id in itemSentenceIds)
                vocab.exampleKey(sentenceById[id]!),
            ],
          );
          vocabList.add(vocab);
          locations.add(
            VocabEntryLocation(
              path: [...yamlPath, itemIndex],
              targetKey: targetKey,
              translationKey: translationKey,
              ttsKey: ttsKey,
              formKeys: formKeys,
              examples: exampleLocations,
              hasExamples: item['examples'] is List,
            ),
          );
        }
      }
    }

    for (final entry in vocabularyDoc.entries) {
      final sectionName = entry.key.toString().trim();
      if (sectionName.isNotEmpty) {
        parseSection(sectionName, entry.value, const [], [
          ...vocabularyPath,
          entry.key,
        ]);
      }
    }

    // Entries keyed by a language (`zh:`) say the language but not the region
    // or script. The file's `target: zh-TW` says both, so it is kept when it
    // is that same language: the region picks the voice and tells which
    // characters the lesson is written in. A region that says nothing more
    // than the language (`ko-KR`, `ja-JP`) is dropped. Generated ids were
    // made from the language as it was read above, and still are.
    final stated = statedTargetLang;
    final lessonTargetLang = Lesson.withoutDefaultRegion(
      stated != null &&
              stated.toLowerCase() != targetLang &&
              Lesson.languageCodeOf(stated) == targetLang
          ? stated
          : targetLang,
    );

    final lesson = Lesson(
      title: title,
      unitTitle: unitTitle,
      targetLanguage: lessonTargetLang,
      nativeLanguage: nativeLang,
      vocabularies: vocabList,
      markdownContent: markdownContent,
      fileName: _markdownFileName(sourcePath),
      fileFolder: _markdownFileName(sourcePath) == null
          ? null
          : _folderOf(sourcePath!),
    );

    if (missingEmphasis.isNotEmpty) {
      throw MissingEmphasisException(missingEmphasis);
    }

    // Link sentence lessonId
    for (final s in allSentences) {
      s.lessonId = lesson.id;
    }

    return YamlParseResult(
      lesson: lesson,
      sentences: allSentences,
      locations: locations,
      sections: sections,
      vocabularyPath: vocabularyPath,
      vocabularySection: removedVocabularySection,
      wordsFromSection: wordsFromSection,
    );
  }

  /// Whether [markdown], text without frontmatter, is a lesson read from
  /// its `## Vocabulary` section: it has one, and is not plain YAML (where
  /// `## Vocabulary` would be a comment).
  static bool isSectionOnlyMarkdown(String markdown) {
    final source = markdown.trim();
    if (source.startsWith('---') ||
        !vocabularySectionPattern.hasMatch(source)) {
      return false;
    }
    try {
      return loadYaml(source) is! Map;
    } on YamlException {
      return true;
    }
  }

  /// Whether [text], typed or pasted into Add Lessons, is Markdown with no
  /// source of words: no `vocabulary:` in its frontmatter (or no frontmatter
  /// at all), and no `## Vocabulary` section. Such text fails to parse with a
  /// YAML error that means nothing to its writer (`---` rules in pasted
  /// Markdown read as YAML documents), so the import screen offers to give
  /// it a `vocabulary:` instead. Plain YAML is not Markdown, and keeps its
  /// own errors.
  static bool needsVocabulary(String text) {
    final source = text.trim();
    if (source.isEmpty) return false;
    final span = frontmatterSpan(source);
    if (span != null) {
      Object? doc;
      try {
        doc = loadYaml(source.substring(span.$1, span.$2));
      } on YamlException {
        doc = null;
      }
      if (doc is Map) return !doc.containsKey('vocabulary');
      // Not YAML: the `---` lines are horizontal rules of plain Markdown.
    }
    if (isSectionOnlyMarkdown(source)) return false;
    try {
      return loadYaml(source) is! Map;
    } on YamlException {
      return true;
    }
  }

  /// Whether a Markdown file found in a folder or ZIP is a lesson: it has
  /// frontmatter with a `vocabulary:` key, or no frontmatter and a
  /// `## Vocabulary` section. Frontmatter without `vocabulary:` marks a page
  /// that is not a lesson, such as a VitePress `index.md`.
  static bool isLessonMarkdown(String markdown) {
    final source = markdown.trim();
    if (source.startsWith('---')) {
      try {
        return hasVocabularyFrontmatter(source);
      } on Exception {
        return false;
      }
    }
    return isSectionOnlyMarkdown(source);
  }

  /// The heading the text of a `## Vocabulary` section that is not about one
  /// word is kept under, when its words are read from it.
  static const vocabularyNotesHeading = '## Vocabulary notes';

  /// [body], a lesson's Markdown, with its `## Vocabulary` sections replaced
  /// by [notes] under [vocabularyNotesHeading], or removed when [notes] is
  /// empty.
  static String withVocabularyNotes(String body, String notes) {
    var replaced = false;
    final kept = notes.trim();
    return body.replaceAllMapped(vocabularySectionPattern, (_) {
      // Every section's notes are in [notes]: keep them once.
      if (replaced || kept.isEmpty) return '';
      replaced = true;
      return '\n$vocabularyNotesHeading\n\n$kept\n';
    });
  }

  /// The language of a `## Vocabulary` section with no `target:` to say it:
  /// Korean if it has Hangul, Japanese if it has kana, Chinese if it has Han
  /// characters, and otherwise Korean, the app's default.
  static String guessSectionLanguage(String section) {
    if (RegExp(r'\p{Script=Hangul}', unicode: true).hasMatch(section)) {
      return 'ko';
    }
    if (_kana.hasMatch(section)) return 'ja';
    if (_han.hasMatch(section)) return 'zh';
    return 'ko';
  }

  /// A reading or form field's value as a word saves it: a YAML list of
  /// alternatives (`traditional: [臺灣, 台灣]`) joined by
  /// [VocabItem.variantsSeparator], anything else as its text.
  static String formText(Object? value) => value is List
      ? [
          for (final item in value)
            if ((item?.toString().trim() ?? '').isNotEmpty)
              item.toString().trim(),
        ].join(VocabItem.variantsSeparator)
      : value?.toString().trim() ?? '';

  /// A reading or form as a lesson file writes it: one string, or a YAML
  /// list when it has more than one alternative ([VocabItem.variantsOf]).
  static Object formYaml(String value) {
    final variants = VocabItem.variantsOf(value);
    return switch (variants) {
      [] => '',
      [final single] => single,
      _ => variants,
    };
  }

  /// The key entries are written under for [language]: the language alone,
  /// `zh` for `zh-TW` (docs/lesson-format.md).
  static String languageKey(String language) =>
      language.split(RegExp('[-_]')).first.trim().toLowerCase();

  /// The frontmatter entry for [word]: the word and its meaning under the
  /// lesson's language keys, then its reading (`pinyin` in a Chinese
  /// lesson), other forms, notes and examples. An example in which the word
  /// is not marked in `**` and cannot be found to mark becomes a note.
  static Map<String, Object> sectionWordYaml(
    SectionWord word, {
    required String targetLanguage,
    String nativeLanguage = 'en',
  }) {
    final targetKey = languageKey(targetLanguage);
    final nativeKey = languageKey(nativeLanguage);
    final language = targetLanguage.toLowerCase();
    final notes = [...word.notes];
    final examples = <Map<String, Object>>[];
    for (final example in word.examples) {
      final sentence = emphasizeWord(
        example.sentence,
        word.word,
        alternatives: word.forms.values.expand(VocabItem.variantsOf),
        language: language,
      );
      if (sentence == null) {
        notes.add(
          'Example: ${example.sentence}'
          '${example.translation.isEmpty ? '' : ' — ${example.translation}'}',
        );
        continue;
      }
      examples.add({
        targetKey: sentence,
        if (example.translation.isNotEmpty) nativeKey: example.translation,
        'notes': ?_sectionNotesValue(example.notes),
      });
    }
    return {
      targetKey: word.word,
      if (word.reading.isNotEmpty)
        (targetKey == 'zh' ? 'pinyin' : 'reading'): formYaml(word.reading),
      for (final MapEntry(:key, :value) in word.forms.entries)
        if (value.isNotEmpty && value != word.word) key: formYaml(value),
      nativeKey: word.meaning,
      'notes': ?_sectionNotesValue(notes),
      if (examples.isNotEmpty) 'examples': examples,
    };
  }

  /// Notes as the frontmatter writes them: one string, a list of
  /// paragraphs, or null for none.
  static Object? _sectionNotesValue(List<String> notes) {
    final kept = [
      for (final note in notes)
        if (note.trim().isNotEmpty) note.trim(),
    ];
    if (kept.isEmpty) return null;
    return kept.length == 1 ? kept.single : kept;
  }

  /// A `## Vocabulary` section of a lesson's Markdown body: from that heading
  /// to a `<!-- /Vocabulary -->` line, the next `## ` heading or the end.
  /// Import leaves it out of the lesson.
  static final vocabularySectionPattern = RegExp(
    r'(?:^|\r?\n)## Vocabulary(?=\r?\n|$)[^]*?'
    r'(?:\r?\n<!-- /Vocabulary -->(?=\r?\n|$)|(?=\r?\n## |$))',
  );

  /// A `##` heading that looks like a Vocabulary section's but isn't one, so
  /// its words are read as lesson text: `## Vocabularies`, or `## vocabulary`
  /// in another case. Only `## Vocabulary` starts a section. Null when
  /// [markdown] has none; otherwise the heading, as written.
  static String? nearMissVocabularyHeading(String markdown) {
    for (final match in RegExp(
      r'^##[ \t]+(vocabular(?:y|ies))[ \t]*:?[ \t]*$',
      multiLine: true,
      caseSensitive: false,
    ).allMatches(markdown)) {
      final heading = match[0]!.trim();
      if (heading != '## Vocabulary') return heading;
    }
    return null;
  }

  /// The text of the `## Vocabulary` sections of [markdown], a lesson's
  /// Markdown body, joined, without their headings and closing comments.
  /// Null when it has none.
  static String? vocabularySectionOf(String markdown) {
    if (!vocabularySectionPattern.hasMatch(markdown)) return null;
    return [
      for (final match in vocabularySectionPattern.allMatches(markdown))
        _vocabularySectionText(match[0]!),
    ].where((text) => text.isNotEmpty).join('\n\n');
  }

  /// The text of a [vocabularySectionPattern] match, without its heading and
  /// closing comment.
  static String _vocabularySectionText(String match) => match
      .replaceFirst(RegExp(r'^\r?\n?## Vocabulary'), '')
      .replaceFirst(RegExp(r'\r?\n<!-- /Vocabulary -->$'), '')
      .trim();

  /// Reads the words of a `## Vocabulary` section ([YamlParseResult
  /// .vocabularySection]) without an AI, by the rules in
  /// docs/lesson-format.md (*Reading a Vocabulary section*): list items
  /// and table rows, with readings, other written forms, notes and examples. [targetLanguage] is the lesson's (`zh-TW`,
  /// `ko`), which decides what a bracketed form after a word is.
  static VocabularySectionReading parseVocabularySection(
    String section, {
    String targetLanguage = 'ko',
  }) {
    final language = targetLanguage.trim().toLowerCase();
    final words = <SectionWord>[];
    final unread = <String>[];
    final kept = <String>[];
    var current = 'words';
    String? heading;

    void keep(String line) {
      if (heading != null) {
        if (kept.isNotEmpty && kept.last.trim().isNotEmpty) kept.add('');
        kept
          ..add(heading!)
          ..add('');
        heading = null;
      }
      kept.add(line);
    }

    SectionWord? entry;
    var entryIndent = 0;
    SectionExample? example;
    var exampleIndent = 0;
    List<String?>? columns;
    String? pendingHeader;
    var inTable = false;

    void addRow(String line, List<String?>? roles) {
      final row = _tableRow(line, roles, current, language);
      if (row == null) {
        unread.add(line);
        keep(line);
      } else {
        words.add(row);
      }
    }

    for (final raw in section.split(RegExp(r'\r?\n'))) {
      final line = raw.trim();
      if (!line.startsWith('|')) {
        if (pendingHeader != null) addRow(pendingHeader, null);
        pendingHeader = null;
        inTable = false;
        columns = null;
      }
      if (line.isEmpty) {
        if (entry == null && heading == null && kept.isNotEmpty) {
          if (kept.last.isNotEmpty) kept.add('');
        }
        continue;
      }
      final indent = _indentOf(raw);

      final headingMatch = RegExp(r'^#{3,6}\s+(.+)$').firstMatch(line);
      if (headingMatch != null) {
        entry = null;
        final name = _sectionSlug(headingMatch[1]!);
        if (name.isNotEmpty) current = name;
        heading = line;
        continue;
      }

      if (line.startsWith('|')) {
        entry = null;
        if (!inTable) {
          inTable = true;
          pendingHeader = line;
          continue;
        }
        final isRule = _tableCells(line)
            .every((cell) => RegExp(r'^:?-{3,}:?$').hasMatch(cell));
        if (pendingHeader != null) {
          if (isRule) {
            columns = _tableRoles(_tableCells(pendingHeader), language);
          } else {
            addRow(pendingHeader, null);
          }
          pendingHeader = null;
          if (isRule) continue;
        }
        if (!isRule) addRow(line, columns);
        continue;
      }

      final item = _listItem.firstMatch(line);
      final text = item?[1] ?? line;
      if (entry != null && indent > entryIndent) {
        if (example != null && indent > exampleIndent) {
          final note = _labelled(_noteLabel, text);
          if (note == null && example.translation.isEmpty) {
            example = _withTranslation(example, _plainSectionText(text));
            entry.examples[entry.examples.length - 1] = example;
          } else {
            example.notes.add(note ?? text);
          }
          continue;
        }
        example = _nestedLine(entry, text, language);
        exampleIndent = indent;
        continue;
      }
      entry = null;
      example = null;
      final parsed = item == null
          ? null
          : _entryLine(item[1]!, current, language);
      if (parsed != null) {
        words.add(parsed);
        entry = parsed;
        entryIndent = indent;
        continue;
      }
      if (item != null) unread.add(line);
      keep(raw.trimRight());
    }
    if (pendingHeader != null) addRow(pendingHeader, null);
    return VocabularySectionReading(
      words: words,
      unread: unread,
      notes: kept.join('\n').trim(),
    );
  }

  static final _listItem = RegExp(r'^(?:[-*+]|\d+[.)])\s+(.+)$');
  static final _han = RegExp(r'\p{Script=Han}', unicode: true);
  static final _kana = RegExp(
    r'[\p{Script=Hiragana}\p{Script=Katakana}]',
    unicode: true,
  );
  static final _latin = RegExp(r'\p{Script=Latin}', unicode: true);
  static final _noteLabel = RegExp(
    r'^(?:notes?|usage|注意?|备注|備註|说明|說明|참고|메모|メモ|注釈)\s*[:：]\s*',
    caseSensitive: false,
  );
  static final _exampleLabel = RegExp(
    r'^(?:examples?\s*[:：]|e\.g\.,?|ex\.|例句?\s*[:：]?|예문\s*[:：]?|예\s*[:：])\s*',
    caseSensitive: false,
  );

  /// Separates a word from its meaning in a list item.
  /// A dash `—` or `–` needs no spaces around it (`学生（がくせい）—
  /// student`); a hyphen or `=` does.
  static final _wordSeparator = RegExp(
    r'\s*[—–]+\s*|\s+[=-]+\s+|\s*：\s*|\s*:\s+|\t+',
  );

  /// Separates a sentence from its translation: not `:`, which sentences
  /// have.
  static final _sentenceSeparator = RegExp(r'\s+[—–=-]+\s+|\t+');

  /// A bracketed group at the end of a text: `(…)`, `（…）`, `[…]`, `【…】`.
  static final _trailingGroup = RegExp(
    r'\s*(?:\(([^()]*)\)|（([^（）]*)）|\[([^\[\]]*)\]|【([^【】]*)】)\s*$',
  );

  /// The first match of [pattern] in [text] that is not inside brackets,
  /// so `老师（繁：老師）：teacher` splits at its last `：`.
  static RegExpMatch? _outsideBrackets(RegExp pattern, String text) {
    for (final match in pattern.allMatches(text)) {
      var depth = 0;
      for (final char in text.substring(0, match.start).split('')) {
        if ('(（[【'.contains(char)) depth++;
        if (')）]】'.contains(char) && depth > 0) depth--;
      }
      if (depth == 0) return match;
    }
    return null;
  }

  static int _indentOf(String raw) {
    var width = 0;
    for (final char in raw.split('')) {
      if (char == ' ') {
        width++;
      } else if (char == '\t') {
        width += 4;
      } else {
        break;
      }
    }
    return width;
  }

  static String _sectionSlug(String name) =>
      _plainSectionText(name)
          .toLowerCase()
          .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), '_')
          .replaceAll(RegExp(r'^_+|_+$'), '');

  /// [text] after a [label], or null when it does not start with one.
  static String? _labelled(RegExp label, String text) {
    final match = label.firstMatch(text);
    if (match == null) return null;
    final rest = text.substring(match.end).trim();
    return rest.isEmpty ? null : rest;
  }

  /// A word's list item, `WORD (forms…) — MEANING`, or null if it is not one.
  static SectionWord? _entryLine(String text, String section, String language) {
    final separator = _outsideBrackets(_wordSeparator, text);
    if (separator == null) return null;
    final head = _wordAndForms(text.substring(0, separator.start), language);
    final meaning = _plainSectionText(text.substring(separator.end));
    if (head.word.isEmpty || meaning.isEmpty) return null;
    return SectionWord(
      section: section,
      word: head.word,
      meaning: meaning,
      reading: head.reading,
      forms: head.forms,
      notes: head.notes,
    );
  }

  /// A word and the bracketed groups after it, sorted into its reading,
  /// other written forms and notes.
  static ({
    String word,
    String reading,
    Map<String, String> forms,
    List<String> notes,
  })
  _wordAndForms(String text, String language) {
    var word = _plainSectionText(text);
    final groups = <String>[];
    for (
      var match = _trailingGroup.firstMatch(word);
      match != null && match.start > 0;
      match = _trailingGroup.firstMatch(word)
    ) {
      groups.insert(
        0,
        (match[1] ?? match[2] ?? match[3] ?? match[4] ?? '').trim(),
      );
      word = word.substring(0, match.start).trim();
    }
    var reading = '';
    final forms = <String, String>{};
    final notes = <String>[];
    for (final group in groups.where((group) => group.isNotEmpty)) {
      final form = _classifyForm(group, word, language);
      if (form == null) {
        notes.add(group);
      } else if (form.key == 'reading') {
        if (reading.isEmpty) reading = form.value;
      } else if (form.value != word) {
        forms.putIfAbsent(form.key, () => form.value);
      }
    }
    return (word: word, reading: reading, forms: forms, notes: notes);
  }

  /// What a bracketed [group] after [word] is: `reading`, `simplified`,
  /// `traditional` or `hanja`, with its text. Null for anything else, which
  /// becomes a note.
  static MapEntry<String, String>? _classifyForm(
    String group,
    String word,
    String language,
  ) {
    final base = language.split(RegExp('[-_]')).first;
    final labelled = RegExp(
      r'^(pinyin|拼音|reading|読み|读音|讀音|'
      r'trad(?:itional)?\.?|繁(?:體|体)?(?:字)?|'
      r'simp(?:lified)?\.?|简(?:体)?(?:字)?|簡(?:體)?(?:字)?|'
      r'hanja|漢字|한자)\s*[:：]?\s*(.+)$',
      caseSensitive: false,
    ).firstMatch(group);
    if (labelled != null) {
      final label = labelled[1]!.toLowerCase();
      final value = labelled[2]!.trim();
      if (RegExp(r'^(pinyin|拼音|reading|読み|读音|讀音)$').hasMatch(label)) {
        return MapEntry('reading', value);
      }
      if (label.startsWith('trad') || label.startsWith('繁')) {
        return MapEntry('traditional', value);
      }
      if (label.startsWith('simp') ||
          label.startsWith('简') ||
          label.startsWith('簡')) {
        return MapEntry('simplified', value);
      }
      return MapEntry('hanja', value);
    }
    final onlyHan = RegExp(
      r'^[\p{Script=Han}\s]+$',
      unicode: true,
    ).hasMatch(group);
    if (base == 'zh') {
      if (onlyHan) {
        final traditionalLesson = RegExp(r'^zh[-_](tw|hk|mo|hant)')
            .hasMatch(language);
        return MapEntry(
          traditionalLesson ? 'simplified' : 'traditional',
          group,
        );
      }
      // Pinyin has tone marks or tone numbers: `xuésheng`, `xue2sheng5`.
      final pinyin = RegExp(
        r"^[a-zA-ZāáǎàēéěèīíǐìōóǒòūúǔùǖǘǚǜüĀÁǍÀĒÉĚÈĪÍǏÌŌÓǑÒŪÚǓÙÜ1-5\s'·-]+$",
      );
      if (pinyin.hasMatch(group) &&
          RegExp(r'[āáǎàēéěèīíǐìōóǒòūúǔùǖǘǚǜĀÁǍÀĒÉĚÈĪÍǏÌŌÓǑÒŪÚǓÙ]|[a-zü][1-5]')
              .hasMatch(group)) {
        return MapEntry('reading', group);
      }
    } else if (base == 'ko' &&
        _han.hasMatch(group) &&
        !_latin.hasMatch(group)) {
      return MapEntry('hanja', group);
    } else if (base == 'ja' &&
        _kana.hasMatch(group) &&
        !_han.hasMatch(group) &&
        !_latin.hasMatch(group)) {
      return MapEntry('reading', group);
    }
    return null;
  }

  /// Adds a line nested under [entry] to it, as a note or an example; the
  /// example, when it is one, for lines nested under it in turn.
  static SectionExample? _nestedLine(
    SectionWord entry,
    String text,
    String language,
  ) {
    final note = _labelled(_noteLabel, text);
    if (note != null) {
      entry.notes.add(note);
      return null;
    }
    // An example is labelled, marks the word in `**`, or has the word and
    // a translation. Any other line is a note.
    final labelled = _labelled(_exampleLabel, text);
    final example = _exampleText(labelled ?? text, entry, language);
    if (example != null &&
        (labelled != null ||
            text.contains('**') ||
            example.translation.isNotEmpty)) {
      entry.examples.add(example);
      return example;
    }
    entry.notes.add(labelled == null ? text : 'Example: $labelled');
    return null;
  }

  /// An example, `SENTENCE — TRANSLATION` or `SENTENCE (TRANSLATION)`, with
  /// [entry]'s word marked in `**`. Null when the word cannot be found in
  /// the sentence to mark it.
  static SectionExample? _exampleText(
    String text,
    SectionWord entry,
    String language,
  ) {
    var sentence = text.trim();
    var translation = '';
    final separator = _outsideBrackets(_sentenceSeparator, sentence);
    if (separator != null) {
      translation = sentence.substring(separator.end).trim();
      sentence = sentence.substring(0, separator.start).trim();
    } else {
      final group = _trailingGroup.firstMatch(sentence);
      final inner = group == null
          ? null
          : (group[1] ?? group[2] ?? group[3] ?? group[4])?.trim();
      final before = group == null ? '' : sentence.substring(0, group.start);
      // A translation in brackets: Latin text after a sentence that is not.
      if (inner != null &&
          inner.isNotEmpty &&
          _latin.hasMatch(inner) &&
          !_latin.hasMatch(before.replaceAll(RegExp(r'\*\*'), ''))) {
        translation = inner;
        sentence = before.trim();
      }
    }
    final emphasized = sentence.contains('**')
        ? sentence
        : emphasizeWord(
            sentence,
            entry.word,
            alternatives: entry.forms.values.expand(VocabItem.variantsOf),
            language: language,
          );
    if (emphasized == null || emphasized.trim().isEmpty) return null;
    return SectionExample(
      sentence: emphasized.replaceAll('`', '').trim(),
      translation: translation.replaceAll('`', '').trim(),
    );
  }

  static SectionExample _withTranslation(
    SectionExample example,
    String translation,
  ) => SectionExample(
    sentence: example.sentence,
    translation: translation,
    notes: example.notes,
  );

  /// [sentence] with the first place [word] (or one of its [alternatives]
  /// forms) is in it marked in `**`, or null when it is not in it. For a
  /// Korean `-다` word, its stem is looked for too (`먹다` in `먹어요`), and
  /// for a `-하다` verb the part before `하다` (`공부하다` in `공부해요`).
  static String? emphasizeWord(
    String sentence,
    String word, {
    Iterable<String> alternatives = const [],
    String language = '',
  }) {
    if (sentence.contains('**')) return sentence;
    final candidates = <String>[
      word,
      ...alternatives,
      if (language.startsWith('ko') && word.endsWith('하다') && word.length > 2)
        word.substring(0, word.length - 2),
      if (language.startsWith('ko') && word.endsWith('다') && word.length > 1)
        word.substring(0, word.length - 1),
    ].map((candidate) => candidate.trim()).where((c) => c.isNotEmpty);
    for (final candidate in candidates) {
      final at = sentence.toLowerCase().indexOf(candidate.toLowerCase());
      if (at == -1) continue;
      final end = at + candidate.length;
      return '${sentence.substring(0, at)}**${sentence.substring(at, end)}**'
          '${sentence.substring(end)}';
    }
    return null;
  }

  static List<String> _tableCells(String line) {
    final cells = line.split('|').map((cell) => cell.trim()).toList();
    return cells.sublist(
      1,
      line.length > 1 && line.endsWith('|') ? cells.length - 1 : null,
    );
  }

  /// What each column of a table with these [headers] holds: `word`,
  /// `reading`, `simplified`, `traditional`, `hanja`, `meaning`, `example`,
  /// `exampleTranslation`, `notes` or `pos`. A column it does not know is
  /// null, and its cells become notes headed by its name.
  static List<String?> _tableRoles(List<String> headers, String language) {
    final base = language.split(RegExp('[-_]')).first;
    String? role(String header) {
      final h = _plainSectionText(header).toLowerCase().trim();
      bool any(List<String> names) => names.any(h.contains);
      final aboutExample = any(['example', 'sentence', '例', '예문']);
      if (aboutExample &&
          any(['translation', 'english', 'meaning', '翻译', '翻譯', '意思'])) {
        return 'exampleTranslation';
      }
      if (aboutExample) return 'example';
      if (any(['pinyin', '拼音', 'reading', 'kana', '読み', '读音', '讀音'])) {
        return 'reading';
      }
      if (any(['traditional', '繁'])) return 'traditional';
      if (any(['simplified', '简', '簡'])) return 'simplified';
      if (any(['hanja', '한자']) || (base == 'ko' && h == '漢字')) {
        return 'hanja';
      }
      if (h == 'pos' || any(['part of speech', '词性', '詞性', '품사'])) {
        return 'pos';
      }
      if (any(['note', 'usage', '注', '备注', '備註', '참고'])) return 'notes';
      if (any([
        'meaning',
        'translation',
        'english',
        'definition',
        '意思',
        '意味',
        '뜻',
        '의미',
      ])) {
        return 'meaning';
      }
      if (any([
            'word',
            'term',
            'vocab',
            'korean',
            'chinese',
            'japanese',
            'hanzi',
            '汉字',
            '漢字',
            '词',
            '詞',
            '단어',
            '単語',
          ]) ||
          h == base) {
        return 'word';
      }
      return null;
    }

    final roles = headers.map(role).toList();
    // The first columns are the word and its meaning unless named otherwise.
    if (!roles.contains('word') && roles.isNotEmpty && roles[0] == null) {
      roles[0] = 'word';
    }
    if (!roles.contains('meaning')) {
      final free = roles.indexWhere((r) => r == null);
      if (free != -1) roles[free] = 'meaning';
    }
    return [
      for (var i = 0; i < roles.length; i++)
        roles[i] ?? 'note:${_plainSectionText(headers[i])}',
    ];
  }

  /// A word from a table row, with columns as [roles] says, or the word and
  /// its meaning in the first two columns without them. Null if the row has
  /// no word or no meaning.
  static SectionWord? _tableRow(
    String line,
    List<String?>? roles,
    String section,
    String language,
  ) {
    final cells = _tableCells(line);
    roles ??= ['word', 'meaning', for (var i = 2; i < cells.length; i++) null];
    final values = <String, String>{};
    final notes = <String>[];
    for (var i = 0; i < cells.length && i < roles.length; i++) {
      final role = roles[i];
      final value = cells[i].replaceAll(RegExp(r'<br\s*/?>'), '\n').trim();
      if (value.isEmpty || value == '-' || role == null) continue;
      if (role.startsWith('note:')) {
        final name = role.substring(5);
        notes.add(name.isEmpty ? value : '$name: $value');
      } else if (role == 'notes') {
        notes.add(value);
      } else {
        values.putIfAbsent(role, () => value);
      }
    }
    final head = _wordAndForms(values['word'] ?? '', language);
    final meaning = _plainSectionText(values['meaning'] ?? '');
    if (head.word.isEmpty || meaning.isEmpty) return null;
    final forms = {
      ...head.forms,
      for (final key in ['simplified', 'traditional', 'hanja'])
        if (values[key] case final value? when value != head.word)
          key: _plainSectionText(value),
    };
    final word = SectionWord(
      section: values['pos'] == null || _sectionSlug(values['pos']!).isEmpty
          ? section
          : _sectionSlug(values['pos']!),
      word: head.word,
      meaning: meaning,
      reading: values['reading'] == null
          ? head.reading
          : _plainSectionText(values['reading']!),
      forms: forms,
      notes: [...head.notes, ...notes],
    );
    if (values['example'] case final text?) {
      final example = _exampleText(
        values['exampleTranslation'] == null
            ? text
            : '$text\t${values['exampleTranslation']}',
        word,
        language,
      );
      if (example == null) {
        word.notes.add('Example: $text');
      } else {
        word.examples.add(example);
      }
    }
    return word;
  }

  /// [text] without Markdown emphasis and code marks.
  static String _plainSectionText(String text) => text
      .replaceAll(RegExp(r'\*\*|__|`'), '')
      .replaceAll(RegExp(r'^[*_]+|[*_]+$'), '')
      .trim();

  /// Where the YAML of [markdown]'s frontmatter starts and ends in it: the
  /// text between the `---` lines, without them. Null when there is no
  /// frontmatter. Everything outside the span is the rest of the file, which
  /// stays as it is when only the frontmatter is rewritten.
  static (int, int)? frontmatterSpan(String markdown) {
    final lead = markdown.length - markdown.trimLeft().length;
    if (!markdown.startsWith('---', lead)) return null;
    final lineEnd = markdown.indexOf('\n', lead);
    if (lineEnd == -1 || markdown.substring(lead + 3, lineEnd).trim() != '') {
      return null;
    }
    final closing = RegExp(r'\r?\n---\s*(?:\r?\n|$)')
        .firstMatch(markdown.substring(lead + 3));
    if (closing == null) return null;
    final start = lineEnd + 1;
    // Keep the line break that ends the last line of YAML.
    final end = lead + 3 + closing.start + closing[0]!.indexOf('---');
    return end < start ? null : (start, end);
  }

  /// [markdown] after its frontmatter (the `---` lines included): the lesson
  /// text, as the import editor's Preview shows it. [markdown] itself when
  /// it has no frontmatter.
  static String withoutFrontmatter(String markdown) {
    final span = frontmatterSpan(markdown);
    if (span == null) return markdown;
    final rest = markdown.indexOf('\n', span.$2);
    return rest == -1 ? '' : markdown.substring(rest + 1);
  }

  /// Two target words with the same key are the same word: they differ only
  /// in case or spacing.
  static String vocabularyKey(String word) =>
      word.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

  /// Keys that hold the Hanja of a Korean word in vocabulary YAML: its
  /// written form, where the Hangul is how it is read.
  static const hanjaKeys = ['hanja'];

  /// Keys that hold how a word is read in vocabulary YAML: the Hangul of a
  /// Korean word, or the reading of a word written in characters, such as the
  /// pinyin of a Chinese word.
  static const readingKeys = ['hangul', 'reading', 'pinyin'];

  /// Keys that hold the simplified and the traditional form of a Chinese
  /// word in vocabulary YAML.
  static const simplifiedKeys = ['simplified'];
  static const traditionalKeys = ['traditional'];

  /// Hanja (CJK ideographs).
  static final _hanja = RegExp(r'[\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF]');

  /// What tells [word] apart from words written alike in [korean] or another
  /// language.
  ///
  /// A Korean word's Hangul is how it is read, and its Hanja is how it is
  /// written. The `hangul` field ([KnownVocabulary.reading]) is always its
  /// reading; the `ko` field ([KnownVocabulary.word]) is its reading too
  /// unless it has Hanja in it, and then it is its form, as the `hanja` field
  /// is. It is compared under its reading, or its form if it has none.
  ///
  /// A word in another language is written as its target word, which it is
  /// compared under, and read as its `reading` or `pinyin`.
  static _WordIdentity _identity(KnownVocabulary word, {required bool korean}) {
    final target = word.word.trim();
    if (!korean) {
      return (
        key: vocabularyKey(target),
        form: target,
        reading: word.reading.trim(),
      );
    }
    final targetIsForm = _hanja.hasMatch(target);
    final form = word.hanja.trim().isNotEmpty
        ? word.hanja.trim()
        : targetIsForm
        ? target
        : '';
    final reading = word.reading.trim().isNotEmpty
        ? word.reading.trim()
        : targetIsForm
        ? ''
        : target;
    return (
      key: vocabularyKey(reading.isNotEmpty ? reading : form),
      form: form,
      reading: reading,
    );
  }

  /// Whether translations [a] and [b] have a meaning in common: a sense,
  /// split at commas, semicolons and slashes, that is the same once notes in
  /// parentheses, punctuation, case and a leading "to", "be" or article are
  /// set aside ("to be pretty" and "Pretty!" share one). A translation that is
  /// empty, or has no sense but "to be", has one in common with any.
  static bool meaningsOverlap(String a, String b) {
    final senses = _senses(a);
    final others = _senses(b);
    if (senses.isEmpty || others.isEmpty) return true;
    return senses.any(others.contains);
  }

  static Set<String> _senses(String meaning) => {
    for (final part
        in meaning
            .toLowerCase()
            .replaceAll(RegExp(r'\([^)]*\)|\[[^\]]*\]'), ' ')
            .split(RegExp(r'[,;/]')))
      if (part
              .replaceAll(RegExp(r'[^\p{L}\p{N}\s]+', unicode: true), ' ')
              .trim()
              .replaceAll(RegExp(r'\s+'), ' ')
              .replaceFirst(RegExp(r'^(to )?(be )?((a|an|the) )?'), '')
          case final sense when sense.isNotEmpty)
        sense,
  };

  /// [yaml], plain vocabulary YAML, without the entries that duplicate a word
  /// in [known] or an earlier entry in [yaml]. The rest of the text is kept
  /// as it is written, so only whole entries go, and a part of speech left
  /// with no entries goes too. YAML that cannot be read, and lists written in
  /// flow style (`[...]`), are left as they are.
  ///
  /// An entry duplicates a word written the same ([vocabularyKey]), the same
  /// Korean word read the same, unless both have a written form and the forms
  /// differ, or both have a reading and the readings differ: then they are
  /// different words, such as 사기 詐欺 (fraud) and 사기 士氣 (morale), or
  /// 行 xíng and 行 háng. See [_identity] for what a word's form and reading
  /// are. If their translations have no meaning in common
  /// ([meaningsOverlap]), the entry is kept but listed in
  /// [VocabularyYamlFilter.possibleDuplicates].
  ///
  /// [known] should only have words of [language], the language of the
  /// YAML: the same characters can be another word in another language, as
  /// 工夫 is.
  static VocabularyYamlFilter withoutKnownVocabulary(
    String yaml,
    Iterable<KnownVocabulary> known, {
    required String language,
  }) {
    final korean =
        language.trim().toLowerCase().split(RegExp(r'[-_]')).first == 'ko';
    final YamlNode root;
    try {
      root = loadYamlNode(yaml);
    } on YamlException {
      return VocabularyYamlFilter(
        yaml: yaml,
        keptEntries: const [],
        removed: const [],
      );
    }
    if (root is! YamlMap) {
      return VocabularyYamlFilter(
        yaml: yaml,
        keptEntries: const [],
        removed: const [],
      );
    }
    final vocabulary = root.nodes['vocabulary'];
    final sections = vocabulary is YamlMap ? vocabulary : root;

    final seen =
        <
          String,
          List<({KnownVocabulary word, _WordIdentity identity, bool inList})>
        >{};
    void remember(KnownVocabulary word, {required bool inList}) {
      final identity = _identity(word, korean: korean);
      if (identity.key.isEmpty) return;
      (seen[identity.key] ??= []).add((
        word: word,
        identity: identity,
        inList: inList,
      ));
    }

    for (final word in known) {
      remember(word, inList: false);
    }
    final kept = <KeptVocabularyEntry>[];
    final removed = <String>[];
    final possibleDuplicates = <PossibleDuplicate>[];
    final cuts = <(int, int)>[];

    // The start of the line [offset] is on.
    int lineStart(int offset) => yaml.lastIndexOf('\n', offset - 1) + 1;
    // Just after the end of the last line [node] has text on.
    int lineEndAfter(YamlNode node) {
      var end = node.span.end.offset;
      while (end > 0 && ' \t\r\n'.contains(yaml[end - 1])) {
        end--;
      }
      final newline = yaml.indexOf('\n', end);
      return newline == -1 ? yaml.length : newline + 1;
    }

    String? targetWord(YamlMap item) {
      for (final entry in item.entries) {
        final key = entry.key.toString().trim().toLowerCase();
        if (knownLangKeys.contains(key)) return entry.value?.toString() ?? '';
      }
      return null;
    }

    String field(YamlMap item, List<String> keys) {
      for (final entry in item.entries) {
        final key = entry.key.toString().trim().toLowerCase();
        if (keys.contains(key)) return formText(entry.value);
      }
      return '';
    }

    // Whether two forms, or two readings, do not tell words apart.
    // Alike when either is missing, or they have an alternative in common
    // (`shéi / shuí` and `shéi`).
    bool alike(String a, String b) {
      if (a.isEmpty || b.isEmpty) return true;
      Set<String> variants(String value) => {
        for (final variant in VocabItem.variantsOf(value))
          variant.replaceAll(RegExp(r'\s+'), '').toLowerCase(),
      };
      return variants(a).intersection(variants(b)).isNotEmpty;
    }

    void filterSection(YamlNode key, YamlNode value) {
      if (value is YamlMap) {
        for (final entry in value.nodes.entries) {
          filterSection(entry.key as YamlNode, entry.value);
        }
        return;
      }
      if (value is! YamlList) return;
      final block = value.style == CollectionStyle.BLOCK;
      final items = value.nodes;
      final gone = <int>[];
      for (var i = 0; i < items.length; i++) {
        final item = items[i];
        if (item is! YamlMap) continue;
        final word = targetWord(item)?.trim();
        if (word == null || word.isEmpty) continue;
        final entry = (
          word: word,
          meaning: field(item, knownNativeKeys),
          hanja: field(item, hanjaKeys),
          reading: field(item, readingKeys),
        );
        // Words compared under the same key whose forms and readings do not
        // tell them apart.
        final identity = _identity(entry, korean: korean);
        final same = [
          for (final other in seen[identity.key] ?? const [])
            if (alike(identity.form, other.identity.form) &&
                alike(identity.reading, other.identity.reading))
              other,
        ];
        final duplicate = same.any(
          (other) => meaningsOverlap(entry.meaning, other.word.meaning),
        );
        if (block && duplicate) {
          removed.add(word);
          gone.add(i);
          continue;
        }
        kept.add((word: word, section: key.value.toString().trim()));
        if (block && same.isNotEmpty) {
          // A word the learner has comes before one in the list.
          final other = same.firstWhere(
            (other) => !other.inList,
            orElse: () => same.first,
          );
          possibleDuplicates.add((
            word: word,
            meaning: entry.meaning,
            otherMeaning: other.word.meaning,
            inList: other.inList,
          ));
        }
        remember(entry, inList: true);
      }
      if (gone.isEmpty) return;
      if (gone.length == items.length) {
        // Nothing is left under this part of speech: its key goes too.
        cuts.add((lineStart(key.span.start.offset), lineEndAfter(value)));
        return;
      }
      for (final i in gone) {
        final start = lineStart(items[i].span.start.offset);
        final end = i + 1 < items.length
            ? lineStart(items[i + 1].span.start.offset)
            : lineEndAfter(items[i]);
        cuts.add((start, end));
      }
    }

    for (final entry in sections.nodes.entries) {
      filterSection(entry.key as YamlNode, entry.value);
    }

    var text = yaml;
    for (final (start, end) in cuts.reversed) {
      text = text.replaceRange(start, end, '');
    }
    return VocabularyYamlFilter(
      yaml: text,
      keptEntries: kept,
      removed: removed,
      possibleDuplicates: possibleDuplicates,
    );
  }

  /// The file name of a Markdown [path] (`unit-2/lesson-1.md` gives
  /// `lesson-1.md`), or null for other files.
  static String? _markdownFileName(String? path) {
    if (path == null) return null;
    final name = path.split(RegExp(r'[/\\]')).last.trim();
    return name.toLowerCase().endsWith('.md') && name.length > 3 ? name : null;
  }

  /// The folders of [path], `/`-separated (`unit-2/lesson-1.md` gives
  /// `unit-2`), or null for a file at the top.
  static String? _folderOf(String path) {
    final parts = path
        .split(RegExp(r'[/\\]'))
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty && part != '.')
        .toList();
    return parts.length < 2 ? null : parts.take(parts.length - 1).join('/');
  }

  /// The lesson a Markdown file at [sourcePath] is, without its vocabulary:
  /// its title (the first `#` heading, or the frontmatter's `title`), its
  /// folders ([defaultUnitTitle]) and its file and folder names. For a file
  /// that import skips because it has not changed, so the lesson made from
  /// it can still take its file path. Null if it is not a lesson file.
  static Lesson? lessonFileInfo(
    String markdown, {
    required String sourcePath,
    String? defaultUnitTitle,
  }) {
    final fileName = _markdownFileName(sourcePath);
    if (fileName == null || !isLessonMarkdown(markdown)) return null;
    final source = markdown.trim();
    final body = source.startsWith('---')
        ? _splitMarkdownFrontmatter(source).$2
        : source;
    final heading = RegExp(
      r'^#\s+(.+)$',
      multiLine: true,
    ).firstMatch(body)?.group(1)?.trim();
    if (heading == null) {
      // No heading: the title is in the frontmatter, so read it all.
      try {
        return parseLessonYaml(
          markdown,
          defaultUnitTitle: defaultUnitTitle,
          sourcePath: sourcePath,
        ).lesson;
      } on FormatException {
        return null;
      }
    }
    return Lesson(
      title: LessonLink.splitHeadingAttributes(heading).$1
          .replaceAll(r'\~', '~'),
      unitTitle: defaultUnitTitle,
      fileName: fileName,
      fileFolder: _folderOf(sourcePath),
    );
  }

  static bool hasVocabularyFrontmatter(String markdown) {
    final source = markdown.trim();
    if (!source.startsWith('---')) return false;
    final frontMatter = _splitMarkdownFrontmatter(source).$1;
    final doc = loadYaml(frontMatter);
    return doc is Map &&
        doc.containsKey('vocabulary') &&
        (doc['vocabulary'] == null || doc['vocabulary'] is Map);
  }

  static (String, String) _splitMarkdownFrontmatter(String markdown) {
    final closingDelimiter = RegExp(r'\r?\n---\s*(?:\r?\n|$)')
        .firstMatch(markdown.substring(3));
    if (closingDelimiter == null) {
      throw const FormatException(
        'Markdown frontmatter is missing its closing --- delimiter.',
      );
    }
    final delimiterStart = closingDelimiter.start + 3;
    final bodyStart = closingDelimiter.end + 3;
    return (
      markdown.substring(3, delimiterStart).trim(),
      markdown.substring(bodyStart),
    );
  }

  static String _generatedVocabId(
    String targetLanguage,
    String targetWord,
    String translation,
  ) {
    String normalize(String value) => value
        .replaceAll(RegExp(r'<[^>]*>'), ' ')
        .replaceAll(RegExp(r'[*_`~]'), '')
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    final identity = [
      normalize(targetLanguage),
      normalize(targetWord),
      normalize(translation),
    ].join('\u0000');
    return 'auto-${sha256.convert(utf8.encode(identity))}';
  }
}

/// `notes` may be one string or a list of strings (joined as paragraphs).
String _notesText(dynamic value) {
  if (value is List) {
    return value
        .map((note) => note.toString().trim())
        .where((note) => note.isNotEmpty)
        .join('\n\n');
  }
  return value.toString().trim();
}

/// `tts` holds alternate text for TTS. The old names `<lang>_text` (such as
/// `ko_text`) and `target_text` (written by older exports) are still read.
bool _isTtsKey(String key) =>
    key == 'tts' ||
    (key.endsWith('_text') &&
        YamlParserService.knownLangKeys.contains(
          key.substring(0, key.length - '_text'.length),
        ));
