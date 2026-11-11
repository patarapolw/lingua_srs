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
import '../services/lesson_ai_prompt.dart';
import '../services/lesson_file_update.dart';
import '../services/markdown_archive_service.dart';
import '../services/storage_service.dart';
import '../services/yaml_parser_service.dart';
import '../widgets/lesson_clash_dialog.dart';

class YamlImportView extends StatefulWidget {
  /// Prefills the lesson name. Using an existing lesson's name adds the YAML's
  /// vocabulary to that lesson.
  final String? initialLessonName;
  final String? initialYaml;

  /// Parses [initialYaml] as soon as the screen opens, so its preview (or its
  /// errors) shows before anything is edited. For YAML that is meant to be
  /// imported as it is, such as vocabulary an AI chat suggested.
  final bool previewInitialYaml;

  /// Only adds vocabulary to the lesson named [initialLessonName]: the input
  /// must be plain vocabulary YAML, not Markdown, which would replace the
  /// lesson's text. The lesson name is fixed, and files and folders cannot be
  /// imported.
  final bool vocabularyOnly;

  /// The vocabulary was suggested by an AI: on import, every word and every
  /// new example sentence gets a note saying so
  /// ([LessonAiPrompt.addAiNotes]).
  final bool aiSuggested;

  const YamlImportView({
    super.key,
    this.initialLessonName,
    this.initialYaml,
    this.previewInitialYaml = false,
    this.vocabularyOnly = false,
    this.aiSuggested = false,
  });

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
  List<MarkdownImportFile> _directoryFiles = [];
  final Set<String> _selectedDirectoryPaths = {};
  List<String> _directoryErrors = [];
  int _directorySkipped = 0;
  int _directoryUnchanged = 0;

  /// Unchanged files of the scanned folder, and how many of them no longer
  /// say what the app does about their words.
  List<LessonFileRef> _unchangedFiles = [];
  int _staleFiles = 0;

  /// Whether importing also writes the app's words back to the files.
  bool _writeBack = false;
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
    if (widget.previewInitialYaml && _yamlController.text.trim().isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _parseCurrentYaml();
      });
    }
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
    _unchangedFiles = [];
    _staleFiles = 0;
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
          allowMarkdown: !widget.vocabularyOnly,
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
          _errorMessage = widget.vocabularyOnly
              ? 'YAML Parse Error: $error'
              : 'YAML / Markdown Parse Error: $error';
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

      final sources = <PickedMarkdownSource>[];
      for (final file in files) {
        sources.add(
          PickedMarkdownSource(
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
    List<PickedMarkdownSource> sources, {
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
      _unchangedFiles = [];
      _staleFiles = 0;
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
      var parseResult = await _parsePickedMarkdownSourcesInBackground(
        sources,
        importedSources,
      );
      if (!mounted) return;
      final lessonless = _lessonlessFiles(
        context.read<AppProvider>(),
        parseResult,
      );
      if (lessonless.isNotEmpty) {
        parseResult = await _parsePickedMarkdownSourcesInBackground(
          sources,
          importedSources,
          reimport: lessonless,
        );
      }
      parseResult.imports.sort((first, second) {
        return first.path.toLowerCase().compareTo(second.path.toLowerCase());
      });

      if (!mounted) return;
      final followed = await context.read<AppProvider>().adoptFilePaths(
        parseResult.unchangedLessons,
      );
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
                          '${_followedNote(followed)}'
                    : 'No Markdown files with vocabulary frontmatter were found.'
              : describeImportErrors(
                  'No importable files found. ${parseResult.errors.length} '
                  'files could not be parsed:',
                  parseResult.errors,
                );
        }
      });
      if (parseResult.imports.isNotEmpty) _showFollowed(followed);
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
    final sources = <PickedMarkdownSource>[];
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
            PickedMarkdownSource(
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
            : describeImportErrors(
                'No supported files could be imported:',
                errors,
              );
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
      final fileSources = <PickedMarkdownSource>[];
      for (final path in selectedPaths) {
        if (await Directory(path).exists()) {
          directoryPaths.add(path);
        } else if (await File(path).exists()) {
          final file = File(path);
          fileSources.add(
            PickedMarkdownSource(
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
    List<PickedMarkdownSource> files = const [],
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
      _unchangedFiles = [];
      _staleFiles = 0;
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
      for (final path in await markdownFilesUnder(Directory(directoryPath))) {
        if (seenPaths.add(markdownSourceKey(path))) markdownPaths.add(path);
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
    Future<MarkdownDirectoryResult> read([
      Set<String> reimport = const {},
    ]) async => _combineMarkdownDirectoryResults([
      if (markdownPaths.isNotEmpty)
        await _parseMarkdownDirectoryInBackground(
          markdownPaths,
          directoryPaths,
          importedSources,
          reimport: reimport,
        ),
      if (files.isNotEmpty)
        await _parsePickedMarkdownSourcesInBackground(
          files,
          importedSources,
          reimport: reimport,
        ),
    ]);
    var result = await read();
    if (!mounted) return;
    final lessonless = _lessonlessFiles(context.read<AppProvider>(), result);
    if (lessonless.isNotEmpty) result = await read(lessonless);
    result.imports.sort((first, second) {
      return first.path.toLowerCase().compareTo(second.path.toLowerCase());
    });

    if (!mounted) return;
    final provider = context.read<AppProvider>();
    final followed = await provider.adoptFilePaths(result.unchangedLessons);
    final stale = await writeLessonFiles(
      provider,
      result.unchangedFiles,
      dryRun: true,
    );
    if (!mounted) return;
    setState(() {
      _unchangedFiles = result.unchangedFiles;
      _staleFiles = stale.files;
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
                        '${_followedNote(followed)}'
                  : 'No Markdown files with a vocabulary frontmatter section were found.'
            : describeImportErrors(
                'No importable files found. ${result.errors.length} '
                'files could not be parsed:',
                result.errors,
              );
      }
    });
    if (result.imports.isNotEmpty) _showFollowed(followed);
  }

  /// Says that [count] lessons took the file paths of unchanged files
  /// ([AppProvider.adoptFilePaths]), or nothing.
  static String _followedNote(int count) => count == 0
      ? ''
      : ' ${count == 1 ? '1 lesson' : '$count lessons'} imported before '
            'file paths were kept now ${count == 1 ? 'follows its' : 'follow their'} '
            'file.';

  void _showFollowed(int count) {
    if (count == 0 || !mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(_followedNote(count).trim())));
  }

  /// Asks which lesson is primary when an import of [fileCount] files adds
  /// a lesson whose name is taken in its folder, remembering an answer given
  /// for the rest of the import.
  Future<LessonClashChoice> Function(LessonNameClash) _askAboutClash(
    int fileCount,
  ) {
    LessonClashChoice? forRest;
    var asked = 0;
    return (clash) async {
      final remembered = forRest;
      if (remembered != null) return remembered;
      asked++;
      if (!mounted) return LessonClashChoice.keepBoth;
      final answer = await showLessonClashDialog(
        context,
        clash,
        importing: true,
        remaining: fileCount - asked,
      );
      final choice = answer?.choice ?? LessonClashChoice.keepBoth;
      if (answer?.forRest ?? false) forRest = choice;
      return choice;
    };
  }

  /// Whether there is a folder to write the app's words back to.
  bool get _canWriteBack =>
      _staleFiles > 0 || _directoryFiles.any((file) => file.filePath != null);

  Future<void> _executeImport() async {
    if (_directoryFiles.isNotEmpty || (_writeBack && _staleFiles > 0)) {
      await _executeDirectoryImport();
      return;
    }

    final text = _yamlController.text.trim();
    final preview = _previewResult;
    if (text.isEmpty || preview == null) return;

    setState(() => _isParsing = true);
    try {
      final provider = context.read<AppProvider>();
      if (widget.aiSuggested) {
        LessonAiPrompt.addAiNotes(
          preview,
          isNew: (sentence) => !provider.hasSentenceLike(sentence),
        );
      }
      if (widget.vocabularyOnly) {
        // Not what the lesson's file says: see [VocabItem.source].
        for (final vocab in preview.lesson.vocabularies) {
          vocab.source = null;
        }
      }
      final importedLesson = (await provider.importParsedLessons(
        [preview],
        // Adding vocabulary names the lesson to add to, so a lesson with that
        // name is that lesson, even when it came from a file (whose virtual
        // path the typed name does not have): nothing to ask.
        onClash: widget.vocabularyOnly
            ? (_) async => LessonClashChoice.keepIncoming
            : _askAboutClash(1),
      )).single;

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
        onClash: _askAboutClash(selectedFiles.length),
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
      // The files just imported are in step with their lessons now, as the
      // unchanged ones are: both can take the app's words.
      final written = _writeBack
          ? await writeLessonFiles(provider, [
              ..._unchangedFiles,
              for (final file in selectedFiles) ?file.fileRef,
            ])
          : null;
      if (!mounted) return;
      setState(() {
        _progressCurrent = importedCount;
        _progressMessage = null;
      });
      final messenger = ScaffoldMessenger.of(context);
      final navigator = Navigator.of(context);
      if (written != null && written.errors.isNotEmpty) {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Some files were not updated'),
            content: SingleChildScrollView(
              child: SelectableText(
                describeImportErrors(
                  'The app\'s words could not be written to '
                  '${written.errors.length} files, which were left as '
                  'they are:',
                  written.errors,
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Imported $importedCount lessons; skipped $_directorySkipped '
            'files without vocabulary frontmatter, $_directoryUnchanged '
            'unchanged Markdown files; '
            '${_directoryErrors.length} invalid files excluded. '
            'Existing SRS progress was preserved.'
            '${written == null ? '' : ' Wrote ${written.words} words to '
                      '${written.files} files.'}',
          ),
          backgroundColor: Colors.green.shade700,
        ),
      );
      navigator.pop();
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
    final vocabularyOnly = widget.vocabularyOnly;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          vocabularyOnly
              ? 'Add Vocabulary'
              : compactBar
              ? 'Import'
              : 'Import Lessons',
        ),
        actions: [
          // Files and folders are whole lessons, not vocabulary to add.
          if (vocabularyOnly)
            const SizedBox.shrink()
          else if (compactBar) ...[
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
              vocabularyOnly
                  ? (compactBar ? 'Add' : 'Add Vocabulary')
                  : _directoryFiles.isEmpty && _writeBack && _staleFiles > 0
                  ? (compactBar
                        ? 'Update $_staleFiles'
                        : 'Update $_staleFiles Files')
                  : _directoryFiles.isEmpty
                  ? (compactBar ? 'Save' : 'Import Markdown')
                  : (compactBar
                        ? 'Save ${_selectedDirectoryPaths.length}'
                        : 'Import ${_selectedDirectoryPaths.length} Lessons'),
            ),
            onPressed:
                (_previewResult != null ||
                        _selectedDirectoryPaths.isNotEmpty ||
                        (_writeBack && _staleFiles > 0)) &&
                    !_isParsing
                ? _executeImport
                : null,
          ),
          SizedBox(width: compactBar ? 8 : 16),
        ],
      ),
      body: DropTarget(
        enable: _supportsDesktopFileDrop && !_isParsing && !vocabularyOnly,
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
                      if (_supportsDesktopFileDrop && !vocabularyOnly) ...[
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
                        readOnly: vocabularyOnly,
                        textInputAction: TextInputAction.next,
                        decoration: InputDecoration(
                          border: const OutlineInputBorder(),
                          hintText: 'e.g. Unit 2::Lesson 26',
                          helperText: vocabularyOnly
                              ? 'The words are added to this lesson; its other '
                                    'words, its text and SRS progress are kept.'
                              : 'Use :: to separate hierarchy levels. Enter an '
                                    'existing lesson\'s name to add vocabulary '
                                    'to it; existing words and SRS progress are '
                                    'kept.',
                          helperMaxLines: 3,
                        ),
                        onChanged: (_) => _parseCurrentYaml(),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        vocabularyOnly
                            ? 'Vocabulary YAML (no Markdown)'
                            : 'Markdown with YAML frontmatter (or plain YAML)',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (widget.aiSuggested) ...[
                        const SizedBox(height: 4),
                        Text(
                          'Suggested by AI. Each word, and each example '
                          'sentence not in your Sentence Pool yet, gets a '
                          'note saying so when added.',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
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
                            hintText: vocabularyOnly
                                ? 'vocabulary:\n'
                                      '  nouns:  # Replace with a part of speech\n'
                                      '    - ko: "Korean word"\n'
                                      '      en: "English meaning"\n'
                                      '      examples:\n'
                                      '        - ko: "Sentence with **word**"\n'
                                      '          en: "Translated sentence with **meaning**"'
                                : '---\n'
                                      'vocabulary:\n'
                                      '  nouns:  # Replace with a part of speech\n'
                                      '    - ko: "Korean word"\n'
                                      '      audio: "https://example.com/word-audio.mp3"\n'
                                      '      en: "English meaning"\n'
                                      '      notes: "Optional **Markdown** notes"\n'
                                      '      examples:\n'
                                      '        - ko: "Sentence with **word**"\n'
                                      '          en: "Translated sentence with **meaning**"\n'
                                      '        - ko: "Another **example** sentence"\n'
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
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxHeight: 320),
                            child: SingleChildScrollView(
                              child: SelectableText(
                                _errorMessage!,
                                style: TextStyle(
                                  color: theme.colorScheme.onErrorContainer,
                                ),
                              ),
                            ),
                          ),
                        ),

                      if (_canWriteBack)
                        CheckboxListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                          value: _writeBack,
                          onChanged: _isParsing
                              ? null
                              : (checked) => setState(
                                  () => _writeBack = checked ?? false,
                                ),
                          title: const Text(
                            'Write words from the app back to the files',
                          ),
                          subtitle: Text(
                            '${_staleFiles == 0
                                ? ''
                                : _staleFiles == 1
                                ? '1 unchanged file no longer matches the '
                                      'words in the app. '
                                : '$_staleFiles unchanged files no longer '
                                      'match the words in the app. '}'
                            'Words and examples edited or added in the app '
                            'are written to the vocabulary in each '
                            'file\'s frontmatter, for imported files after '
                            'they are merged. Lesson text is not touched.',
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
                                  ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxHeight: 200,
                                    ),
                                    child: SingleChildScrollView(
                                      child: SelectableText(
                                        describeImportErrors(
                                          '',
                                          _directoryErrors,
                                        ).trim(),
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                              color: theme.colorScheme.error,
                                            ),
                                      ),
                                    ),
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

class MarkdownImportFile {
  final String path;
  final String sourceKey;
  final String sourceHash;
  final YamlParseResult preview;

  /// Where the file is on disk, for one found in a picked folder. Null for
  /// a file from a ZIP or one picked or dropped by itself, which cannot be
  /// written back to.
  final String? filePath;

  const MarkdownImportFile({
    required this.path,
    required this.sourceKey,
    required this.sourceHash,
    required this.preview,
    this.filePath,
  });

  LessonFileRef? get fileRef => filePath == null
      ? null
      : LessonFileRef(
          filePath: filePath!,
          path: path,
          sourceKey: sourceKey,
          sourceHash: sourceHash,
        );
}

/// The `.md` files under [root], at any depth. Hidden folders and files and
/// the folders of [MarkdownArchiveService.ignoredFolders] are not looked
/// into: a `node_modules` next to the lessons holds thousands of files, none
/// of them a lesson. [root] itself is looked into whatever its name.
Future<List<String>> markdownFilesUnder(Directory root) async {
  final paths = <String>[];
  await for (final entity in root.list(followLinks: false)) {
    // Already decoded: decoding again throws on a name such as `이다.md`.
    final name = entity.uri.pathSegments.lastWhere(
      (segment) => segment.isNotEmpty,
      orElse: () => '',
    );
    if (MarkdownArchiveService.isIgnoredName(name)) {
      continue;
    }
    if (entity is Directory) {
      paths.addAll(await markdownFilesUnder(entity));
    } else if (entity is File && entity.path.toLowerCase().endsWith('.md')) {
      paths.add(entity.path);
    }
  }
  return paths;
}

/// A lesson file in a picked folder, as it was when the folder was scanned.
class LessonFileRef {
  final String filePath;

  /// Its path under the picked folder.
  final String path;
  final String sourceKey;
  final String sourceHash;

  const LessonFileRef({
    required this.filePath,
    required this.path,
    required this.sourceKey,
    required this.sourceHash,
  });
}

/// What [writeLessonFiles] did.
class LessonFileWriteResult {
  /// Files written, or with [writeLessonFiles]' `dryRun`, that would be.
  final int files;

  /// Entries changed in and added to those files.
  final int words;
  final List<String> errors;

  const LessonFileWriteResult({
    required this.files,
    required this.words,
    required this.errors,
  });
}

/// Writes the words of the app's lessons into the vocabulary of [files],
/// the lesson files they were imported from: what was edited or added in
/// the app since. Only a file's frontmatter is rewritten; see
/// [LessonFileUpdate].
///
/// A file has to be in step with its lesson: one that was not changed since
/// it was last imported, or one that was just imported. A file edited since
/// the folder was scanned is left alone.
///
/// With [dryRun] nothing is written: the result says how many files differ.
Future<LessonFileWriteResult> writeLessonFiles(
  AppProvider provider,
  List<LessonFileRef> files, {
  bool dryRun = false,
}) async {
  final errors = <String>[];
  final written = <LessonFileUpdate>[];
  final hashes = <String, String>{};
  for (final ref in files) {
    try {
      final file = File(ref.filePath);
      final contents = await file.readAsString();
      if (sha256.convert(utf8.encode(contents)).toString() != ref.sourceHash) {
        continue;
      }
      final info = YamlParserService.lessonFileInfo(
        contents,
        sourcePath: ref.path,
        defaultUnitTitle: _unitTitleForPath(ref.path),
      );
      if (info == null) continue;
      final update = provider.planFileUpdate(contents, info);
      if (update == null) continue;
      if (!dryRun) {
        await file.writeAsString(update.text, flush: true);
        hashes[ref.sourceKey] = sha256
            .convert(utf8.encode(update.text))
            .toString();
      }
      written.add(update);
    } catch (error) {
      if (!dryRun) errors.add(describeImportError(ref.path, error));
    }
  }
  if (!dryRun && written.isNotEmpty) {
    await provider.adoptFileUpdates(written);
    // The files as written are the ones last imported.
    final sources = await StorageService.loadImportedMarkdownSources();
    await StorageService.saveImportedMarkdownSources({...sources, ...hashes});
  }
  return LessonFileWriteResult(
    files: written.length,
    words: written.fold(
      0,
      (total, update) => total + update.changed + update.added,
    ),
    errors: errors,
  );
}

class PickedMarkdownSource {
  final String name;
  final String sourceKey;
  final List<int> bytes;

  const PickedMarkdownSource({
    required this.name,
    required this.sourceKey,
    required this.bytes,
  });
}

class MarkdownDirectoryResult {
  final List<MarkdownImportFile> imports;
  final List<String> errors;
  final int skipped;
  final int unchanged;

  /// The lessons the [unchanged] files are, without vocabulary
  /// ([YamlParserService.lessonFileInfo]), so the lessons saved from them can
  /// take their real file paths ([AppProvider.adoptFilePaths]).
  final List<Lesson> unchangedLessons;

  /// The source keys of [unchangedLessons], in the same order, to name the
  /// ones to read again (`reimport`) when their lesson is no longer saved.
  final List<String> unchangedKeys;

  /// The [unchanged] files that are in a picked folder.
  final List<LessonFileRef> unchangedFiles;

  const MarkdownDirectoryResult({
    required this.imports,
    required this.errors,
    required this.skipped,
    required this.unchanged,
    this.unchangedLessons = const [],
    this.unchangedKeys = const [],
    this.unchangedFiles = const [],
  });
}

Future<YamlParseResult> _parseLessonInBackground(
  String text,
  String? title,
  String? unitTitle, {
  bool allowMarkdown = true,
}) => Isolate.run(
  () => YamlParserService.parseLessonYaml(
    text,
    defaultTitle: title,
    defaultUnitTitle: unitTitle,
    allowMarkdown: allowMarkdown,
  ),
);

Future<MarkdownDirectoryResult> _parseMarkdownDirectoryInBackground(
  List<String> paths,
  List<String> directoryPaths,
  Map<String, String> importedSources, {
  Set<String> reimport = const {},
}) => Isolate.run(
  () => parseMarkdownFiles(
    paths,
    directoryPaths,
    importedSources,
    reimport: reimport,
  ),
);

Future<MarkdownDirectoryResult> _parsePickedMarkdownSourcesInBackground(
  List<PickedMarkdownSource> sources,
  Map<String, String> importedSources, {
  Set<String> reimport = const {},
}) => Isolate.run(
  () =>
      parsePickedMarkdownSources(sources, importedSources, reimport: reimport),
);

/// The source keys of the unchanged files of [result] that have no saved
/// lesson any more: their lesson was deleted, here or on another device.
/// Reading the files again with these as `reimport` offers them for import
/// (#185).
Set<String> _lessonlessFiles(
  AppProvider provider,
  MarkdownDirectoryResult result,
) => {
  for (var index = 0; index < result.unchangedKeys.length; index++)
    if (!provider.hasLessonForFile(result.unchangedLessons[index]))
      result.unchangedKeys[index],
};

/// Reads Markdown files and ZIP archives that were picked or dropped. A file
/// that has not changed since it was imported is counted, not offered,
/// unless its source key is in [reimport].
MarkdownDirectoryResult parsePickedMarkdownSources(
  List<PickedMarkdownSource> sources,
  Map<String, String> importedSources, {
  Set<String> reimport = const {},
}) {
  final imports = <MarkdownImportFile>[];
  final errors = <String>[];
  var skipped = 0;
  var unchanged = 0;
  final unchangedLessons = <Lesson>[];
  final unchangedKeys = <String>[];

  void parseMarkdown(
    String path,
    String sourceKey,
    String contents, {
    required String? defaultTitle,
    required bool requireVocabularyFrontmatter,
    String? hierarchyPath,
    String? legacySourceKey,
  }) {
    try {
      final sourceHash = sha256.convert(utf8.encode(contents)).toString();
      if (!reimport.contains(sourceKey) &&
          (importedSources[sourceKey] == sourceHash ||
              (legacySourceKey != null &&
                  importedSources[legacySourceKey] == sourceHash))) {
        unchanged++;
        final lesson = YamlParserService.lessonFileInfo(
          contents,
          sourcePath: hierarchyPath ?? path,
          defaultUnitTitle: _unitTitleForPath(hierarchyPath ?? path),
        );
        if (lesson != null) {
          unchangedLessons.add(lesson);
          unchangedKeys.add(sourceKey);
        }
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
        sourcePath: hierarchyPath ?? path,
      );
      imports.add(
        MarkdownImportFile(
          path: path,
          sourceKey: sourceKey,
          sourceHash: sourceHash,
          preview: preview,
        ),
      );
    } catch (error) {
      errors.add(describeImportError(path, error));
    }
  }

  for (final source in sources) {
    try {
      if (source.name.toLowerCase().endsWith('.zip')) {
        for (final file in MarkdownArchiveService.readMarkdownFiles(
          source.bytes,
        )) {
          if (file.error != null) {
            errors.add('${source.name}/${file.path}: ${file.error}');
            continue;
          }
          parseMarkdown(
            '${source.name}/${file.path}',
            zipEntrySourceKey(file.path),
            file.contents,
            defaultTitle: null,
            requireVocabularyFrontmatter: true,
            hierarchyPath: file.path,
            // Saved before ZIP entries were keyed by their path alone.
            legacySourceKey: markdownSourceKey(
              '${source.sourceKey}!/${file.path}',
            ),
          );
        }
      } else {
        final pathParts = source.name.split(RegExp(r'[/\\]'));
        final filename = pathParts.last;
        parseMarkdown(
          filename,
          markdownSourceKey(source.sourceKey),
          utf8.decode(source.bytes),
          defaultTitle: null,
          requireVocabularyFrontmatter: filename.toLowerCase().endsWith('.md'),
        );
      }
    } catch (error) {
      errors.add('${source.name}: $error');
    }
  }

  return MarkdownDirectoryResult(
    imports: imports,
    errors: errors,
    skipped: skipped,
    unchanged: unchanged,
    unchangedLessons: unchangedLessons,
    unchangedKeys: unchangedKeys,
  );
}

/// Reads the Markdown files at [paths], found under [directoryPaths]. A file
/// that has not changed since it was imported is counted, not offered,
/// unless its source key is in [reimport].
MarkdownDirectoryResult parseMarkdownFiles(
  List<String> paths,
  List<String> directoryPaths,
  Map<String, String> importedSources, {
  Set<String> reimport = const {},
}) {
  final imports = <MarkdownImportFile>[];
  final errors = <String>[];
  var skipped = 0;
  var unchanged = 0;
  final unchangedLessons = <Lesson>[];
  final unchangedFiles = <LessonFileRef>[];
  final unchangedKeys = <String>[];
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
      if (!reimport.contains(markdownSourceKey(path)) &&
          importedSources[markdownSourceKey(path)] == sourceHash) {
        unchanged++;
        final lesson = YamlParserService.lessonFileInfo(
          contents,
          sourcePath: relativePath,
          defaultUnitTitle: _unitTitleForPath(relativePath),
        );
        if (lesson != null) {
          unchangedLessons.add(lesson);
          unchangedKeys.add(markdownSourceKey(path));
          unchangedFiles.add(
            LessonFileRef(
              filePath: path,
              path: relativePath,
              sourceKey: markdownSourceKey(path),
              sourceHash: sourceHash,
            ),
          );
        }
        continue;
      }
      if (!YamlParserService.hasVocabularyFrontmatter(contents)) {
        skipped++;
        continue;
      }
      final preview = YamlParserService.parseLessonYaml(
        contents,
        defaultUnitTitle: _unitTitleForPath(relativePath),
        sourcePath: relativePath,
      );
      imports.add(
        MarkdownImportFile(
          path: relativePath,
          sourceKey: markdownSourceKey(path),
          sourceHash: sourceHash,
          preview: preview,
          filePath: path,
        ),
      );
    } catch (error) {
      errors.add(describeImportError(relativePath, error));
    }
  }
  return MarkdownDirectoryResult(
    imports: imports,
    errors: errors,
    skipped: skipped,
    unchanged: unchanged,
    unchangedLessons: unchangedLessons,
    unchangedKeys: unchangedKeys,
    unchangedFiles: unchangedFiles,
  );
}

MarkdownDirectoryResult _combineMarkdownDirectoryResults(
  List<MarkdownDirectoryResult> results,
) => MarkdownDirectoryResult(
  imports: results.expand((result) => result.imports).toList(),
  errors: results.expand((result) => result.errors).toList(),
  skipped: results.fold(0, (total, result) => total + result.skipped),
  unchanged: results.fold(0, (total, result) => total + result.unchanged),
  unchangedLessons: [for (final result in results) ...result.unchangedLessons],
  unchangedKeys: [for (final result in results) ...result.unchangedKeys],
  unchangedFiles: [for (final result in results) ...result.unchangedFiles],
);

/// The key a ZIP entry's fingerprint is saved under, to skip it when it is
/// imported again unchanged: its path inside the ZIP alone. The ZIP's own
/// location is no use, since a picker can copy it somewhere new every time
/// (Android does) and a downloaded copy can be renamed (`course (1).zip`).
/// Two ZIPs with an entry at the same path share a key, which is safe: an
/// entry is only skipped when its contents are the same, and the same path
/// is the same lesson.
String zipEntrySourceKey(String path) => 'zip:${path.replaceAll('\\', '/')}';

/// The key a folder file's import is remembered by: its path with `/`
/// between folders, and lowercase on Windows, where names ignore case.
String markdownSourceKey(String path) {
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

/// How many sentences of one file are quoted in its error line.
const _sentencesShownPerFile = 5;

/// The marker [describeImportErrors] looks for to add the how-to-fix hint.
const _noEmphasisMarker = 'no **emphasis**';

/// One line (or, for example sentences without `**`, a few) saying why the
/// file at [path] could not be imported. [path] is what the person knows the
/// file by: a name inside a zip (`lessons.zip/unit1/a.md`) or the path under
/// the chosen folder.
String describeImportError(String path, Object error) {
  if (error is MissingEmphasisException) {
    final count = error.sentences.length;
    return [
      '$path: $count example '
          '${count == 1 ? 'sentence has' : 'sentences have'} '
          '$_noEmphasisMarker',
      for (final missing in error.sentences.take(_sentencesShownPerFile))
        '    ${missing.word}: ${missing.sentence}',
      if (count > _sentencesShownPerFile)
        '    …and ${count - _sentencesShownPerFile} more',
    ].join('\n');
  }
  return '$path: $error';
}

/// Every error of an import under [headline], once, with how to fix example
/// sentences that lack `**`.
String describeImportErrors(String headline, List<String> errors) {
  final hint = errors.any((error) => error.contains(_noEmphasisMarker))
      ? '\nWrap the word being studied in ** **, for example: '
            '저는 **배**를 먹어요.'
      : '';
  return '$headline\n${errors.join('\n')}$hint';
}
