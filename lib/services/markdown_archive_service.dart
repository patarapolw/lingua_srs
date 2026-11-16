import 'dart:convert';

import 'package:archive/archive.dart';

class MarkdownArchiveFile {
  final String path;
  final String contents;

  /// Why the entry could not be read, such as text that is not UTF-8. Its
  /// [contents] are then empty; the other entries of the ZIP are still read.
  final String? error;

  const MarkdownArchiveFile({
    required this.path,
    required this.contents,
    this.error,
  });
}

class MarkdownArchiveService {
  /// Folders that never hold lessons, whatever `.md` files are in them:
  /// what `npm` installs next to a lesson folder previewed with VitePress,
  /// and what the macOS Finder adds to a ZIP it makes.
  static const ignoredFolders = {'node_modules', '__MACOSX'};

  /// Whether a folder or file called [name] is left out of a folder or ZIP
  /// import: one of [ignoredFolders], or hidden (a name starting with a
  /// dot, such as `.vitepress`, `.git`, or the `._lesson.md` files macOS
  /// keeps next to `lesson.md`).
  static bool isIgnoredName(String name) =>
      name.startsWith('.') || ignoredFolders.contains(name);

  /// Whether any folder on [relativePath], or its file, is left out
  /// ([isIgnoredName]). The path is the one under the picked folder or
  /// inside the ZIP.
  static bool isIgnoredPath(String relativePath) => relativePath
      .split(RegExp(r'[/\\]'))
      .where((segment) => segment.isNotEmpty)
      .any(isIgnoredName);

  /// Orders two paths of a folder or ZIP import "naturally": folder by folder
  /// (`/` or `\\`), each name case-insensitively, with runs of digits
  /// compared as numbers, so `lesson-2` < `lesson-9` < `lesson-10`, and
  /// `lesson-02` sorts with `lesson-2`. Names that only differ in case or
  /// in leading zeros are still ordered (leading zeros first, then plain
  /// text), so the result does not depend on the order files were read in.
  ///
  /// Folders and files are not separated: `intro.md` sorts among the unit
  /// folders by its name. VitePress has no sort of its own (its sidebar is
  /// what the lesson folder's config lists), so this matches the usual
  /// natural file-name order, not a VitePress rule.
  static int comparePaths(String first, String second) {
    List<String> parts(String path) => path
        .split(RegExp(r'[/\\]'))
        .where((segment) => segment.isNotEmpty)
        .toList();
    final a = parts(first);
    final b = parts(second);
    for (var i = 0; i < a.length && i < b.length; i++) {
      final result = _compareNames(a[i], b[i]);
      if (result != 0) return result;
    }
    final byDepth = a.length.compareTo(b.length);
    return byDepth != 0 ? byDepth : first.compareTo(second);
  }

  static final _digitsOrText = RegExp(r'\d+|\D+');

  static int _compareNames(String first, String second) {
    final a = _digitsOrText.allMatches(first).map((m) => m[0]!).toList();
    final b = _digitsOrText.allMatches(second).map((m) => m[0]!).toList();
    for (var i = 0; i < a.length && i < b.length; i++) {
      final left = a[i];
      final right = b[i];
      final bothDigits =
          left.codeUnitAt(0) >= 48 &&
          left.codeUnitAt(0) <= 57 &&
          right.codeUnitAt(0) >= 48 &&
          right.codeUnitAt(0) <= 57;
      int result;
      if (bothDigits) {
        final x = left.replaceFirst(RegExp(r'^0+'), '');
        final y = right.replaceFirst(RegExp(r'^0+'), '');
        result = x.length != y.length
            ? x.length.compareTo(y.length)
            : x.compareTo(y);
        // Equal numbers: more leading zeros first (`01` before `1`).
        if (result == 0) result = right.length.compareTo(left.length);
      } else {
        result = left.toLowerCase().compareTo(right.toLowerCase());
      }
      if (result != 0) return result;
    }
    final byParts = a.length.compareTo(b.length);
    return byParts != 0 ? byParts : first.compareTo(second);
  }

  /// The Markdown entries of a ZIP, without the ones in ignored folders
  /// ([isIgnoredPath]). An entry that cannot be read comes back with its
  /// [MarkdownArchiveFile.error] and does not stop the rest.
  static List<MarkdownArchiveFile> readMarkdownFiles(List<int> bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    final files = <MarkdownArchiveFile>[];

    for (final entry in archive.files) {
      if (!entry.isFile ||
          entry.isSymbolicLink ||
          !entry.name.toLowerCase().endsWith('.md')) {
        continue;
      }

      final path = _safeRelativePath(entry.name);
      if (path == null) {
        throw FormatException(
          'Unsafe Markdown path in ZIP archive: ${entry.name}',
        );
      }
      if (isIgnoredPath(path)) continue;
      try {
        files.add(
          MarkdownArchiveFile(path: path, contents: utf8.decode(entry.content)),
        );
      } on FormatException {
        files.add(
          MarkdownArchiveFile(
            path: path,
            contents: '',
            error: 'The file is not UTF-8 text.',
          ),
        );
      }
    }

    return files;
  }

  static String? _safeRelativePath(String entryName) {
    final normalized = entryName.replaceAll('\\', '/');
    if (normalized.startsWith('/') ||
        RegExp(r'^[a-zA-Z]:').hasMatch(normalized)) {
      return null;
    }

    final segments = normalized.split('/');
    if (segments.any((segment) => segment == '..')) return null;
    final safeSegments = segments
        .where((segment) => segment.isNotEmpty && segment != '.')
        .toList();
    if (safeSegments.isEmpty) return null;
    return safeSegments.join('/');
  }
}
