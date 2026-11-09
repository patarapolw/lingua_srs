import '../models/lesson.dart';

/// A link from lesson Markdown to a lesson, a heading, or a heading in
/// another lesson, named in plain text: `[[Unit 2::Lesson 26#Past tense]]`.
class LessonLink {
  /// The linked lesson's name or path (`Lesson 26`, `Unit 2::Lesson 26`), or
  /// null for a heading in the same lesson.
  final String? lesson;

  /// The linked heading's text (or GitHub-style anchor), or null for the top
  /// of the lesson.
  final String? heading;

  const LessonLink({this.lesson, this.heading});

  static const scheme = 'lingua-lesson';

  /// The `href` [prepareWikiLinks] writes for this link.
  String get href => Uri(
    scheme: scheme,
    queryParameters: {'lesson': ?lesson, 'heading': ?heading},
  ).toString();

  /// Reads a tapped link: a `lingua-lesson:` link, or a `#heading` link.
  /// Returns null for any other link, such as a web address.
  static LessonLink? fromHref(String href) {
    if (href.startsWith('#')) {
      final heading = _decode(href.substring(1)).trim();
      return heading.isEmpty ? null : LessonLink(heading: heading);
    }
    if (!href.startsWith('$scheme:')) return null;
    final Uri uri;
    try {
      uri = Uri.parse(href);
    } on FormatException {
      return null;
    }
    String? param(String name) {
      final value = uri.queryParameters[name]?.trim();
      return value == null || value.isEmpty ? null : value;
    }

    final lesson = param('lesson');
    final heading = param('heading');
    if (lesson == null && heading == null) return null;
    return LessonLink(lesson: lesson, heading: heading);
  }

  static String _decode(String text) {
    try {
      return Uri.decodeComponent(text);
    } catch (_) {
      return text;
    }
  }

  static final _wikiLink = RegExp(r'\[\[([^\[\]\n]+?)\]\]');
  static final _protected = RegExp(
    r'(^```[\s\S]*?^```[ \t]*$|^~~~[\s\S]*?^~~~[ \t]*$|(`+)[^\n]*?\2)',
    multiLine: true,
  );

  /// Turns `[[target]]` and `[[target|label]]` into Markdown links, leaving
  /// code alone. The target is `Lesson`, `Folder::Lesson`, `#Heading` or
  /// `Lesson#Heading`. Without a label, the link reads as its target:
  /// `Lesson 26 › Past tense`.
  static String prepareWikiLinks(String markdown) {
    if (!markdown.contains('[[')) return markdown;
    final code = <String>[];
    var prefix = 'LINGUA_LINK_CODE_';
    while (markdown.contains(prefix)) {
      prefix += 'X';
    }
    var text = markdown.replaceAllMapped(_protected, (match) {
      code.add(match[0]!);
      return '$prefix${code.length - 1}_';
    });
    text = text.replaceAllMapped(_wikiLink, (match) {
      final link = parseWikiTarget(match[1]!);
      if (link == null) return match[0]!;
      final label = _escapeLabel(link.$2);
      return '[$label](<${link.$1.href}>)';
    });
    return text.replaceAllMapped(
      RegExp('$prefix(\\d+)_'),
      (match) => code[int.parse(match[1]!)],
    );
  }

  /// The link and its label for the inside of a `[[...]]`, or null if it
  /// names nothing.
  static (LessonLink, String)? parseWikiTarget(String inner) {
    final bar = inner.indexOf('|');
    final target = (bar < 0 ? inner : inner.substring(0, bar)).trim();
    final label = bar < 0 ? '' : inner.substring(bar + 1).trim();
    final hash = target.indexOf('#');
    final lessonPart = (hash < 0 ? target : target.substring(0, hash)).trim();
    final headingPart = hash < 0 ? '' : target.substring(hash + 1).trim();
    final lessonPath = splitHierarchyPath(lessonPart);
    if (lessonPath.isEmpty && headingPart.isEmpty) return null;
    final link = LessonLink(
      lesson: lessonPath.isEmpty ? null : joinHierarchyPath(lessonPath),
      heading: headingPart.isEmpty ? null : headingPart,
    );
    return (link, label.isNotEmpty ? label : link.displayName);
  }

  /// How the link reads when it has no label of its own.
  String get displayName => [
    if (lesson != null) formatHierarchyPath(splitHierarchyPath(lesson)),
    ?heading,
  ].join(' › ');

  static String _escapeLabel(String label) =>
      label.replaceAllMapped(RegExp(r'[\[\]\\]'), (m) => '\\${m[0]}');

  /// GitHub-style anchor for a heading: `Hello, World!` becomes `hello-world`.
  static String slug(String text) => text
      .toLowerCase()
      .replaceAll(RegExp(r'[^\p{L}\p{N}\s_-]', unicode: true), '')
      .trim()
      .replaceAll(RegExp(r'\s'), '-');

  /// Whether [target], a heading's text or its anchor, names [heading].
  static bool headingMatches(String heading, String target) {
    final wanted = slug(target);
    return wanted.isNotEmpty && slug(heading) == wanted;
  }

  /// The lesson named [name] (`Lesson 26` or `Unit 2::Lesson 26`), matched
  /// against the end of each lesson's folder path and title, ignoring case.
  /// When several match, the one closest to [from] in the folder tree wins.
  static Lesson? resolveLesson(
    Iterable<Lesson> lessons,
    String name, {
    Lesson? from,
  }) {
    final wanted = [
      for (final part in splitHierarchyPath(name)) part.toLowerCase(),
    ];
    if (wanted.isEmpty) return null;
    final fromPath = [
      for (final part in from?.folderPath ?? const <String>[])
        part.toLowerCase(),
    ];
    Lesson? best;
    var bestScore = -1;
    for (final lesson in lessons) {
      final path = [
        for (final part in [...lesson.folderPath, lesson.displayTitle])
          part.toLowerCase(),
      ];
      if (path.length < wanted.length) continue;
      final tail = path.sublist(path.length - wanted.length);
      var matches = true;
      for (var i = 0; i < wanted.length; i++) {
        if (tail[i] != wanted[i]) {
          matches = false;
          break;
        }
      }
      if (!matches) continue;
      var score = 0;
      final folder = path.sublist(0, path.length - 1);
      while (score < folder.length &&
          score < fromPath.length &&
          folder[score] == fromPath[score]) {
        score++;
      }
      if (score > bestScore) {
        best = lesson;
        bestScore = score;
      }
    }
    return best;
  }
}
