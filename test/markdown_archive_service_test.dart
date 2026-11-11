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

  test('leaves out hidden entries and the folders that hold no lessons', () {
    final files = MarkdownArchiveService.readMarkdownFiles(
      _zip([
        ArchiveFile.string('lessons/unit-1/lesson-1.md', '# Lesson 1'),
        ArchiveFile.string('lessons/node_modules/vitepress/README.md', '# No'),
        ArchiveFile.string('node_modules/vue/README.md', '# No'),
        ArchiveFile.string('lessons/.vitepress/theme/notes.md', '# No'),
        ArchiveFile.string('.git/description.md', '# No'),
        // What the macOS Finder adds for `lesson-1.md`: not text at all.
        ArchiveFile.bytes('__MACOSX/lessons/unit-1/._lesson-1.md', [
          0x00,
          0x05,
          0x16,
          0x07,
          0xff,
          0xfe,
        ]),
        ArchiveFile.bytes('lessons/unit-1/._lesson-1.md', [0xff, 0xfe]),
      ]),
    );

    expect(files.single.path, 'lessons/unit-1/lesson-1.md');
    expect(files.single.error, isNull);
  });

  test('an entry that is not UTF-8 does not stop the others', () {
    final files = MarkdownArchiveService.readMarkdownFiles(
      _zip([
        ArchiveFile.bytes('unit-1/latin1.md', [0x63, 0x61, 0x66, 0xe9]),
        ArchiveFile.string('unit-1/lesson-1.md', '# Lesson 1'),
      ]),
    );

    expect(files.map((file) => file.path), [
      'unit-1/latin1.md',
      'unit-1/lesson-1.md',
    ]);
    expect(files.first.error, contains('UTF-8'));
    expect(files.last.contents, '# Lesson 1');
    expect(files.last.error, isNull);
  });

  test('says which names are left out of an import', () {
    expect(MarkdownArchiveService.isIgnoredPath('unit-1/lesson-1.md'), isFalse);
    expect(MarkdownArchiveService.isIgnoredPath('my_modules/a.md'), isFalse);
    expect(MarkdownArchiveService.isIgnoredPath('node_modules/a.md'), isTrue);
    expect(
      MarkdownArchiveService.isIgnoredPath(r'unit-1\node_modules\a.md'),
      isTrue,
    );
    expect(MarkdownArchiveService.isIgnoredPath('unit-1/.draft.md'), isTrue);
  });

  test('rejects Markdown entries with paths escaping the archive root', () {
    final bytes = _zip([ArchiveFile.string('../Lesson.md', '# Unsafe lesson')]);

    expect(
      () => MarkdownArchiveService.readMarkdownFiles(bytes),
      throwsFormatException,
    );
  });
}
