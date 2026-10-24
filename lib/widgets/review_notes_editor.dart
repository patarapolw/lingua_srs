import 'package:flutter/material.dart';

import '../models/srs_card.dart';
import 'markdown_content.dart';
import 'markdown_text_field.dart';

/// True while a text field has focus, so single-key shortcuts (space, R, 1-4,
/// ...) must not fire.
bool isEditingText() {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return false;
  // The focused node belongs either to the EditableText or to a Focus widget
  // it builds, depending on the Flutter version.
  return context.widget is EditableText ||
      context.findAncestorWidgetOfExactType<EditableText>() != null;
}

/// The review note of the card being studied, editable from its back side.
///
/// Only this card's direction is affected (each direction has its own note).
/// Markdown with a Preview toggle, like vocab notes. Nothing is shown while
/// the note is empty except a small "Add review note" button, so the back of
/// a card stays uncluttered.
class ReviewNotesEditor extends StatefulWidget {
  final SrsCard card;
  final ValueChanged<String> onSave;

  const ReviewNotesEditor({
    super.key,
    required this.card,
    required this.onSave,
  });

  @override
  State<ReviewNotesEditor> createState() => _ReviewNotesEditorState();
}

class _ReviewNotesEditorState extends State<ReviewNotesEditor> {
  final _controller = TextEditingController();
  bool _editing = false;
  bool _preview = false;

  String get _label => widget.card.direction == CardDirection.targetToNative
      ? 'KO ➔ EN'
      : 'EN ➔ KO';

  void _start() {
    setState(() {
      _controller.text = widget.card.backNotes;
      _editing = true;
      _preview = false;
    });
  }

  void _save() {
    widget.onSave(_controller.text.trim());
    setState(() => _editing = false);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Widget _panel(
    ThemeData theme, {
    required Widget header,
    required Widget body,
  }) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [header, const SizedBox(height: 6), body],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = Text(
      'Review notes · $_label',
      style: theme.textTheme.labelMedium,
    );

    if (!_editing) {
      final notes = widget.card.backNotes;
      if (notes.trim().isEmpty) {
        return Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: TextButton.icon(
              icon: const Icon(Icons.edit_note, size: 18),
              label: const Text('Add review note'),
              onPressed: _start,
            ),
          ),
        );
      }
      return _panel(
        theme,
        header: Row(
          children: [
            Expanded(child: title),
            IconButton(
              icon: const Icon(Icons.edit_outlined, size: 18),
              tooltip: 'Edit review note',
              visualDensity: VisualDensity.compact,
              onPressed: _start,
            ),
          ],
        ),
        body: MarkdownContent(content: notes),
      );
    }

    return _panel(
      theme,
      header: Row(
        children: [
          Expanded(child: title),
          TextButton.icon(
            icon: Icon(_preview ? Icons.edit : Icons.preview, size: 18),
            label: Text(_preview ? 'Edit' : 'Preview'),
            onPressed: () => setState(() => _preview = !_preview),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_preview)
            Container(
              padding: const EdgeInsets.all(12),
              constraints: const BoxConstraints(minHeight: 80),
              child: _controller.text.trim().isEmpty
                  ? const Text(
                      'No notes entered yet.',
                      style: TextStyle(color: Colors.grey),
                    )
                  : MarkdownContent(content: _controller.text),
            )
          else
            MarkdownTextField(
              controller: _controller,
              autofocus: true,
              minLines: 3,
              maxLines: 6,
              decoration: const InputDecoration(
                hintText: 'Markdown notes, e.g. **bold**, lists',
                border: OutlineInputBorder(),
              ),
            ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => setState(() => _editing = false),
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 8),
              FilledButton(onPressed: _save, child: const Text('Save')),
            ],
          ),
        ],
      ),
    );
  }
}
