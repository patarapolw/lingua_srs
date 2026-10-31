import 'package:flutter/material.dart';

import 'markdown_content.dart';
import 'markdown_text_field.dart';

/// Markdown notes in a form, laid out like the review note on the back of a
/// card: while empty it is only a small "Add" button, so an unused field takes
/// no room; once it has notes they are shown rendered, with an Edit button;
/// while being edited there is a Preview button to get back.
///
/// The notes live in [controller], which the form saves, so there is no Save or
/// Cancel here.
class MarkdownNotesField extends StatefulWidget {
  /// Names the notes above them, e.g. "Sentence notes".
  final String label;

  /// The text of the button that starts the first note.
  final String addLabel;
  final TextEditingController controller;
  final String hintText;

  const MarkdownNotesField({
    super.key,
    required this.label,
    required this.controller,
    this.addLabel = 'Add notes',
    this.hintText = 'Markdown notes, e.g. **bold**, lists',
  });

  @override
  State<MarkdownNotesField> createState() => _MarkdownNotesFieldState();
}

class _MarkdownNotesFieldState extends State<MarkdownNotesField> {
  bool _editing = false;

  void _setEditing(bool editing) => setState(() => _editing = editing);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final notes = widget.controller.text;

    if (!_editing && notes.trim().isEmpty) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: TextButton.icon(
            icon: const Icon(Icons.edit_note, size: 18),
            label: Text(widget.addLabel),
            onPressed: () => _setEditing(true),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(widget.label, style: theme.textTheme.labelLarge),
              ),
              TextButton.icon(
                icon: Icon(_editing ? Icons.preview : Icons.edit, size: 18),
                label: Text(_editing ? 'Preview' : 'Edit'),
                onPressed: () => _setEditing(!_editing),
              ),
            ],
          ),
          if (_editing)
            MarkdownTextField(
              controller: widget.controller,
              autofocus: true,
              minLines: 2,
              maxLines: 4,
              decoration: InputDecoration(
                hintText: widget.hintText,
                border: const OutlineInputBorder(),
              ),
            )
          else
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.3,
                ),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: theme.colorScheme.outlineVariant),
              ),
              child: MarkdownContent(content: notes),
            ),
        ],
      ),
    );
  }
}
