import 'dart:convert';

import 'package:archive/archive.dart';

import '../models/lesson.dart';
import '../models/sentence.dart';
import '../models/vocab_item.dart';
import 'yaml_parser_service.dart';

class LessonExportService {
  static List<int> createZip(List<Lesson> lessons, List<Sentence> sentences) {
    final sentenceById = {
      for (final sentence in sentences) sentence.id: sentence,
    };
    final archive = Archive();
    final usedPaths = <String>{};

    for (final lesson in lessons) {
      final path = _uniquePath(_lessonPath(lesson), lesson.id, usedPaths);
      archive.add(
        ArchiveFile.string(path, _lessonMarkdown(lesson, sentenceById)),
      );
    }

    return ZipEncoder().encode(archive);
  }

  static String fileName(String name) => '${_safeSegment(name)}.zip';

  static String _lessonPath(Lesson lesson) => [
    ...lesson.folderPath.map(_safeSegment),
    '${_safeSegment(lesson.displayTitle)}.md',
  ].join('/');

  static String _uniquePath(
    String path,
    String lessonId,
    Set<String> usedPaths,
  ) {
    if (usedPaths.add(path.toLowerCase())) return path;
    final separator = path.lastIndexOf('/');
    final directory = separator == -1 ? '' : path.substring(0, separator + 1);
    final filename = path.substring(separator + 1);
    final extension = filename.toLowerCase().endsWith('.md') ? '.md' : '';
    final title = extension.isEmpty
        ? filename
        : filename.substring(0, filename.length - extension.length);
    var candidate = '$directory$title (${_safeSegment(lessonId)})$extension';
    var suffix = 2;
    while (!usedPaths.add(candidate.toLowerCase())) {
      candidate =
          '$directory$title (${_safeSegment(lessonId)} $suffix)$extension';
      suffix++;
    }
    return candidate;
  }

  static String _safeSegment(String value) {
    final safe = value
        .replaceAll(RegExp(r'[\x00-\x1F<>:"/\\|?*]'), '_')
        .replaceAll(RegExp(r'[. ]+$'), '')
        .trim();
    return safe.isEmpty || safe == '.' || safe == '..' ? 'Untitled' : safe;
  }

  static String _lessonMarkdown(
    Lesson lesson,
    Map<String, Sentence> sentenceById,
  ) {
    final sections = _vocabulary(lesson, sentenceById);
    final frontMatter = jsonEncode({
      'title': lesson.displayTitle,
      'target': lesson.targetLanguage,
      'native': lesson.nativeLanguage,
      'vocabulary': sections,
    });
    final body = lesson.markdownContent.trim();
    final heading = '# ${lesson.displayTitle}';
    final markdownBody = body.isEmpty
        ? heading
        : RegExp(r'^#\s+.*$', multiLine: true).hasMatch(body)
        ? body.replaceFirst(RegExp(r'^#\s+.*$', multiLine: true), heading)
        : '$heading\n\n$body';
    return '---\n$frontMatter\n---\n$markdownBody\n';
  }

  static Map<String, dynamic> _vocabulary(
    Lesson lesson,
    Map<String, Sentence> sentenceById,
  ) {
    final root = <String, dynamic>{};
    for (final vocab in lesson.vocabularies) {
      final path = vocab.effectiveSectionPath
          .map((part) => part.trim())
          .where((part) => part.isNotEmpty)
          .toList();
      if (path.isEmpty) path.add('general');

      var section = root;
      for (final part in path.take(path.length - 1)) {
        final child = section.putIfAbsent(part, () => <String, dynamic>{});
        if (child is! Map<String, dynamic>) {
          throw FormatException(
            'Cannot export conflicting vocabulary section "$part".',
          );
        }
        section = child;
      }

      final entries = section.putIfAbsent(path.last, () => <dynamic>[]);
      if (entries is! List) {
        throw FormatException(
          'Cannot export conflicting vocabulary section "${path.last}".',
        );
      }
      entries.add(_vocabEntry(lesson, vocab, sentenceById));
    }
    return root;
  }

  static Map<String, dynamic> _vocabEntry(
    Lesson lesson,
    VocabItem vocab,
    Map<String, Sentence> sentenceById,
  ) {
    final entry = <String, dynamic>{
      'id': vocab.id,
      'target': vocab.targetWord,
      'meaning': vocab.translation,
    };
    if (vocab.reading.isNotEmpty) entry['reading'] = vocab.reading;
    if (vocab.simplified.isNotEmpty) entry['simplified'] = vocab.simplified;
    if (vocab.traditional.isNotEmpty) entry['traditional'] = vocab.traditional;
    if (vocab.hanja.isNotEmpty) entry['hanja'] = vocab.hanja;
    if (vocab.audioUrl != null) entry['audio'] = vocab.audioUrl;
    if (vocab.ttsText != null) entry[YamlParserService.ttsKey] = vocab.ttsText;
    if (vocab.notes.isNotEmpty) entry['notes'] = vocab.notes;
    if (vocab.disambiguation.isNotEmpty) {
      entry['disambiguation'] = vocab.disambiguation;
    }

    final examples = <Map<String, String>>[];
    for (final id in vocab.sentenceIds) {
      final sentence = sentenceById[id];
      if (sentence == null) continue;
      var target = vocab.targetTextFor(sentence);
      if (!Sentence.hasEmphasis(target)) {
        target = Sentence.suggestEmphasis(
          sentence.targetText,
          vocab.targetWord,
          korean: lesson.targetLanguage.toLowerCase() == 'ko',
        );
        if (!Sentence.hasEmphasis(target) && target.isNotEmpty) {
          target = '**$target**';
        }
      }

      final example = <String, String>{'target': target};
      final translation = vocab.translationTextFor(sentence);
      if (translation.isNotEmpty) example['translation'] = translation;
      if (sentence.audioUrl != null) example['audio'] = sentence.audioUrl!;
      if (sentence.ttsText != null)
        example[YamlParserService.ttsKey] = sentence.ttsText!;
      if (sentence.notes.isNotEmpty) example['notes'] = sentence.notes;
      examples.add(example);
    }
    if (examples.isNotEmpty) entry['examples'] = examples;
    return entry;
  }
}
