import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';

import '../models/lesson.dart';
import '../providers/app_provider.dart';
import '../services/markdown_archive_service.dart';
import '../services/storage_service.dart';
import '../services/yaml_parser_service.dart';

class YamlImportView extends StatefulWidget {
  /// Prefills the lesson name. Using an existing lesson's name adds the YAML's
  /// vocabulary to that lesson.
  final String? initialLessonName;
  final String? initialYaml;

  const YamlImportView({super.key, this.initialLessonName, this.initialYaml});

  @override
  State<YamlImportView> createState() => _YamlImportViewState();
}

class _YamlImportViewState extends State<YamlImportView>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController = TabController(
    length: 2,
    vsync: this,
  );
  final TextEditingController _lessonNameController = TextEditingController();
  final TextEditingController _yamlController = TextEditingController();
  String? _errorMessage;
  YamlParseResult? _previewResult;
  String? _defaultUnitTitle;
  List<_MarkdownImportFile> _directoryFiles = [];
  final Set<String> _selectedDirectoryPaths = {};
  List<String> _directoryErrors = [];
  int _directorySkipped = 0;
  int _directoryUnchanged = 0;
  String? _importSourceLabel;
  bool _isParsing = false;
  bool _isDraggingFiles = false;
  String? _progressMessage;
  int _progressCurrent = 0;
  int _progressTotal = 0;
  Timer? _parseTimer;
  int _parseGeneration = 0;

  @override
  void initState() {
    super.initState();
    _lessonNameController.text = widget.initialLessonName ?? '';
    _yamlController.text = widget.initialYaml ?? '';
  }

  @override
  void dispose() {
    _lessonNameController.dispose();
    _yamlController.dispose();
    _parseTimer?.cancel();
    _tabController.dispose();
    _parseGeneration++;
    super.dispose();
  }

  void _parseCurrentYaml() {
    _parseTimer?.cancel();
    final generation = ++_parseGeneration;
    final text = _yamlController.text.trim();
    if (_directoryFiles.isNotEmpty) {
      _directoryFiles = [];
      _importSourceLabel = null;
      _selectedDirectoryPaths.clear();
      _directoryErrors = [];
      _directorySkipped = 0;
      _directoryUnchanged = 0;
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

  Future<void> _pickFiles() async {
    try {
      final files = await FilePicker.pickFiles(
        dialogTitle: 'Select Markdown, YAML, or ZIP lesson files',
        type: FileType.custom,
        allowedExtensions: ['yaml', 'yml', 'txt', 'md', 'zip'],
      );
      if (files.isEmpty) return;

      final sources = <_PickedMarkdownSource>[];
      for (final file in files) {
        sources.add(
          _PickedMarkdownSource(
            name: file.name,
            sourceKey: file.uri.toString(),
            bytes: await file.readAsBytes(),
          ),
        );
      }
      await _importPickedSources(sources, label: 'Selected files');
    } catch (error) {
      if (mounted) {
        setState(() {
          _isParsing = false;
          _progressMessage = null;
          _errorMessage = 'Failed to read selected files: $error';
        });
      }
    }
  }

  Future<void> _importPickedSources(
    List<_PickedMarkdownSource> sources, {
    required String label,
  }) async {
    if (sources.isEmpty || !mounted) return;
    _parseTimer?.cancel();
    _parseGeneration++;
    setState(() {
      _isParsing = true;
      _previewResult = null;
      _directoryFiles = [];
      _directoryErrors = [];
      _directorySkipped = 0;
      _directoryUnchanged = 0;
      _errorMessage = null;
      _progressMessage = 'Reading selected lesson files...';
      _progressCurrent = 0;
      _progressTotal = sources.length;
    });
    _lessonNameController.clear();
    _yamlController.clear();
    _importSourceLabel = label;
    _tabController.animateTo(1);

    try {
      final importedSources =
          await StorageService.loadImportedMarkdownSources();
      final parseResult = await _parsePickedMarkdownSourcesInBackground(
        sources,
        importedSources,
      );
      parseResult.imports.sort((first, second) {
        return first.path.toLowerCase().compareTo(second.path.toLowerCase());
      });

      if (!mounted) return;
      setState(() {
        _directoryFiles = parseResult.imports;
        _selectedDirectoryPaths.clear();
        _directoryErrors = parseResult.errors;
        _directorySkipped = parseResult.skipped;
        _directoryUnchanged = parseResult.unchanged;
        _progressCurrent = sources.length;
        _isParsing = false;
        _progressMessage = null;
        if (parseResult.imports.isEmpty) {
          _errorMessage = parseResult.errors.isEmpty
              ? parseResult.unchanged > 0
                    ? 'No changed Markdown files found. '
                          '${parseResult.unchanged} unchanged files were skipped.'
                    : 'No Markdown files with vocabulary frontmatter were found.'
              : 'No importable files found. ${parseResult.errors.length} files '
                    'could not be parsed:\n${parseResult.errors.take(5).join('\n')}';
        }
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isParsing = false;
        _progressMessage = null;
        _errorMessage = 'Failed to parse selected files: $error';
      });
      return;
    }
  }

  Future<void> _handleDroppedFiles(DropDoneDetails details) async {
    final sources = <_PickedMarkdownSource>[];
    final errors = <String>[];
    const supportedExtensions = {'md', 'yaml', 'yml', 'txt', 'zip'};

    for (final item in details.files) {
      final filename = item.name;
      final extension = filename.contains('.')
          ? filename.split('.').last.toLowerCase()
          : '';
      if (extension == '' || !supportedExtensions.contains(extension)) {
        errors.add('$filename: unsupported file type');
        continue;
      }
      try {
        final bookmark = Platform.isMacOS ? item.extraAppleBookmark : null;
        final startedAccess = bookmark != null && bookmark.isNotEmpty
            ? await DesktopDrop.instance.startAccessingSecurityScopedResource(
                bookmark: bookmark,
              )
            : false;
        if (bookmark != null && bookmark.isNotEmpty && !startedAccess) {
          throw FileSystemException(
            'Could not access the dropped file',
            item.path,
          );
        }

        try {
          sources.add(
            _PickedMarkdownSource(
              name: filename,
              sourceKey: File(item.path).uri.toString(),
              bytes: await item.readAsBytes(),
            ),
          );
        } finally {
          if (startedAccess) {
            await DesktopDrop.instance.stopAccessingSecurityScopedResource(
              bookmark: bookmark,
            );
          }
        }
      } catch (error) {
        errors.add('$filename: $error');
      }
    }

    if (sources.isNotEmpty) {
      await _importPickedSources(sources, label: 'Dropped files');
      if (errors.isNotEmpty && mounted) {
        setState(() {
          _directoryErrors = [..._directoryErrors, ...errors];
        });
      }
    } else if (mounted) {
      setState(() {
        _directoryErrors = errors;
        _errorMessage = errors.isEmpty
            ? 'No files were dropped.'
            : 'No supported files could be imported:\n${errors.take(5).join('\n')}';
      });
    }
  }

  Future<void> _pickDirectory() async {
    if (Platform.isMacOS) {
      await _pickMultipleDirectories();
      return;
    }

    try {
      final directoryPath = await FilePicker.getDirectoryPath(
        dialogTitle: 'Select a folder of lesson Markdown files',
      );
      if (directoryPath == null) return;
      await _importFromDirectories([directoryPath], label: 'Markdown folder');
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isParsing = false;
        _progressMessage = null;
        _errorMessage = 'Failed to scan directory: $error';
      });
    }
  }

  Future<void> _pickMultipleDirectories() async {
    try {
      final selectedPaths = await FilePicker.pickFileAndDirectoryPaths(
        dialogTitle: 'Select lesson folders and files',
        type: FileType.custom,
        allowedExtensions: ['yaml', 'yml', 'txt', 'md', 'zip'],
      );
      if (selectedPaths.isEmpty) return;

      final directoryPaths = <String>[];
      final fileSources = <_PickedMarkdownSource>[];
      for (final path in selectedPaths) {
        if (await Directory(path).exists()) {
          directoryPaths.add(path);
        } else if (await File(path).exists()) {
          final file = File(path);
          fileSources.add(
            _PickedMarkdownSource(
              name: path.split(RegExp(r'[/\\]')).last,
              sourceKey: file.uri.toString(),
              bytes: await file.readAsBytes(),
            ),
          );
        }
      }

      if (directoryPaths.isEmpty && fileSources.isEmpty) return;
      await _importFromDirectories(
        directoryPaths,
        files: fileSources,
        label: 'Selected folders and files',
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isParsing = false;
        _progressMessage = null;
        _errorMessage = 'Failed to select folders: $error';
      });
    }
  }

  Future<void> _importFromDirectories(
    List<String> directoryPaths, {
    List<_PickedMarkdownSource> files = const [],
    required String label,
  }) async {
    _parseTimer?.cancel();
    _parseGeneration++;
    setState(() {
      _isParsing = true;
      _previewResult = null;
      _directoryFiles = [];
      _directoryErrors = [];
      _directorySkipped = 0;
      _directoryUnchanged = 0;
      _errorMessage = null;
      _progressMessage = 'Scanning Markdown files...';
      _progressCurrent = 0;
      _progressTotal = 0;
    });
    _lessonNameController.clear();
    _yamlController.clear();
    _importSourceLabel = label;
    _tabController.animateTo(1);

    final markdownPaths = <String>[];
    final seenPaths = <String>{};
    for (final directoryPath in directoryPaths) {
      final root = Directory(directoryPath);
      await for (final entity in root.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is File &&
            entity.path.toLowerCase().endsWith('.md') &&
            seenPaths.add(_markdownSourceKey(entity.path))) {
          markdownPaths.add(entity.path);
        }
      }
    }
    if (mounted) {
      setState(() {
        _progressTotal = markdownPaths.length + files.length;
        _progressMessage = 'Reading and validating Markdown files...';
      });
    }

    final importedSources = await StorageService.loadImportedMarkdownSources();
    if (mounted) {
      setState(() {
        _progressMessage = 'Parsing Markdown files in the background...';
        _progressCurrent = 0;
        _progressTotal = markdownPaths.length + files.length;
      });
    }
    final results = <_MarkdownDirectoryResult>[
      if (markdownPaths.isNotEmpty)
        await _parseMarkdownDirectoryInBackground(
          markdownPaths,
          directoryPaths,
          importedSources,
        ),
      if (files.isNotEmpty)
        await _parsePickedMarkdownSourcesInBackground(files, importedSources),
    ];
    final result = _combineMarkdownDirectoryResults(results);
    result.imports.sort((first, second) {
      return first.path.toLowerCase().compareTo(second.path.toLowerCase());
    });

    if (!mounted) return;
    setState(() {
      _directoryFiles = result.imports;
      _selectedDirectoryPaths.clear();
      _directoryErrors = result.errors;
      _directorySkipped = result.skipped;
      _directoryUnchanged = result.unchanged;
      _progressCurrent = markdownPaths.length + files.length;
      _isParsing = false;
      _progressMessage = null;
      if (result.imports.isEmpty) {
        _errorMessage = result.errors.isEmpty
            ? result.unchanged > 0
                  ? 'No changed Markdown files found. '
                        '${result.unchanged} unchanged files were skipped.'
                  : 'No Markdown files with a vocabulary frontmatter section were found.'
            : 'No importable files found. ${result.errors.length} files '
                  'could not be parsed:\n${result.errors.take(5).join('\n')}';
      }
    });
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
        .where((file) => _selectedDirectoryPaths.contains(file.sourceKey))
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
      final importedSources =
          await StorageService.loadImportedMarkdownSources();
      for (final file in selectedFiles) {
        importedSources[file.sourceKey] = file.sourceHash;
      }
      await StorageService.saveImportedMarkdownSources(importedSources);
      if (!mounted) return;
      setState(() {
        _progressCurrent = importedCount;
        _progressMessage = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Imported $importedCount lessons; skipped $_directorySkipped '
            'files without vocabulary frontmatter, $_directoryUnchanged '
            'unchanged Markdown files; '
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
        title: Text(compactBar ? 'Import' : 'Import Lessons'),
        actions: [
          if (compactBar) ...[
            IconButton(
              icon: const Icon(Icons.file_open_outlined),
              tooltip: 'Import Markdown, YAML, or ZIP files',
              onPressed: _isParsing ? null : _pickFiles,
            ),
            IconButton(
              icon: const Icon(Icons.folder_open_outlined),
              tooltip: Platform.isMacOS ? 'Select Folders' : 'Select Folder',
              onPressed: _isParsing ? null : _pickDirectory,
            ),
          ] else ...[
            Tooltip(
              message: 'Import Markdown, YAML, or ZIP files',
              child: TextButton.icon(
                icon: const Icon(Icons.file_open_outlined),
                label: const Text('Files'),
                onPressed: _isParsing ? null : _pickFiles,
              ),
            ),
            TextButton.icon(
              icon: const Icon(Icons.folder_open_outlined),
              label: Text(Platform.isMacOS ? 'Folders' : 'Folder'),
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
                  ? (compactBar ? 'Save' : 'Import Markdown')
                  : (compactBar
                        ? 'Save ${_selectedDirectoryPaths.length}'
                        : 'Import ${_selectedDirectoryPaths.length} Lessons'),
            ),
            onPressed:
                (_previewResult != null ||
                        _selectedDirectoryPaths.isNotEmpty) &&
                    !_isParsing
                ? _executeImport
                : null,
          ),
          SizedBox(width: compactBar ? 8 : 16),
        ],
      ),
      body: DropTarget(
        enable: _supportsDesktopFileDrop && !_isParsing,
        onDragEntered: (_) => setState(() => _isDraggingFiles = true),
        onDragExited: (_) => setState(() => _isDraggingFiles = false),
        onDragDone: _handleDroppedFiles,
        child: Stack(
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                final narrow = constraints.maxWidth < 700;
                final editor = Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_supportsDesktopFileDrop) ...[
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerHighest
                                .withValues(alpha: 0.45),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Text(
                            'Drop .md, .yaml, .yml, or .zip files anywhere here. '
                            'Markdown with YAML frontmatter and plain YAML both work.',
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
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
                          helperText:
                              'Use :: to separate hierarchy levels. Enter an existing '
                              'lesson\'s name to add vocabulary to it; existing '
                              'words and SRS progress are kept.',
                          helperMaxLines: 3,
                        ),
                        onChanged: (_) => _parseCurrentYaml(),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Markdown with YAML frontmatter (or plain YAML)',
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
                          // Fixed line boxes keep the first line from riding up
                          // against the top border.
                          strutStyle: const StrutStyle(
                            fontFamily: 'monospace',
                            fontSize: 14,
                            height: 1.45,
                            forceStrutHeight: true,
                          ),
                          decoration: InputDecoration(
                            border: const OutlineInputBorder(),
                            alignLabelWithHint: true,
                            hintText:
                                '---\n'
                                'vocabulary:\n'
                                '  nouns:  # Replace with a part of speech\n'
                                '    - ko: "Korean word"\n'
                                '      audio: "https://example.com/word-audio.mp3"\n'
                                '      en: "English meaning"\n'
                                '      notes: "Optional **Markdown** notes"\n'
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
                              color: theme.colorScheme.onSurfaceVariant
                                  .withValues(alpha: 0.65),
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
                                          _directoryFiles.map(
                                            (file) => file.sourceKey,
                                          ),
                                        );
                                    }),
                              child: const Text('Check all'),
                            ),
                            TextButton(
                              onPressed: _isParsing
                                  ? null
                                  : () =>
                                        setState(_selectedDirectoryPaths.clear),
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
                                  '$_importSourceLabel ready',
                                  style: theme.textTheme.titleLarge?.copyWith(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  '${_directoryFiles.length} lessons found; '
                                  '${_selectedDirectoryPaths.length} selected, '
                                  '$_directorySkipped files skipped and '
                                  '$_directoryUnchanged unchanged.',
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
                                      file.sourceKey,
                                    ),
                                    onChanged: (checked) => setState(() {
                                      if (checked == true) {
                                        _selectedDirectoryPaths.add(
                                          file.sourceKey,
                                        );
                                      } else {
                                        _selectedDirectoryPaths.remove(
                                          file.sourceKey,
                                        );
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
                                      avatar: const Icon(
                                        Icons.language,
                                        size: 16,
                                      ),
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
                            itemCount:
                                _previewResult!.lesson.vocabularies.length,
                            itemBuilder: (context, idx) {
                              final v =
                                  _previewResult!.lesson.vocabularies[idx];
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
                  return Column(
                    children: [
                      TabBar(
                        controller: _tabController,
                        tabs: const [
                          Tab(text: 'Editor'),
                          Tab(text: 'Preview'),
                        ],
                      ),
                      Expanded(
                        child: TabBarView(
                          controller: _tabController,
                          children: [editor, preview],
                        ),
                      ),
                    ],
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
              },
            ),
            if (_supportsDesktopFileDrop && _isDraggingFiles)
              Positioned.fill(
                child: IgnorePointer(
                  child: Container(
                    alignment: Alignment.center,
                    color: theme.colorScheme.primary.withValues(alpha: 0.14),
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          'Drop Markdown, YAML, or ZIP files to import',
                          style: theme.textTheme.titleLarge,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  bool get _supportsDesktopFileDrop =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;
}

class _MarkdownImportFile {
  final String path;
  final String sourceKey;
  final String sourceHash;
  final YamlParseResult preview;

  const _MarkdownImportFile({
    required this.path,
    required this.sourceKey,
    required this.sourceHash,
    required this.preview,
  });
}

class _PickedMarkdownSource {
  final String name;
  final String sourceKey;
  final List<int> bytes;

  const _PickedMarkdownSource({
    required this.name,
    required this.sourceKey,
    required this.bytes,
  });
}

class _MarkdownDirectoryResult {
  final List<_MarkdownImportFile> imports;
  final List<String> errors;
  final int skipped;
  final int unchanged;

  const _MarkdownDirectoryResult({
    required this.imports,
    required this.errors,
    required this.skipped,
    required this.unchanged,
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
  List<String> directoryPaths,
  Map<String, String> importedSources,
) => Isolate.run(
  () => _parseMarkdownFiles(paths, directoryPaths, importedSources),
);

Future<_MarkdownDirectoryResult> _parsePickedMarkdownSourcesInBackground(
  List<_PickedMarkdownSource> sources,
  Map<String, String> importedSources,
) => Isolate.run(() => _parsePickedMarkdownSources(sources, importedSources));

_MarkdownDirectoryResult _parsePickedMarkdownSources(
  List<_PickedMarkdownSource> sources,
  Map<String, String> importedSources,
) {
  final imports = <_MarkdownImportFile>[];
  final errors = <String>[];
  var skipped = 0;
  var unchanged = 0;

  void parseMarkdown(
    String path,
    String sourceKey,
    String contents, {
    required String? defaultTitle,
    required bool requireVocabularyFrontmatter,
    String? hierarchyPath,
  }) {
    try {
      final sourceHash = sha256.convert(utf8.encode(contents)).toString();
      if (importedSources[sourceKey] == sourceHash) {
        unchanged++;
        return;
      }
      if (requireVocabularyFrontmatter &&
          !YamlParserService.hasVocabularyFrontmatter(contents)) {
        skipped++;
        return;
      }
      final preview = YamlParserService.parseLessonYaml(
        contents,
        defaultTitle: defaultTitle,
        defaultUnitTitle: _unitTitleForPath(hierarchyPath ?? path),
      );
      imports.add(
        _MarkdownImportFile(
          path: path,
          sourceKey: sourceKey,
          sourceHash: sourceHash,
          preview: preview,
        ),
      );
    } catch (error) {
      errors.add('$path: $error');
    }
  }

  for (final source in sources) {
    try {
      if (source.name.toLowerCase().endsWith('.zip')) {
        for (final file in MarkdownArchiveService.readMarkdownFiles(
          source.bytes,
        )) {
          final sourceKey = _markdownSourceKey(
            '${source.sourceKey}!/${file.path}',
          );
          parseMarkdown(
            '${source.name}/${file.path}',
            sourceKey,
            file.contents,
            defaultTitle: null,
            requireVocabularyFrontmatter: true,
            hierarchyPath: file.path,
          );
        }
      } else {
        final pathParts = source.name.split(RegExp(r'[/\\]'));
        final filename = pathParts.last;
        parseMarkdown(
          filename,
          _markdownSourceKey(source.sourceKey),
          utf8.decode(source.bytes),
          defaultTitle: null,
          requireVocabularyFrontmatter: filename.toLowerCase().endsWith('.md'),
        );
      }
    } catch (error) {
      errors.add('${source.name}: $error');
    }
  }

  return _MarkdownDirectoryResult(
    imports: imports,
    errors: errors,
    skipped: skipped,
    unchanged: unchanged,
  );
}

_MarkdownDirectoryResult _parseMarkdownFiles(
  List<String> paths,
  List<String> directoryPaths,
  Map<String, String> importedSources,
) {
  final imports = <_MarkdownImportFile>[];
  final errors = <String>[];
  var skipped = 0;
  var unchanged = 0;
  final normalizedDirectories =
      directoryPaths.map((path) => path.replaceAll('\\', '/')).toList()
        ..sort((first, second) => first.length.compareTo(second.length));

  for (final path in paths) {
    final normalizedPath = path.replaceAll('\\', '/');
    final comparisonPath = Platform.isWindows
        ? normalizedPath.toLowerCase()
        : normalizedPath;
    final matchingRoot = normalizedDirectories.firstWhere((directory) {
      final comparisonDirectory = Platform.isWindows
          ? directory.toLowerCase()
          : directory;
      return comparisonPath.startsWith(
        comparisonDirectory.endsWith('/')
            ? comparisonDirectory
            : '$comparisonDirectory/',
      );
    }, orElse: () => normalizedDirectories.first);
    final relativePath = normalizedPath
        .substring(matchingRoot.length)
        .replaceFirst(RegExp(r'^/+'), '');
    try {
      final contents = File(path).readAsStringSync();
      final sourceHash = sha256.convert(utf8.encode(contents)).toString();
      if (importedSources[_markdownSourceKey(path)] == sourceHash) {
        unchanged++;
        continue;
      }
      if (!YamlParserService.hasVocabularyFrontmatter(contents)) {
        skipped++;
        continue;
      }
      final preview = YamlParserService.parseLessonYaml(
        contents,
        defaultUnitTitle: _unitTitleForPath(relativePath),
      );
      imports.add(
        _MarkdownImportFile(
          path: relativePath,
          sourceKey: _markdownSourceKey(path),
          sourceHash: sourceHash,
          preview: preview,
        ),
      );
    } catch (error) {
      errors.add('$relativePath: $error');
    }
  }
  return _MarkdownDirectoryResult(
    imports: imports,
    errors: errors,
    skipped: skipped,
    unchanged: unchanged,
  );
}

_MarkdownDirectoryResult _combineMarkdownDirectoryResults(
  List<_MarkdownDirectoryResult> results,
) => _MarkdownDirectoryResult(
  imports: results.expand((result) => result.imports).toList(),
  errors: results.expand((result) => result.errors).toList(),
  skipped: results.fold(0, (total, result) => total + result.skipped),
  unchanged: results.fold(0, (total, result) => total + result.unchanged),
);

String _markdownSourceKey(String path) {
  final normalizedPath = path.replaceAll('\\', '/');
  return Platform.isWindows ? normalizedPath.toLowerCase() : normalizedPath;
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
