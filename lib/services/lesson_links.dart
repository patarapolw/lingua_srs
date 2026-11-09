import '../models/lesson.dart';

/// A link from lesson Markdown to a lesson, a heading, or a heading in
/// another lesson: named in plain text (`[[Unit 2::Lesson 26#Past tense]]`)
/// or by a relative `.md` path (`[...](../unit-2/lesson-26.md#past-tense)`).
class LessonLink {
  /// The linked lesson's name or path (`Lesson 26`, `Unit 2::Lesson 26`), or
  /// null for a heading in the same lesson or a [file] link.
  final String? lesson;

  /// The linked lesson's `.md` file, relative to the linking lesson's
  /// virtual folder (or to the top folder if it starts with `/`).
  final String? file;

  /// The linked heading's text (or GitHub-style anchor), or null for the top
  /// of the lesson.
  final String? heading;

  const LessonLink({this.lesson, this.file, this.heading});

  /// Whether the link goes to another lesson (or names one), rather than
  /// to a heading in the same lesson.
  bool get isOtherLesson => lesson != null || file != null;

  static const scheme = 'lingua-lesson';

  /// The `href` [prepareWikiLinks] writes for this link.
  String get href => Uri(
    scheme: scheme,
    queryParameters: {'lesson': ?lesson, 'heading': ?heading},
  ).toString();

  static final _otherScheme = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*:');

  /// Reads a tapped link: a `lingua-lesson:` link, a `#heading` link, or a
  /// relative link to a `.md` file. Returns null for any other link, such as
  /// a web address.
  static LessonLink? fromHref(String href) {
    if (href.startsWith('#')) {
      final heading = _decode(href.substring(1)).trim();
      return heading.isEmpty ? null : LessonLink(heading: heading);
    }
    if (!href.startsWith('$scheme:')) {
      if (_otherScheme.hasMatch(href)) return null;
      final hash = href.indexOf('#');
      var path = hash < 0 ? href : href.substring(0, hash);
      final query = path.indexOf('?');
      if (query >= 0) path = path.substring(0, query);
      path = _decode(path).trim();
      if (!path.toLowerCase().endsWith('.md')) return null;
      final heading = hash < 0 ? '' : _decode(href.substring(hash + 1)).trim();
      return LessonLink(file: path, heading: heading.isEmpty ? null : heading);
    }
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
    ?file,
    ?heading,
  ].join(' › ');

  /// What a link to a missing lesson names, for a message.
  String get target => lesson ?? file ?? '';

  static const _attributeToken =
      r'''(?:[#.][^\s{}#.=]+|[^\s{}#.=]+=(?:"[^"]*"|'[^']*'|[^\s{}"']+))''';
  static final _headingAttributes = RegExp(
    '\\s*\\{\\s*($_attributeToken(?:\\s+$_attributeToken)*)\\s*\\}\\s*\$',
  );
  static final _idAttribute = RegExp(r'(?:^|\s)#([^\s{}#.=]+)');

  /// Splits markdown-it-attrs style attributes off the end of a heading:
  /// `Polite {#past-polite .note}` gives `Polite` and the id `past-polite`.
  /// Attributes are `#id`, `.class` and `key=value`; text in braces that is
  /// not made of them stays part of the heading.
  static (String, String?) splitHeadingAttributes(String heading) {
    final match = _headingAttributes.firstMatch(heading);
    if (match == null) return (heading, null);
    final id = _idAttribute.firstMatch(match[1]!)?.group(1);
    return (heading.substring(0, match.start), id);
  }

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
    return _nearest(
      lessons.where((lesson) {
        final path = [
          for (final part in [...lesson.folderPath, lesson.displayTitle])
            part.toLowerCase(),
        ];
        if (path.length < wanted.length) return false;
        final tail = path.sublist(path.length - wanted.length);
        for (var i = 0; i < wanted.length; i++) {
          if (tail[i] != wanted[i]) return false;
        }
        return true;
      }),
      from,
    );
  }

  /// The lesson a relative `.md` [file] link from [from] points to, by
  /// virtual path ([Lesson.virtualPath]): `..` goes up a folder, and a
  /// leading `/` starts at the top. Names compare loosely, the way folder
  /// import names folders, so `unit-2/lesson-26.md` finds a lesson in the
  /// folder `Unit 2` imported from `lesson-26.md`, or titled `Lesson 26`.
  ///
  /// If no lesson is at that path (say, only part of a course was
  /// imported), the nearest lesson with that file name or title is used.
  static Lesson? resolveFile(
    Iterable<Lesson> lessons,
    String file, {
    required Lesson from,
  }) {
    final path = file.startsWith('/') ? <String>[] : [...from.folderPath];
    for (final part in file.split(RegExp(r'[/\\]'))) {
      if (part.trim().isEmpty || part == '.') continue;
      if (part == '..') {
        if (path.isNotEmpty) path.removeLast();
      } else {
        path.add(part);
      }
    }
    if (path.isEmpty) return null;
    final folder = [
      for (final part in path.sublist(0, path.length - 1)) _key(part),
    ];
    final name = _fileKey(path.last);
    if (name.isEmpty) return null;

    bool named(Lesson lesson) =>
        _fileKey(lesson.virtualFileName) == name ||
        _key(lesson.displayTitle) == name;
    bool inFolder(Lesson lesson) {
      final lessonFolder = lesson.folderPath;
      if (lessonFolder.length != folder.length) return false;
      for (var i = 0; i < folder.length; i++) {
        if (_key(lessonFolder[i]) != folder[i]) return false;
      }
      return true;
    }

    final candidates = lessons.where(named).toList();
    return _nearest(candidates.where(inFolder), from) ??
        _nearest(candidates, from);
  }

  /// [Lesson.virtualPath] as a path from the top folder, the way a `.md`
  /// link can name it: `/Unit 2/lesson-26.md`.
  static String virtualPathText(Lesson lesson) =>
      '/${lesson.virtualPath.join('/')}';

  /// A Markdown link to [lesson] by its virtual path, for pasting into
  /// another lesson: `[Lesson 26](</Unit 2/lesson-26.md>)`.
  static String markdownLinkTo(Lesson lesson) {
    final label = _escapeLabel(lesson.displayTitle);
    final path = virtualPathText(
      lesson,
    ).replaceAllMapped(RegExp(r'[<>\\#?%]'), (m) => Uri.encodeComponent(m[0]!));
    return '[$label](<$path>)';
  }

  /// A name as folder import would write it, for loose comparison: lower
  /// case, with every run of other characters than letters and digits made
  /// one space (`unit-2`, `Unit 2` and `unit_2` are the same).
  static String _key(String name) => name
      .toLowerCase()
      .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
      .trim();

  static String _fileKey(String name) => _key(
    name.toLowerCase().endsWith('.md')
        ? name.substring(0, name.length - 3)
        : name,
  );

  /// Of [lessons], the one sharing the most leading folders with [from]; the
  /// first on a tie.
  static Lesson? _nearest(Iterable<Lesson> lessons, Lesson? from) {
    final fromPath = [
      for (final part in from?.folderPath ?? const <String>[]) _key(part),
    ];
    Lesson? best;
    var bestScore = -1;
    for (final lesson in lessons) {
      final folder = lesson.folderPath;
      var score = 0;
      while (score < folder.length &&
          score < fromPath.length &&
          _key(folder[score]) == fromPath[score]) {
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
