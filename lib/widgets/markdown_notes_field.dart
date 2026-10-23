import 'package:flutter/material.dart';

import 'markdown_content.dart';

/// A multi-line Markdown field with an Edit/Preview toggle, like Vocab notes.
class MarkdownNotesField extends StatefulWidget {
  final String label;
  final TextEditingController controller;
  final String hintText;

  const MarkdownNotesField({
    super.key,
    required this.label,
    required this.controller,
    this.hintText = 'Markdown notes, e.g. **bold**, lists',
  });

  @override
  State<MarkdownNotesField> createState() => _MarkdownNotesFieldState();
}

class _MarkdownNotesFieldState extends State<MarkdownNotesField> {
  bool _preview = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
                icon: Icon(_preview ? Icons.edit : Icons.preview, size: 18),
                label: Text(_preview ? 'Edit' : 'Preview'),
                onPressed: () => setState(() => _preview = !_preview),
              ),
            ],
          ),
          if (_preview)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              constraints: const BoxConstraints(minHeight: 64),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.3,
                ),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: theme.colorScheme.outlineVariant),
              ),
              child: widget.controller.text.trim().isEmpty
                  ? const Text(
                      'No notes entered yet.',
                      style: TextStyle(color: Colors.grey),
                    )
                  : MarkdownContent(content: widget.controller.text),
            )
          else
            TextField(
              controller: widget.controller,
              minLines: 2,
              maxLines: 4,
              decoration: InputDecoration(
                hintText: widget.hintText,
                border: const OutlineInputBorder(),
              ),
            ),
        ],
      ),
    );
  }
}
