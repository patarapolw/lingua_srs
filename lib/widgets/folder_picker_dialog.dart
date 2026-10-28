import 'package:flutter/material.dart';

import '../models/lesson.dart';

/// Asks where to move a lesson or folder. Resolves to the chosen folder path
/// (empty for the root), or null when cancelled.
///
/// Besides the existing [folderPaths], the person can type a new folder name.
/// `::` nests, e.g. `Unit 3::Grammar`; the folder is created implicitly when
/// something is moved into it, because folders are derived from lessons.
Future<List<String>?> showFolderPickerDialog(
  BuildContext context, {
  required String title,
  required List<List<String>> folderPaths,
}) => showDialog<List<String>>(
  context: context,
  builder: (dialogContext) =>
      FolderPickerDialog(title: title, folderPaths: folderPaths),
);

class FolderPickerDialog extends StatefulWidget {
  final String title;
  final List<List<String>> folderPaths;

  const FolderPickerDialog({
    super.key,
    required this.title,
    required this.folderPaths,
  });

  @override
  State<FolderPickerDialog> createState() => _FolderPickerDialogState();
}

class _FolderPickerDialogState extends State<FolderPickerDialog> {
  final _controller = TextEditingController();
  bool _creating = false;

  List<String> get _newPath => splitHierarchyPath(_controller.text);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submitNew() {
    final path = _newPath;
    if (path.isEmpty) return;
    Navigator.pop(context, path);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 400,
        child: ListView(
          shrinkWrap: true,
          children: [
            if (_creating)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: TextField(
                  key: const ValueKey('new-folder-field'),
                  controller: _controller,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'New folder name',
                    helperText: 'Use :: to nest, e.g. Unit 3::Grammar',
                  ),
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => _submitNew(),
                ),
              )
            else
              ListTile(
                key: const ValueKey('new-folder-tile'),
                leading: const Icon(Icons.create_new_folder_outlined),
                title: const Text('New folder...'),
                onTap: () => setState(() => _creating = true),
              ),
            ListTile(
              leading: const Icon(Icons.home_outlined),
              title: const Text('Root (no folder)'),
              onTap: () => Navigator.pop(context, <String>[]),
            ),
            for (final path in widget.folderPaths)
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text(formatHierarchyPath(path)),
                onTap: () => Navigator.pop(context, path),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        if (_creating)
          FilledButton(
            key: const ValueKey('new-folder-create'),
            onPressed: _newPath.isEmpty ? null : _submitNew,
            child: const Text('Create'),
          ),
      ],
    );
  }
}
