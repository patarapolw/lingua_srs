import 'dart:convert';

import 'package:yaml/yaml.dart';
import 'package:yaml_edit/yaml_edit.dart';

import '../models/lesson.dart';
import '../models/sentence.dart';
import '../models/shared_vocab.dart';
import '../models/vocab_item.dart';
import 'lesson_export_service.dart';
import 'lesson_word_match.dart';
import 'yaml_parser_service.dart';

/// A lesson file with its vocabulary brought up to date with the lesson in
/// the app: words and examples edited or added in the app, written into the
/// file's frontmatter.
///
/// Only the entries that differ are rewritten. The rest of the frontmatter
/// (other keys, comments, the order and layout of entries) and everything
/// after it, the lesson text, stay as they are.
class LessonFileUpdate {
  /// The file's new text.
  final String text;

  /// Entries of the file that were changed, and words that were added to it.
  final int changed;
  final int added;

  /// What the file now says about each saved word it has
  /// ([VocabItem.source]), to keep once the file is written.
  final Map<VocabItem, VocabSource> sources;

  const LessonFileUpdate({
    required this.text,
    required this.changed,
    required this.added,
    required this.sources,
  });

  /// The update [markdown], the text of [lesson]'s file, needs, or null when
  /// it already says what the app does.
  ///
  /// The file has to be in step with the lesson first: imported, and not
  /// edited since. An entry of the file that the lesson has no word for is
  /// left alone, so a word deleted in the app stays in the file.
  ///
  /// Throws a [FormatException] when the file cannot be read as a lesson, or
  /// when the edit cannot be made safely; the file is then to be left as it
  /// is.
  static LessonFileUpdate? plan(
    String markdown,
    Lesson lesson,
    Map<String, Sentence> sentenceById,
  ) {
    final span = YamlParserService.frontmatterSpan(markdown);
    if (span == null) return null;
    final edit = _edit(markdown, span, lesson, sentenceById);
    if (edit == null) return null;

    var yaml = edit.yaml;
    if (!yaml.endsWith('\n')) yaml = '$yaml\n';
    final text = markdown.replaceRange(span.$1, span.$2, yaml);
    // The new file, read back, has to say what the app does: nothing more
    // to write, and no word lost on the way.
    final newSpan = YamlParserService.frontmatterSpan(text);
    final before = YamlParserService.parseLessonYaml(markdown);
    final after = YamlParserService.parseLessonYaml(text);
    if (newSpan == null ||
        text.substring(newSpan.$2) != markdown.substring(span.$2) ||
        after.lesson.vocabularies.length !=
            before.lesson.vocabularies.length + edit.added ||
        _edit(text, newSpan, lesson, sentenceById) != null) {
      throw const FormatException(
        'The words could not be written to this file safely.',
      );
    }
    final matches = LessonWordMatch.match(
      after.lesson.vocabularies,
      lesson.vocabularies,
    );
    return LessonFileUpdate(
      text: text,
      changed: edit.changed,
      added: edit.added,
      sources: Map.identity()
        ..addAll({
          for (final entry in matches.entries)
            if (entry.key.source != null) entry.value.word: entry.key.source!,
        }),
    );
  }

  static ({String yaml, int changed, int added})? _edit(
    String markdown,
    (int, int) span,
    Lesson lesson,
    Map<String, Sentence> sentenceById,
  ) {
    final parsed = YamlParserService.parseLessonYaml(markdown);
    final fileWords = parsed.lesson.vocabularies;
    final fileSentences = {
      for (final sentence in parsed.sentences) sentence.id: sentence,
    };
    final matches = LessonWordMatch.match(fileWords, lesson.vocabularies);
    YamlEditor editor;
    try {
      editor = YamlEditor(markdown.substring(span.$1, span.$2));
    } catch (error) {
      throw FormatException('The frontmatter could not be edited: $error');
    }
    final keys = _Keys.of(parsed, lesson);
    var changed = 0;
    var added = 0;
    // Entries to add to the end of a section's list, by the list's path.
    final appended = <(List<Object?>, Map<String, Object>)>[];

    void apply(void Function() edit) {
      try {
        edit();
      } catch (error) {
        throw FormatException('The frontmatter could not be edited: $error');
      }
    }

    for (var index = 0; index < fileWords.length; index++) {
      final fileWord = fileWords[index];
      final word = matches[fileWord]?.word;
      if (word == null) continue;
      final location = parsed.locations[index];
      var touched = false;
      void set(Object? key, String value) {
        apply(() => editor.update([...location.path, key], value));
        touched = true;
      }

      final target = word.targetWord.trim();
      if (target.isNotEmpty &&
          target != fileWord.targetWord &&
          location.targetKey != null) {
        set(location.targetKey, target);
      }
      final translation = word.translation.trim();
      if (translation.isNotEmpty &&
          translation != fileWord.translation &&
          location.translationKey != null) {
        set(location.translationKey, translation);
      }
      // The reading and other forms, under the key the entry has for each.
      for (final field in VocabSource.formFields) {
        final value = word.formOf(field).trim();
        if (value.isEmpty || value == fileWord.formOf(field)) continue;
        set(location.formKeys[field] ?? _formKey(lesson, field), value);
      }
      // A detail is shared by every lesson that has the word, and another
      // lesson's file may say something else: only what was typed in the
      // app is written.
      void detail(String field, Object? key, String? ours, String? theirs) {
        final value = ours?.trim() ?? '';
        if (value.isEmpty ||
            value == (theirs?.trim() ?? '') ||
            word.shared.meta[field]?.origin != DetailOrigin.manual) {
          return;
        }
        set(key, value);
      }

      detail(SharedVocab.audioField, 'audio', word.audioUrl, fileWord.audioUrl);
      detail(
        SharedVocab.ttsField,
        location.ttsKey ?? 'tts',
        word.ttsText,
        fileWord.ttsText,
      );
      detail(SharedVocab.notesField, 'notes', word.notes, fileWord.notes);
      detail(
        SharedVocab.disambiguationField,
        'disambiguation',
        word.disambiguation,
        fileWord.disambiguation,
      );

      // Examples: the same sentence is the same example, whatever its
      // marking.
      final ours = <String, Sentence>{};
      for (final id in word.sentenceIds) {
        final sentence = sentenceById[id];
        if (sentence != null) {
          ours.putIfAbsent(sentence.signature, () => sentence);
        }
      }
      final inFile = <String>{};
      final gone = <int>{};
      // Example index to the keys to set in it.
      final marks = <int, Map<Object?, String>>{};
      for (final example in location.examples) {
        final theirs = fileSentences[example.sentenceId];
        if (theirs == null) continue;
        final sentence = ours[theirs.signature];
        if (sentence == null) {
          gone.add(example.index);
          continue;
        }
        inFile.add(theirs.signature);
        // Only the marking is compared. Sentences are shared by lessons,
        // and one that two files write with other letter case or spacing
        // would otherwise be rewritten in each file in turn.
        final marked = word.targetTextFor(sentence).trim();
        if (Sentence.hasEmphasis(marked) &&
            _loose(marked) != _loose(fileWord.targetTextFor(theirs)) &&
            example.targetKey != null) {
          (marks[example.index] ??= {})[example.targetKey] = marked;
        }
        final meaning = word.translationTextFor(sentence).trim();
        if (Sentence.hasEmphasis(meaning) &&
            _loose(meaning) != _loose(fileWord.translationTextFor(theirs))) {
          (marks[example.index] ??= {})[example.translationKey ??
                  keys.exampleTranslation] =
              meaning;
        }
      }
      final fresh = [
        for (final entry in ours.entries)
          if (!inFile.contains(entry.key))
            _example(lesson, word, entry.value, keys),
      ];
      final examplesPath = [...location.path, 'examples'];
      for (final mark in marks.entries) {
        if (gone.contains(mark.key)) continue;
        for (final field in mark.value.entries) {
          apply(
            () => editor.update([
              ...examplesPath,
              mark.key,
              field.key,
            ], field.value),
          );
          touched = true;
        }
      }
      if (gone.isNotEmpty || fresh.isNotEmpty) {
        touched = true;
        final length = location.hasExamples
            ? (editor.parseAt(examplesPath).value as List).length
            : 0;
        final before = editor.toString();
        try {
          // One line taken out or put in per example, so that the rest of
          // the entry reads the same in a diff.
          if (length > 0 && gone.length == length && fresh.isEmpty) {
            editor = YamlEditor(_removeLines(before, examplesPath));
          } else {
            var text = before;
            for (final index in gone.toList()..sort((a, b) => b - a)) {
              text = _removeLines(text, [...examplesPath, index]);
            }
            editor = YamlEditor(text);
            if (length - gone.length > 0) {
              appended.addAll([
                for (final example in fresh) (examplesPath, example),
              ]);
            } else if (fresh.isNotEmpty) {
              editor.update(examplesPath, fresh);
            }
          }
        } catch (_) {
          // The list is written again as a whole, with the examples that
          // stay as the file has them.
          editor = YamlEditor(before);
          final kept = <Object?>[];
          if (location.hasExamples) {
            final list = editor.parseAt(examplesPath).value as List;
            for (var at = 0; at < list.length; at++) {
              if (!gone.contains(at)) kept.add(_plain(list[at]));
            }
          }
          apply(() => editor.update(examplesPath, [...kept, ...fresh]));
        }
      }
      if (touched) changed++;
    }

    // Words the app has and no file ever had: added in the app. A word that
    // came from a file and is not in this one was taken out of the file.
    final inFile = Set<VocabItem>.identity()
      ..addAll(matches.values.map((match) => match.word));
    // A lesson can hold a word twice. The copy left over when the other was
    // paired with the file's entry is not a new word: the file has it.
    final fileIds = {for (final word in fileWords) word.id};
    final fileMeanings = {
      for (final word in fileWords) LessonWordMatch.meaningKey(word),
    };
    final sections = {...parsed.sections};
    for (final word in lesson.vocabularies) {
      if (inFile.contains(word) ||
          fileIds.contains(word.id) ||
          fileMeanings.contains(LessonWordMatch.meaningKey(word)) ||
          word.source != null ||
          (!word.idIsExplicit && word.id.startsWith('auto-')) ||
          (word.targetWord.trim().isEmpty && word.translation.trim().isEmpty)) {
        continue;
      }
      final names = [
        for (final name in word.effectiveSectionPath)
          if (name.trim().isNotEmpty) name.trim(),
      ];
      if (names.isEmpty) names.add('general');
      final entry = _entry(lesson, word, sentenceById, keys);
      final section = sections[YamlParseResult.sectionKey(names)];
      if (section != null) {
        // A section of that name that holds sections, not entries.
        if (!section.isList) continue;
        appended.add((section.path, entry));
        added++;
        continue;
      }
      // The deepest section there is on the way, to make the rest under.
      var depth = names.length - 1;
      VocabSectionLocation? parent;
      for (; depth > 0; depth--) {
        parent = sections[YamlParseResult.sectionKey(names.take(depth))];
        if (parent != null) break;
      }
      if (parent != null && parent.isList) continue;
      final base = parent?.path ?? parsed.vocabularyPath;
      Object value = [entry];
      for (final name in names.skip(depth + 1).toList().reversed) {
        value = {name: value};
      }
      if (parent == null && sections.isEmpty) {
        // `vocabulary:` with nothing under it is not a map yet.
        apply(() => editor.update(base, {names.first: value}));
      } else {
        apply(() => editor.update([...base, names[depth]], value));
      }
      for (var made = depth + 1; made <= names.length; made++) {
        sections[YamlParseResult.sectionKey(
          names.take(made),
        )] = VocabSectionLocation([
          ...base,
          ...names.skip(depth).take(made - depth),
        ], isList: made == names.length);
      }
      added++;
    }

    if (changed == 0 && added == 0) return null;
    var yaml = editor.toString();
    for (final (path, entry) in appended) {
      yaml = _append(yaml, path, entry);
    }
    return (yaml: yaml, changed: changed, added: added);
  }

  /// [yaml] with [entry] added to the end of the list at [path].
  ///
  /// Written here as text, after the list's last item and indented like it:
  /// `YamlEditor.appendToList` puts an item in the wrong place when the list
  /// is inside another collection and something follows it.
  static String _append(
    String yaml,
    List<Object?> path,
    Map<String, Object> entry,
  ) {
    final node = _nodeAt(loadYamlNode(yaml), path);
    if (node is! YamlList) {
      throw const FormatException('A vocabulary section is not a list.');
    }
    if (node.style == CollectionStyle.FLOW || node.nodes.isEmpty) {
      // On one line, as an export writes it: nothing follows on the line
      // to be mistaken for.
      final editor = YamlEditor(yaml);
      try {
        editor.appendToList(path, entry);
      } catch (error) {
        throw FormatException('The frontmatter could not be edited: $error');
      }
      return editor.toString();
    }

    final last = node.nodes.last;
    // The `-` of the last item, which the new one lines up with.
    var dash = last.span.start.offset - 1;
    while (dash >= 0 && yaml[dash] == ' ') {
      dash--;
    }
    if (dash < 0 || yaml[dash] != '-') {
      throw const FormatException('A vocabulary list could not be added to.');
    }
    final lineStart = yaml.lastIndexOf('\n', dash) + 1;
    if (yaml.substring(lineStart, dash).trim().isNotEmpty) {
      throw const FormatException('A vocabulary list could not be added to.');
    }
    final indent = ' ' * (dash - lineStart);
    // The end of the line the last item's last value ends on.
    var end = _lastValueEnd(last);
    while (end > 0 && ' \t\r\n'.contains(yaml[end - 1])) {
      end--;
    }
    final lineEnd = yaml.indexOf('\n', end);
    final at = lineEnd == -1 ? yaml.length : lineEnd;
    final newline = yaml.contains('\r\n') ? '\r\n' : '\n';
    final lines = _block(entry);
    final text = StringBuffer();
    for (var index = 0; index < lines.length; index++) {
      text
        ..write(newline)
        ..write(indent)
        ..write(index == 0 ? '- ' : '  ')
        ..write(lines[index]);
    }
    final before = yaml.substring(0, at).replaceFirst(RegExp(r'\r$'), '');
    final after = yaml.substring(at);
    return '$before$text${lineEnd == -1 ? newline : ''}$after';
  }

  /// The node at [path] under [root].
  static YamlNode _nodeAt(YamlNode root, List<Object?> path) {
    var node = root;
    for (final key in path) {
      final YamlNode? child;
      if (node is YamlMap) {
        child = node.nodes.entries
            .where((item) => (item.key as YamlNode).value == key)
            .map((item) => item.value)
            .firstOrNull;
      } else if (node is YamlList && key is int && key < node.nodes.length) {
        child = node.nodes[key];
      } else {
        child = null;
      }
      if (child == null) {
        throw const FormatException('A vocabulary section was not found.');
      }
      node = child;
    }
    return node;
  }

  /// [yaml] without the item of a block list, or the key of a block map, at
  /// [path]: the lines from its `-` or its key to the end of its last value,
  /// and nothing after. `YamlEditor.remove` also takes the blank line that
  /// follows, which separates the next entry. Throws when the item is not
  /// laid out on lines of its own.
  static String _removeLines(String yaml, List<Object?> path) {
    final parent = _nodeAt(
      loadYamlNode(yaml),
      path.sublist(0, path.length - 1),
    );
    final key = path.last;
    final int start;
    final YamlNode value;
    if (parent is YamlList &&
        parent.style != CollectionStyle.FLOW &&
        key is int &&
        key < parent.nodes.length) {
      value = parent.nodes[key];
      var dash = value.span.start.offset - 1;
      while (dash >= 0 && yaml[dash] == ' ') {
        dash--;
      }
      if (dash < 0 || yaml[dash] != '-') {
        throw const FormatException('An example could not be taken out.');
      }
      start = dash;
    } else if (parent is YamlMap && parent.style != CollectionStyle.FLOW) {
      final item = parent.nodes.entries
          .where((item) => (item.key as YamlNode).value == key)
          .firstOrNull;
      if (item == null) {
        throw const FormatException('An example could not be taken out.');
      }
      start = (item.key as YamlNode).span.start.offset;
      value = item.value;
    } else {
      throw const FormatException('An example could not be taken out.');
    }
    final lineStart = yaml.lastIndexOf('\n', start) + 1;
    if (yaml.substring(lineStart, start).trim().isNotEmpty) {
      throw const FormatException('An example could not be taken out.');
    }
    var end = _lastValueEnd(value);
    while (end > lineStart && ' \t\r\n'.contains(yaml[end - 1])) {
      end--;
    }
    final lineEnd = yaml.indexOf('\n', end);
    return yaml.replaceRange(
      lineStart,
      lineEnd == -1 ? yaml.length : lineEnd + 1,
      '',
    );
  }

  static int _lastValueEnd(YamlNode node) {
    if (node is YamlMap &&
        node.style != CollectionStyle.FLOW &&
        node.nodes.isNotEmpty) {
      return _lastValueEnd(node.nodes.values.last);
    }
    if (node is YamlList &&
        node.style != CollectionStyle.FLOW &&
        node.nodes.isNotEmpty) {
      return _lastValueEnd(node.nodes.last);
    }
    return node.span.end.offset;
  }

  /// [map] as the lines of a YAML block mapping. Every value is written in
  /// double quotes, as JSON writes a string, which YAML reads the same way
  /// whatever the text has in it.
  static List<String> _block(Map<Object?, Object?> map) {
    String key(Object? name) {
      final text = name.toString();
      return RegExp(r'^[A-Za-z_][A-Za-z0-9_-]*$').hasMatch(text)
          ? text
          : jsonEncode(text);
    }

    final lines = <String>[];
    for (final field in map.entries) {
      final value = field.value;
      if (value is List) {
        lines.add('${key(field.key)}:');
        for (final item in value) {
          final itemLines = item is Map
              ? _block(item)
              : [jsonEncode(item.toString())];
          for (var index = 0; index < itemLines.length; index++) {
            lines.add('  ${index == 0 ? '- ' : '  '}${itemLines[index]}');
          }
        }
      } else {
        lines.add('${key(field.key)}: ${jsonEncode(value.toString())}');
      }
    }
    return lines;
  }

  static String _loose(String text) =>
      text.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  /// A copy of a YAML value that can be changed and written again.
  static Object? _plain(Object? value) {
    if (value is Map) {
      return <Object?, Object?>{
        for (final entry in value.entries) entry.key: _plain(entry.value),
      };
    }
    if (value is List) return [for (final item in value) _plain(item)];
    return value;
  }

  /// The key a reading or form is written under when the entry has none for
  /// it yet.
  static String _formKey(Lesson lesson, String field) =>
      field == VocabSource.readingField
      ? LessonExportService.readingKey(lesson)
      : field;

  static Map<String, Object> _entry(
    Lesson lesson,
    VocabItem word,
    Map<String, Sentence> sentenceById,
    _Keys keys,
  ) {
    String? text(String? value) =>
        value == null || value.trim().isEmpty ? null : value.trim();
    final seen = <String>{};
    final examples = [
      for (final id in word.sentenceIds)
        if (sentenceById[id] case final sentence?)
          if (seen.add(sentence.signature))
            _example(lesson, word, sentence, keys),
    ];
    return {
      if (word.idIsExplicit) 'id': word.id,
      keys.target: word.targetWord.trim(),
      keys.translation: word.translation.trim(),
      for (final field in VocabSource.formFields)
        _formKey(lesson, field): ?text(word.formOf(field)),
      'audio': ?text(word.audioUrl),
      'tts': ?text(word.ttsText),
      'notes': ?text(word.notes),
      'disambiguation': ?text(word.disambiguation),
      if (examples.isNotEmpty) 'examples': examples,
    };
  }

  static Map<String, Object> _example(
    Lesson lesson,
    VocabItem word,
    Sentence sentence,
    _Keys keys,
  ) {
    String? text(String? value) =>
        value == null || value.trim().isEmpty ? null : value.trim();
    return {
      keys.exampleTarget: LessonExportService.exampleTarget(
        lesson,
        word,
        sentence,
      ).trim(),
      keys.exampleTranslation: ?text(word.translationTextFor(sentence)),
      'audio': ?text(sentence.audioUrl),
      'tts': ?text(sentence.ttsText),
      'notes': ?text(sentence.notes),
    };
  }
}

/// The keys new entries and examples are written with: the ones the file
/// uses most, else the lesson's languages.
class _Keys {
  final String target;
  final String translation;
  final String exampleTarget;
  final String exampleTranslation;

  const _Keys({
    required this.target,
    required this.translation,
    required this.exampleTarget,
    required this.exampleTranslation,
  });

  factory _Keys.of(YamlParseResult parsed, Lesson lesson) {
    String? mostUsed(Iterable<Object?> keys) {
      final counts = <String, int>{};
      for (final key in keys) {
        if (key is String) counts[key] = (counts[key] ?? 0) + 1;
      }
      String? best;
      for (final entry in counts.entries) {
        if (best == null || entry.value > counts[best]!) best = entry.key;
      }
      return best;
    }

    String known(String language, List<String> keys, String fallback) {
      final key = language.trim().toLowerCase();
      return keys.contains(key) ? key : fallback;
    }

    final examples = parsed.locations.expand((location) => location.examples);
    final target =
        mostUsed(parsed.locations.map((location) => location.targetKey)) ??
        known(lesson.targetLanguage, YamlParserService.knownLangKeys, 'target');
    final translation =
        mostUsed(parsed.locations.map((location) => location.translationKey)) ??
        known(
          lesson.nativeLanguage,
          YamlParserService.knownNativeKeys,
          'translation',
        );
    return _Keys(
      target: target,
      translation: translation,
      exampleTarget:
          mostUsed(examples.map((example) => example.targetKey)) ?? target,
      exampleTranslation:
          mostUsed(examples.map((example) => example.translationKey)) ??
          translation,
    );
  }
}
