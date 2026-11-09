import 'package:flutter/material.dart';

import '../models/lesson.dart';
import '../providers/app_provider.dart';
import '../services/lesson_links.dart';

/// What [showLessonClashDialog] returns: the choice, and whether to make the
/// same one for the clashes after it.
typedef LessonClashAnswer = ({LessonClashChoice choice, bool forRest});

/// Asks which of two lessons with the same name in one folder is primary
/// (the other is overwritten by it), or whether to keep both by renaming
/// the incoming one. [importing] says the incoming one is a file being
/// imported; otherwise both are saved lessons. With [remaining] clashes (or,
/// when importing, files) after this one, it offers to answer them all the
/// same way. Returns null
/// if cancelled, which only saved lessons allow.
Future<LessonClashAnswer?> showLessonClashDialog(
  BuildContext context,
  LessonNameClash clash, {
  required bool importing,
  int remaining = 0,
}) => showDialog<LessonClashAnswer>(
  context: context,
  barrierDismissible: !importing,
  builder: (_) => LessonClashDialog(
    clash: clash,
    importing: importing,
    remaining: remaining,
  ),
);

class LessonClashDialog extends StatefulWidget {
  final LessonNameClash clash;
  final bool importing;
  final int remaining;

  const LessonClashDialog({
    super.key,
    required this.clash,
    required this.importing,
    this.remaining = 0,
  });

  @override
  State<LessonClashDialog> createState() => _LessonClashDialogState();
}

class _LessonClashDialogState extends State<LessonClashDialog> {
  LessonClashChoice _choice = LessonClashChoice.keepBoth;
  bool _forRest = false;

  String _describe(Lesson lesson) {
    final words = lesson.vocabularies.length;
    return '${LessonLink.virtualPathText(lesson)} · '
        '$words ${words == 1 ? 'word' : 'words'}';
  }

  String get _consequence {
    final importing = widget.importing;
    return switch (_choice) {
      LessonClashChoice.keepExisting =>
        importing
            ? 'The imported file is skipped.'
            : 'The other lesson is removed. Words only it has move to the '
                  'primary one, with their study progress, and its AI chat '
                  'joins the primary one’s.',
      LessonClashChoice.keepIncoming =>
        importing
            ? 'The saved lesson takes the imported name, text and words. Its '
                  'words keep their study progress, and words not in the '
                  'file stay.'
            : 'The saved lesson is removed. Words only it has move to the '
                  'primary one, with their study progress, and its AI chat '
                  'joins the primary one’s.',
      LessonClashChoice.keepBoth =>
        'The ${importing ? 'imported' : 'other'} lesson is named '
            '“${widget.clash.renamedTitle}”.',
    };
  }

  @override
  Widget build(BuildContext context) {
    final clash = widget.clash;
    final importing = widget.importing;
    final folder = clash.existing.folderPath;
    final where = folder.isEmpty
        ? 'at the top level'
        : 'in ${formatHierarchyPath(folder)}';
    final remaining = widget.remaining;

    return AlertDialog(
      title: const Text('Two lessons with one name'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'A folder can hold only one lesson named '
              '“${clash.existing.displayTitle}”, and '
              '${importing ? 'the import adds another' : 'there are two'} '
              '$where. Which one is primary? The other is overwritten by it.',
            ),
            const SizedBox(height: 8),
            RadioGroup<LessonClashChoice>(
              groupValue: _choice,
              onChanged: (value) => setState(() => _choice = value ?? _choice),
              child: Column(
                children: [
                  RadioListTile<LessonClashChoice>(
                    value: LessonClashChoice.keepExisting,
                    title: Text(importing ? 'Saved lesson' : 'First lesson'),
                    subtitle: Text(_describe(clash.existing)),
                  ),
                  RadioListTile<LessonClashChoice>(
                    value: LessonClashChoice.keepIncoming,
                    title: Text(importing ? 'Imported file' : 'Second lesson'),
                    subtitle: Text(_describe(clash.incoming)),
                  ),
                  RadioListTile<LessonClashChoice>(
                    value: LessonClashChoice.keepBoth,
                    title: const Text('Keep both'),
                    subtitle: Text(
                      'Rename the ${importing ? 'imported' : 'second'} one',
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                _consequence,
                key: const ValueKey('clash-consequence'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            if (remaining > 0)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _forRest,
                onChanged: (value) => setState(() => _forRest = value ?? false),
                title: Text(
                  importing
                      ? 'Do the same for any other clash in this import'
                      : 'Do the same for the other $remaining '
                            '${remaining == 1 ? 'clash' : 'clashes'}',
                ),
              ),
          ],
        ),
      ),
      actions: [
        if (!importing)
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Not now'),
          ),
        FilledButton(
          onPressed: () => Navigator.pop<LessonClashAnswer>(context, (
            choice: _choice,
            forRest: _forRest,
          )),
          child: const Text('Continue'),
        ),
      ],
    );
  }
}
