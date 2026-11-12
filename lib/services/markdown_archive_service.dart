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
