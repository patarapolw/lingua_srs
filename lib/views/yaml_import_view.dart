import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';

import '../models/lesson.dart';
import '../providers/app_provider.dart';
import '../services/yaml_parser_service.dart';

class YamlImportView extends StatefulWidget {
  const YamlImportView({super.key});

  @override
  State<YamlImportView> createState() => _YamlImportViewState();
}

class _YamlImportViewState extends State<YamlImportView> {
  final TextEditingController _lessonNameController = TextEditingController();
  final TextEditingController _yamlController = TextEditingController();
  String? _errorMessage;
  YamlParseResult? _previewResult;
  String? _defaultUnitTitle;
  List<_MarkdownImportFile> _directoryFiles = [];
  final Set<String> _selectedDirectoryPaths = {};
  List<String> _directoryErrors = [];
  int _directorySkipped = 0;
  bool _isParsing = false;
  String? _progressMessage;
  int _progressCurrent = 0;
  int _progressTotal = 0;
  Timer? _parseTimer;
  int _parseGeneration = 0;

  @override
  void dispose() {
    _lessonNameController.dispose();
    _yamlController.dispose();
    _parseTimer?.cancel();
    _parseGeneration++;
    super.dispose();
  }

  void _parseCurrentYaml() {
    _parseTimer?.cancel();
    final generation = ++_parseGeneration;
    final text = _yamlController.text.trim();
    if (_directoryFiles.isNotEmpty) {
      _directoryFiles = [];
      _selectedDirectoryPaths.clear();
      _directoryErrors = [];
      _directorySkipped = 0;
    }
    if (text.isEmpty) {
      setState(() {
        _errorMessage = null;
        _previewResult = null;
        _progressMessage = null;
      });
      return;
    }

    final nameParts = _lessonNameParts(_lessonNameController.text);
    final unitTitle = nameParts.unitTitle ?? _defaultUnitTitle;
    setState(() {
      _errorMessage = null;
      _previewResult = null;
      _progressMessage = 'Parsing lesson...';
    });
    _parseTimer = Timer(const Duration(milliseconds: 300), () async {
      try {
        final result = await _parseLessonInBackground(
          text,
          nameParts.title,
          unitTitle,
        );
        if (!mounted || generation != _parseGeneration) return;
        setState(() {
          _errorMessage = null;
          _previewResult = result;
          _progressMessage = null;
        });
      } catch (error) {
        if (!mounted || generation != _parseGeneration) return;
        setState(() {
          _errorMessage = 'YAML / Markdown Parse Error: $error';
          _previewResult = null;
          _progressMessage = null;
        });
      }
    });
  }

  static ({String? title, String? unitTitle}) _lessonNameParts(String value) {
    final parts = splitHierarchyPath(value);
    if (parts.isEmpty) return (title: null, unitTitle: null);
    if (parts.length == 1) return (title: parts.single, unitTitle: null);
    return (
      title: parts.last,
      unitTitle: joinHierarchyPath(parts.take(parts.length - 1)),
    );
  }

  Future<void> _pickFile() async {
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['yaml', 'yml', 'txt', 'md'],
      );

      if (files.isNotEmpty && files.first.path != null) {
        final file = File(files.first.path!);
        final content = await file.readAsString();
        final unitMatch = RegExp(
          r'unit[-_ ](\d+)',
          caseSensitive: false,
        ).firstMatch(file.path);
        _defaultUnitTitle = unitMatch == null
            ? null
            : 'Unit ${unitMatch.group(1)}';
        _directoryFiles = [];
        _selectedDirectoryPaths.clear();
        _directoryErrors = [];
        _directorySkipped = 0;
        _lessonNameController.clear();
        _yamlController.text = content;
        _parseCurrentYaml();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed to read file: $e')));
      }
    }
  }

  Future<void> _pickDirectory() async {
    try {
      final directoryPath = await FilePicker.getDirectoryPath(
        dialogTitle: 'Select a folder of lesson Markdown files',
      );
      if (directoryPath == null) return;

      _parseTimer?.cancel();
      _parseGeneration++;
      setState(() {
        _isParsing = true;
        _previewResult = null;
        _directoryFiles = [];
        _directoryErrors = [];
        _directorySkipped = 0;
        _errorMessage = null;
        _progressMessage = 'Scanning Markdown files...';
        _progressCurrent = 0;
        _progressTotal = 0;
      });
      _lessonNameController.clear();
      _yamlController.clear();

      final root = Directory(directoryPath);
      final files = <File>[];
      await for (final entity in root.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is File && entity.path.toLowerCase().endsWith('.md')) {
          files.add(entity);
        }
      }
      if (mounted) {
        setState(() {
          _progressTotal = files.length;
          _progressMessage = 'Reading and validating Markdown files...';
        });
      }

      if (mounted) {
        setState(() {
          _progressMessage = 'Parsing Markdown files in the background...';
          _progressCurrent = 0;
          _progressTotal = files.length;
        });
      }
      final result = await _parseMarkdownDirectoryInBackground(
        files.map((file) => file.path).toList(),
        directoryPath,
      );
      result.imports.sort((first, second) {
        return first.path.toLowerCase().compareTo(second.path.toLowerCase());
      });

      if (!mounted) return;
      setState(() {
        _directoryFiles = result.imports;
        _selectedDirectoryPaths.clear();
        _directoryErrors = result.errors;
        _directorySkipped = result.skipped;
        _progressCurrent = files.length;
        _isParsing = false;
        _progressMessage = null;
        if (result.imports.isEmpty) {
          _errorMessage = result.errors.isEmpty
              ? 'No Markdown files with a vocabulary frontmatter section were found.'
              : 'No importable Markdown files found. ${result.errors.length} files '
                    'could not be parsed:\n${result.errors.take(5).join('\n')}';
        }
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isParsing = false;
        _progressMessage = null;
        _errorMessage = 'Failed to scan directory: $error';
      });
    }
  }

  Future<void> _executeImport() async {
    if (_directoryFiles.isNotEmpty) {
      await _executeDirectoryImport();
      return;
    }

    final text = _yamlController.text.trim();
    final preview = _previewResult;
    if (text.isEmpty || preview == null) return;

    setState(() => _isParsing = true);
    try {
      final provider = context.read<AppProvider>();
      final importedLesson = (await provider.importParsedLessons([preview]))
          .single;

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Imported "${importedLesson.displayTitle}" '
              '(${importedLesson.vocabularies.length} items) successfully!',
            ),
            backgroundColor: Colors.green.shade700,
          ),
        );
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Import failed: $e';
          _isParsing = false;
        });
      }
    }
  }

  Future<void> _executeDirectoryImport() async {
    final selectedFiles = _directoryFiles
        .where((file) => _selectedDirectoryPaths.contains(file.path))
        .toList();
    setState(() {
      _isParsing = true;
      _progressMessage = 'Importing lessons...';
      _progressCurrent = 0;
      _progressTotal = selectedFiles.length;
    });
    final provider = context.read<AppProvider>();
    try {
      final importedLessons = await provider.importParsedLessons(
        selectedFiles.map((file) => file.preview).toList(),
        onProgress: (current, total) {
          if (!mounted) return;
          setState(() {
            _progressCurrent = current;
            _progressTotal = total;
          });
        },
      );
      final importedCount = importedLessons.length;
      if (!mounted) return;
      setState(() {
        _progressCurrent = importedCount;
        _progressMessage = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Imported $importedCount lessons; skipped $_directorySkipped '
            'files without vocabulary frontmatter; '
            '${_directoryErrors.length} invalid files excluded. '
            'Existing SRS progress was preserved.',
          ),
          backgroundColor: Colors.green.shade700,
        ),
      );
      Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isParsing = false;
        _progressMessage = null;
        _errorMessage = 'Directory import failed: $error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final compactBar = MediaQuery.sizeOf(context).width < 700;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Import Lessons'),
        actions: [
          if (compactBar) ...[
            IconButton(
              icon: const Icon(Icons.file_upload_outlined),
              tooltip: 'Pick File',
              onPressed: _isParsing ? null : _pickFile,
            ),
            IconButton(
              icon: const Icon(Icons.folder_open_outlined),
              tooltip: 'Pick Folder',
              onPressed: _isParsing ? null : _pickDirectory,
            ),
          ] else ...[
            TextButton.icon(
              icon: const Icon(Icons.file_upload_outlined),
              label: const Text('Pick File'),
              onPressed: _isParsing ? null : _pickFile,
            ),
            TextButton.icon(
              icon: const Icon(Icons.folder_open_outlined),
              label: const Text('Pick Folder'),
              onPressed: _isParsing ? null : _pickDirectory,
            ),
          ],
          const SizedBox(width: 8),
          FilledButton.icon(
            icon: _isParsing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.check),
            label: Text(
              _directoryFiles.isEmpty
                  ? (compactBar ? 'Import' : 'Import Markdown')
                  : 'Import ${_selectedDirectoryPaths.length} Lessons',
            ),
            onPressed:
                (_previewResult != null ||
                        _selectedDirectoryPaths.isNotEmpty) &&
                    !_isParsing
                ? _executeImport
                : null,
          ),
          const SizedBox(width: 16),
        ],
      ),
      body: LayoutBuilder(builder: (context, constraints) {
        final narrow = constraints.maxWidth < 700;
        final editor = Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_progressMessage != null) ...[
                    Text(_progressMessage!),
                    const SizedBox(height: 6),
                    LinearProgressIndicator(
                      value: _progressTotal == 0
                          ? null
                          : _progressCurrent / _progressTotal,
                    ),
                    const SizedBox(height: 12),
                  ],
                  Text(
                    'Lesson name',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _lessonNameController,
                    enabled: !_isParsing && _directoryFiles.isEmpty,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      hintText: 'e.g. Unit 2::Lesson 26',
                      helperText: 'Use :: to separate hierarchy levels.',
                    ),
                    onChanged: (_) => _parseCurrentYaml(),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Markdown with YAML frontmatter',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: TextField(
                      controller: _yamlController,
                      maxLines: null,
                      expands: true,
                      enabled: !_isParsing && _directoryFiles.isEmpty,
                      textAlignVertical: TextAlignVertical.top,
                      keyboardType: TextInputType.multiline,
                      autocorrect: false,
                      enableSuggestions: false,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 14,
                        height: 1.45,
                      ),
                      decoration: InputDecoration(
                        border: const OutlineInputBorder(),
                        alignLabelWithHint: true,
                        hintText:
                            '---\n'
                            'vocabulary:\n'
                            '  nouns:  # Replace with a part of speech or section name\n'
                            '    - ko: "Korean word"\n'
                            '      audio: "https://example.com/word-audio.mp3"\n'
                            '      en: "English meaning"\n'
                            '      notes: "Optional HTML or Markdown notes"\n'
                            '      examples:\n'
                            '        - ko: "Sentence with **word**"\n'
                            '          en: "Translated sentence with **meaning**"\n'
                            '        - ko: "Another example sentence"\n'
                            '          audio: "https://example.com/sentence-audio.mp3"\n'
                            '          en: "Another translation"\n'
                            '---\n'
                            '\n'
                            '# Lesson 26\n'
                            '\n'
                            'Lesson contents go **here**.',
                        hintStyle: TextStyle(
                          color: theme.colorScheme.onSurfaceVariant.withValues(
                            alpha: 0.65,
                          ),
                          fontFamily: 'monospace',
                          fontSize: 14,
                          height: 1.45,
                        ),
                        contentPadding: const EdgeInsets.all(16),
                      ),
                      onChanged: (_) => _parseCurrentYaml(),
                    ),
                  ),
                ],
              ),
            );

        final preview = Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Validation & Preview',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),

                  if (_errorMessage != null)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.errorContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        _errorMessage!,
                        style: TextStyle(
                          color: theme.colorScheme.onErrorContainer,
                        ),
                      ),
                    ),

                  if (_directoryFiles.isNotEmpty) ...[
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${_directoryFiles.length} lessons found; '
                            '${_selectedDirectoryPaths.length} selected.',
                          ),
                        ),
                        TextButton(
                          onPressed: _isParsing
                              ? null
                              : () => setState(() {
                                  _selectedDirectoryPaths
                                    ..clear()
                                    ..addAll(
                                      _directoryFiles.map((file) => file.path),
                                    );
                                }),
                          child: const Text('Check all'),
                        ),
                        TextButton(
                          onPressed: _isParsing
                              ? null
                              : () => setState(_selectedDirectoryPaths.clear),
                          child: const Text('Uncheck all'),
                        ),
                      ],
                    ),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Markdown folder ready',
                              style: theme.textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '${_directoryFiles.length} lessons found; '
                              '${_selectedDirectoryPaths.length} selected, '
                              '$_directorySkipped files skipped.',
                            ),
                            const SizedBox(height: 4),
                            const Text(
                              'Matching lessons and vocabulary will be updated '
                              'in place. Existing vocabulary SRS progress will '
                              'be preserved; unmatched vocabulary will be kept.',
                            ),
                            if (_directoryErrors.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Text(
                                '${_directoryErrors.length} files could not be '
                                'parsed and will not be imported.',
                                style: TextStyle(
                                  color: theme.colorScheme.error,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                _directoryErrors.take(3).join('\n'),
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.error,
                                ),
                                maxLines: 5,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Lessons Preview:',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: ListView.builder(
                        itemCount: _directoryFiles.length,
                        itemBuilder: (context, index) {
                          final file = _directoryFiles[index];
                          final lesson = file.preview.lesson;
                          return Card(
                            margin: const EdgeInsets.symmetric(vertical: 4),
                            child: ListTile(
                              dense: true,
                              leading: Checkbox(
                                value: _selectedDirectoryPaths.contains(
                                  file.path,
                                ),
                                onChanged: (checked) => setState(() {
                                  if (checked == true) {
                                    _selectedDirectoryPaths.add(file.path);
                                  } else {
                                    _selectedDirectoryPaths.remove(file.path);
                                  }
                                }),
                              ),
                              title: Text(lesson.displayTitle),
                              subtitle: Text(
                                '${lesson.effectiveUnitTitle ?? file.path} · '
                                '${lesson.vocabularies.length} vocabulary items',
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ] else if (_previewResult != null) ...[
                    Card(
                      elevation: 0,
                      color: theme.colorScheme.surfaceContainerHighest
                          .withValues(alpha: 0.5),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _previewResult!.lesson.displayTitle,
                              style: theme.textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            if (_previewResult!.lesson.effectiveUnitTitle !=
                                null) ...[
                              const SizedBox(height: 4),
                              Text(
                                _previewResult!.lesson.effectiveUnitTitle!,
                                style: theme.textTheme.labelLarge?.copyWith(
                                  color: theme.colorScheme.primary,
                                ),
                              ),
                            ],
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                Chip(
                                  avatar: const Icon(Icons.language, size: 16),
                                  label: Text(
                                    '${_previewResult!.lesson.targetLanguage.toUpperCase()} ➔ ${_previewResult!.lesson.nativeLanguage.toUpperCase()}',
                                  ),
                                ),
                                Chip(
                                  avatar: const Icon(Icons.style, size: 16),
                                  label: Text(
                                    '${_previewResult!.lesson.vocabularies.length} Vocabs',
                                  ),
                                ),
                                Chip(
                                  avatar: const Icon(
                                    Icons.format_quote,
                                    size: 16,
                                  ),
                                  label: Text(
                                    '${_previewResult!.sentences.length} Pooled Sentences',
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Vocabulary Items Preview:',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: ListView.builder(
                        itemCount: _previewResult!.lesson.vocabularies.length,
                        itemBuilder: (context, idx) {
                          final v = _previewResult!.lesson.vocabularies[idx];
                          return Card(
                            margin: const EdgeInsets.symmetric(vertical: 4),
                            child: ListTile(
                              dense: true,
                              title: Text(
                                v.targetWord,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                ),
                              ),
                              subtitle: Text(v.translation),
                              trailing: Chip(
                                label: Text(v.pos),
                                visualDensity: VisualDensity.compact,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ] else if (_errorMessage == null)
                    const Expanded(
                      child: Center(
                        child: Text('Enter Markdown to see preview'),
                      ),
                    ),
                ],
              ),
            );

        if (narrow) {
          return DefaultTabController(
            length: 2,
            child: Column(
              children: [
                const TabBar(
                  tabs: [
                    Tab(text: 'Editor'),
                    Tab(text: 'Preview'),
                  ],
                ),
                Expanded(child: TabBarView(children: [editor, preview])),
              ],
            ),
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(flex: 6, child: editor),
            const VerticalDivider(width: 1),
            Expanded(flex: 5, child: preview),
          ],
        );
      }),
    );
  }
}

class _MarkdownImportFile {
  final String path;
  final YamlParseResult preview;

  const _MarkdownImportFile({required this.path, required this.preview});
}

class _MarkdownDirectoryResult {
  final List<_MarkdownImportFile> imports;
  final List<String> errors;
  final int skipped;

  const _MarkdownDirectoryResult({
    required this.imports,
    required this.errors,
    required this.skipped,
  });
}

Future<YamlParseResult> _parseLessonInBackground(
  String text,
  String? title,
  String? unitTitle,
) => Isolate.run(
  () => YamlParserService.parseLessonYaml(
    text,
    defaultTitle: title,
    defaultUnitTitle: unitTitle,
  ),
);

Future<_MarkdownDirectoryResult> _parseMarkdownDirectoryInBackground(
  List<String> paths,
  String directoryPath,
) => Isolate.run(() => _parseMarkdownFiles(paths, directoryPath));

_MarkdownDirectoryResult _parseMarkdownFiles(
  List<String> paths,
  String directoryPath,
) {
  final imports = <_MarkdownImportFile>[];
  final errors = <String>[];
  var skipped = 0;
  final normalizedDirectory = directoryPath.replaceAll('\\', '/');

  for (final path in paths) {
    final normalizedPath = path.replaceAll('\\', '/');
    final relativePath = normalizedPath
        .substring(normalizedDirectory.length)
        .replaceFirst(RegExp(r'^/+'), '');
    try {
      final contents = File(path).readAsStringSync();
      if (!YamlParserService.hasVocabularyFrontmatter(contents)) {
        skipped++;
        continue;
      }
      final preview = YamlParserService.parseLessonYaml(
        contents,
        defaultUnitTitle: _unitTitleForPath(relativePath),
      );
      imports.add(_MarkdownImportFile(path: relativePath, preview: preview));
    } catch (error) {
      errors.add('$relativePath: $error');
    }
  }
  return _MarkdownDirectoryResult(
    imports: imports,
    errors: errors,
    skipped: skipped,
  );
}

String? _unitTitleForPath(String relativePath) {
  final pathParts = relativePath.split('/');
  if (pathParts.length < 2) return null;
  return joinHierarchyPath(
    pathParts.take(pathParts.length - 1).map((part) {
      final unitMatch = RegExp(
        r'^unit[-_ ](\d+)$',
        caseSensitive: false,
      ).firstMatch(part);
      if (unitMatch != null) return 'Unit ${unitMatch.group(1)}';
      final words = part
          .replaceAll(RegExp(r'[-_]'), ' ')
          .split(' ')
          .where((word) => word.isNotEmpty)
          .map((word) => '${word[0].toUpperCase()}${word.substring(1)}');
      return words.join(' ');
    }),
  );
}
