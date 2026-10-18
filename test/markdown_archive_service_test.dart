import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lingua_srs/services/markdown_archive_service.dart';

List<int> _zip(List<ArchiveFile> files) {
  final archive = Archive();
  for (final file in files) {
    archive.add(file);
  }
  return ZipEncoder().encode(archive);
}

void main() {
  test('reads Markdown entries and preserves their nested paths', () {
    final files = MarkdownArchiveService.readMarkdownFiles(
      _zip([
        ArchiveFile.string('Unit 2/Lesson 1.md', '# Lesson 1'),
        ArchiveFile.string('images/cover.png', 'not markdown'),
      ]),
    );

    expect(files, hasLength(1));
    expect(files.single.path, 'Unit 2/Lesson 1.md');
    expect(files.single.contents, '# Lesson 1');
  });

  test('rejects Markdown entries with paths escaping the archive root', () {
    final bytes = _zip([ArchiveFile.string('../Lesson.md', '# Unsafe lesson')]);

    expect(
      () => MarkdownArchiveService.readMarkdownFiles(bytes),
      throwsFormatException,
    );
  });
}
