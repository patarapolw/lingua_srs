import 'dart:convert';

import 'package:archive/archive.dart';

class MarkdownArchiveFile {
  final String path;
  final String contents;

  const MarkdownArchiveFile({required this.path, required this.contents});
}

class MarkdownArchiveService {
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
      files.add(
        MarkdownArchiveFile(path: path, contents: utf8.decode(entry.content)),
      );
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
