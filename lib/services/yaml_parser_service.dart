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
            ttsText = fVal; // e.g. ko_text: alternate text for TTS
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
                throw FormatException(
                  'Example sentence "$exTarget" of "$targetWord" has no '
                  '**emphasis**. Wrap the word being studied in ** **, '
                  'for example: 저는 **배**를 먹어요.',
                );
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

    // Link sentence lessonId
    for (final s in allSentences) {
      s.lessonId = lesson.id;
    }

    return YamlParseResult(lesson: lesson, sentences: allSentences);
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

/// `<lang>_text` (such as `ko_text`) holds alternate text for TTS.
bool _isTtsKey(String key) =>
    key.endsWith('_text') &&
    YamlParserService.knownLangKeys.contains(
      key.substring(0, key.length - '_text'.length),
    );
