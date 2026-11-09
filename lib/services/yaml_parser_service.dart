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

  YamlParseResult({required this.lesson, required this.sentences});
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
    var frontMatter = yamlString.trim();
    String? markdownTitle;
    String markdownContent = '';
    final isMarkdown = frontMatter.startsWith('---');
    if (isMarkdown && !allowMarkdown) {
      throw const FormatException(markdownNotAllowed);
    }
    if (isMarkdown) {
      final frontMatterParts = _splitMarkdownFrontmatter(frontMatter);
      final markdownBody = frontMatterParts.$2;
      markdownContent = markdownBody
          .replaceFirst(RegExp(r'\n## Vocabulary\r?\n[^]+?\r?\n## '), '\n## ')
          .trim();
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

    final doc = loadYaml(frontMatter);
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

    void parseSection(String sectionName, dynamic value, List<String> parent) {
      final sectionPath = [...parent, sectionName];
      if (value is Map) {
        for (final child in value.entries) {
          parseSection(child.key.toString().trim(), child.value, sectionPath);
        }
        return;
      }
      if (value is! List) return;

      for (final item in value) {
        if (item is! Map) continue;
        String targetWord = '';
        String translation = '';
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
            if (fKey != 'target' && fKey != 'term' && fKey != 'word') {
              targetLang = fKey; // Infer target lang from key
            }
          } else if (knownNativeKeys.contains(fKey) && translation.isEmpty) {
            translation = fVal;
            if (fKey == 'en' || fKey == 'eng') {
              nativeLang = 'en';
            }
          } else if (_isTtsKey(fKey) && fVal.isNotEmpty) {
            ttsText = fVal; // tts: alternate text for TTS
          }
        }

        if (item['examples'] is List) {
          final examples = item['examples'] as List;
          for (final ex in examples) {
            if (ex is! Map) continue;

            String exTarget = '';
            String exTrans = '';
            String? exAudio;
            String? exTts;
            String exNotes = '';

            if (ex['audio'] != null) {
              exAudio = ex['audio'].toString().trim();
            }
            if (ex['notes'] != null) {
              exNotes = _notesText(ex['notes']);
            }

            for (final exField in ex.entries) {
              final exKey = exField.key.toString().trim().toLowerCase();
              final exVal = exField.value?.toString().trim() ?? '';

              if (knownLangKeys.contains(exKey) && exTarget.isEmpty) {
                exTarget = exVal;
              } else if (knownNativeKeys.contains(exKey) && exTrans.isEmpty) {
                exTrans = exVal;
              } else if (_isTtsKey(exKey) && exVal.isNotEmpty) {
                exTts = exVal;
              }
            }

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
              itemSentenceIds.add(sentence.id);
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
            pos: sectionPath.last,
            sectionPath: sectionPath,
            audioUrl: vocabAudio,
            ttsText: ttsText,
            notes: notes,
            disambiguation: disambiguation,
            sentenceIds: itemSentenceIds,
            sentenceEmphasis: itemEmphasis,
          );
          vocabList.add(vocab);
        }
      }
    }

    for (final entry in vocabularyDoc.entries) {
      final sectionName = entry.key.toString().trim();
      if (sectionName.isNotEmpty) {
        parseSection(sectionName, entry.value, const []);
      }
    }

    final lesson = Lesson(
      title: title,
      unitTitle: unitTitle,
      targetLanguage: targetLang,
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

    return YamlParseResult(lesson: lesson, sentences: allSentences);
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
        if (keys.contains(key)) return entry.value?.toString().trim() ?? '';
      }
      return '';
    }

    // Whether two forms, or two readings, do not tell words apart.
    bool alike(String a, String b) =>
        a.isEmpty ||
        b.isEmpty ||
        a.replaceAll(RegExp(r'\s+'), '').toLowerCase() ==
            b.replaceAll(RegExp(r'\s+'), '').toLowerCase();

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

  /// The file name of a Markdown [path] (`unit-2/lesson-26.md` gives
  /// `lesson-26.md`), or null for other files.
  static String? _markdownFileName(String? path) {
    if (path == null) return null;
    final name = path.split(RegExp(r'[/\\]')).last.trim();
    return name.toLowerCase().endsWith('.md') && name.length > 3 ? name : null;
  }

  /// The folders of [path], `/`-separated (`unit-2/lesson-26.md` gives
  /// `unit-2`), or null for a file at the top.
  static String? _folderOf(String path) {
    final parts = path
        .split(RegExp(r'[/\\]'))
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty && part != '.')
        .toList();
    return parts.length < 2 ? null : parts.take(parts.length - 1).join('/');
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
