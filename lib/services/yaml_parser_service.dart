import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:yaml/yaml.dart';

import '../models/lesson.dart';
import '../models/vocab_item.dart';
import '../models/sentence.dart';

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

/// Vocabulary YAML with the words that are already known left out, from
/// [YamlParserService.withoutKnownVocabulary].
class VocabularyYamlFilter {
  /// The YAML without the left-out entries, as written otherwise.
  final String yaml;

  /// The target words of the entries that are kept, in order.
  final List<String> kept;

  /// The target words of the entries that were left out, in order.
  final List<String> removed;

  const VocabularyYamlFilter({
    required this.yaml,
    required this.kept,
    required this.removed,
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

  static YamlParseResult parseLessonYaml(
    String yamlString, {
    String? defaultTitle,
    String? defaultUnitTitle,
  }) {
    var frontMatter = yamlString.trim();
    String? markdownTitle;
    String markdownContent = '';
    final isMarkdown = frontMatter.startsWith('---');
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
      markdownTitle = headingTitle?.replaceAll(r'\~', '~');
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

  /// [yaml], plain vocabulary YAML, without the entries whose target word is
  /// in [known] (keys from [vocabularyKey]) or comes earlier in [yaml]. The
  /// rest of the text is kept as it is written, so only whole entries go, and
  /// a part of speech left with no entries goes too. YAML that cannot be
  /// read, and lists written in flow style (`[...]`), are left as they are.
  static VocabularyYamlFilter withoutKnownVocabulary(
    String yaml,
    Set<String> known,
  ) {
    final YamlNode root;
    try {
      root = loadYamlNode(yaml);
    } on YamlException {
      return VocabularyYamlFilter(
        yaml: yaml,
        kept: const [],
        removed: const [],
      );
    }
    if (root is! YamlMap) {
      return VocabularyYamlFilter(
        yaml: yaml,
        kept: const [],
        removed: const [],
      );
    }
    final vocabulary = root.nodes['vocabulary'];
    final sections = vocabulary is YamlMap ? vocabulary : root;

    final seen = {...known};
    final kept = <String>[];
    final removed = <String>[];
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
        final word = targetWord(item);
        if (word == null || word.trim().isEmpty) continue;
        if (!block || seen.add(vocabularyKey(word))) {
          kept.add(word.trim());
        } else {
          removed.add(word.trim());
          gone.add(i);
        }
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
    return VocabularyYamlFilter(yaml: text, kept: kept, removed: removed);
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
