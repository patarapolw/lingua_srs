import 'dart:io';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';

import '../providers/app_provider.dart';
import '../services/storage_service.dart';
import '../services/yaml_parser_service.dart';

class YamlImportView extends StatefulWidget {
  const YamlImportView({super.key});

  @override
  State<YamlImportView> createState() => _YamlImportViewState();
}

class _YamlImportViewState extends State<YamlImportView> {
  final TextEditingController _yamlController = TextEditingController();
  String? _errorMessage;
  YamlParseResult? _previewResult;
  String? _defaultUnitTitle;
  List<_MarkdownImportFile> _directoryFiles = [];
  List<String> _directoryErrors = [];
  int _directorySkipped = 0;
  bool _isParsing = false;
  String? _progressMessage;
  int _progressCurrent = 0;
  int _progressTotal = 0;

  @override
  void initState() {
    super.initState();
    _yamlController.text = StorageService.defaultSampleYaml.trim();
    _parseCurrentYaml();
  }

  @override
  void dispose() {
    _yamlController.dispose();
    super.dispose();
  }

  void _parseCurrentYaml() {
    final text = _yamlController.text.trim();
    if (_directoryFiles.isNotEmpty) {
      _directoryFiles = [];
      _directoryErrors = [];
      _directorySkipped = 0;
    }
    if (text.isEmpty) {
      setState(() {
        _errorMessage = null;
        _previewResult = null;
      });
      return;
    }

    try {
      final res = YamlParserService.parseLessonYaml(
        text,
        defaultUnitTitle: _defaultUnitTitle,
      );
      setState(() {
        _errorMessage = null;
        _previewResult = res;
      });
    } catch (e) {
      setState(() {
        _errorMessage = 'YAML Parse Error: $e';
        _previewResult = null;
      });
    }
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
        _directoryErrors = [];
        _directorySkipped = 0;
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
      files.sort(
        (a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()),
      );
      if (mounted) {
        setState(() {
          _progressTotal = files.length;
          _progressMessage = 'Reading and validating Markdown files...';
        });
      }

      final imports = <_MarkdownImportFile>[];
      final errors = <String>[];
      var skipped = 0;
      for (var index = 0; index < files.length; index++) {
        final file = files[index];
        final relativePath = file.path
            .substring(directoryPath.length)
            .replaceAll('\\', '/')
            .replaceFirst(RegExp(r'^/+'), '');
        try {
          final contents = await file.readAsString();
          if (!YamlParserService.hasVocabularyFrontmatter(contents)) {
            skipped++;
          } else {
            final unitTitle = _unitTitleForPath(relativePath, file.path);
            final preview = YamlParserService.parseLessonYaml(
              contents,
              defaultUnitTitle: unitTitle,
            );
            imports.add(
              _MarkdownImportFile(path: relativePath, preview: preview),
            );
          }
        } catch (error) {
          errors.add('$relativePath: $error');
        }
        if (mounted && (index % 3 == 2 || index == files.length - 1)) {
          setState(() => _progressCurrent = index + 1);
          await Future<void>.delayed(Duration.zero);
        }
      }

      if (!mounted) return;
      setState(() {
        _directoryFiles = imports;
        _directoryErrors = errors;
        _directorySkipped = skipped;
        _isParsing = false;
        _progressMessage = null;
        if (imports.isEmpty) {
          _errorMessage = errors.isEmpty
              ? 'No Markdown files with a vocabulary frontmatter section were found.'
              : 'No importable Markdown files found. ${errors.length} files '
                    'could not be parsed:\n${errors.take(5).join('\n')}';
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

  static String? _unitTitleForPath(String relativePath, String absolutePath) {
    final unitMatch = RegExp(
      r'(?:^|/)(unit[-_ ](\d+))(?:/|$)',
      caseSensitive: false,
    ).firstMatch(absolutePath.replaceAll('\\', '/'));
    if (unitMatch != null) return 'Unit ${unitMatch.group(2)}';

    final firstDirectory = relativePath.split('/').first;
    if (relativePath.contains('/')) {
      final words = firstDirectory
          .replaceAll(RegExp(r'[-_]'), ' ')
          .split(' ')
          .where((word) => word.isNotEmpty)
          .map((word) => '${word[0].toUpperCase()}${word.substring(1)}');
      return words.join(' ');
    }
    return null;
  }

  Future<void> _executeImport() async {
    if (_directoryFiles.isNotEmpty) {
      await _executeDirectoryImport();
      return;
    }

    final text = _yamlController.text.trim();
    if (text.isEmpty) return;

    setState(() => _isParsing = true);
    try {
      final provider = context.read<AppProvider>();
      final importedLesson = await provider.importYaml(
        text,
        defaultUnitTitle: _defaultUnitTitle,
      );

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
    setState(() {
      _isParsing = true;
      _progressMessage = 'Importing lessons...';
      _progressCurrent = 0;
      _progressTotal = _directoryFiles.length;
    });
    final provider = context.read<AppProvider>();
    try {
      final importedLessons = await provider.importParsedLessons(
        _directoryFiles.map((file) => file.preview).toList(),
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

    return Scaffold(
      appBar: AppBar(
        title: const Text('Import Lessons'),
        actions: [
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
                  ? 'Import Now'
                  : 'Import ${_directoryFiles.length} Lessons',
            ),
            onPressed:
                (_previewResult != null || _directoryFiles.isNotEmpty) &&
                    !_isParsing
                ? _executeImport
                : null,
          ),
          const SizedBox(width: 16),
        ],
      ),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Left: YAML Editor
          Expanded(
            flex: 6,
            child: Padding(
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
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'YAML Input Definition',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      TextButton(
                        onPressed: () {
                          _yamlController.text = StorageService
                              .defaultSampleYaml
                              .trim();
                          _parseCurrentYaml();
                        },
                        child: const Text('Reset to Sample'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: TextField(
                      controller: _yamlController,
                      maxLines: null,
                      expands: true,
                      textAlignVertical: TextAlignVertical.top,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 13.5,
                      ),
                      decoration: InputDecoration(
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        hintText: 'Paste YAML content here...',
                        contentPadding: const EdgeInsets.all(14),
                      ),
                      onChanged: (_) => _parseCurrentYaml(),
                    ),
                  ),
                ],
              ),
            ),
          ),

          const VerticalDivider(width: 1),

          // Right: Preview & Validation
          Expanded(
            flex: 5,
            child: Padding(
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
                              '${_directoryFiles.length} lessons to import, '
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
                      child: Center(child: Text('Enter YAML to see preview')),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MarkdownImportFile {
  final String path;
  final YamlParseResult preview;

  const _MarkdownImportFile({required this.path, required this.preview});
}
