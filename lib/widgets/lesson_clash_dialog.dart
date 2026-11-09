import 'package:flutter/material.dart';

import '../models/lesson.dart';
import '../models/vocab_item.dart';
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

  /// Words of [from] that [into] does not have, matched the way an import
  /// matches them: by id, or by the same word and meaning.
  static int _wordsOnlyIn(Lesson from, Lesson into) {
    String meaning(VocabItem vocab) =>
        '${vocab.targetWord.trim().toLowerCase()}\u0000'
        '${vocab.translation.trim().toLowerCase()}';
    final ids = {for (final vocab in into.vocabularies) vocab.id};
    final meanings = {for (final vocab in into.vocabularies) meaning(vocab)};
    return from.vocabularies
        .where(
          (vocab) =>
              !ids.contains(vocab.id) && !meanings.contains(meaning(vocab)),
        )
        .length;
  }

  static String _words(int count) => count == 1 ? '1 word' : '$count words';

  /// What the choice does.
  String get _consequence {
    final importing = widget.importing;
    final other = importing ? 'imported' : 'second';
    return switch (_choice) {
      LessonClashChoice.keepExisting =>
        importing
            ? 'The imported file is skipped. The saved lesson stays as it is.'
            : 'The first lesson keeps its name and text. The second lesson '
                  'is removed, and its AI chat joins the first one’s.',
      LessonClashChoice.keepIncoming =>
        importing
            ? 'The saved lesson takes the file’s name and text, and its words '
                  'are updated from the file, keeping their study progress.'
            : 'The second lesson keeps its name and text. The first lesson '
                  'is removed, and its AI chat joins the second one’s.',
      LessonClashChoice.keepBoth =>
        'Both lessons stay. The $other one is named '
            '“${widget.clash.renamedTitle}”.',
    };
  }

  /// What the choice keeps that the person may not expect, or null.
  String? get _warning {
    final clash = widget.clash;
    final (kept, gone) = switch (_choice) {
      LessonClashChoice.keepExisting => (clash.existing, clash.incoming),
      LessonClashChoice.keepIncoming => (clash.incoming, clash.existing),
      LessonClashChoice.keepBoth => (null, null),
    };
    if (kept == null || gone == null) return null;
    if (widget.importing) {
      if (_choice != LessonClashChoice.keepIncoming) return null;
      final extra = _wordsOnlyIn(clash.existing, clash.incoming);
      if (extra == 0) return null;
      return '${_words(extra)} in the saved lesson ${extra == 1 ? 'is' : 'are'} '
          'not in the file. ${extra == 1 ? 'It is' : 'They are'} not deleted: '
          '${extra == 1 ? 'it stays' : 'they stay'} in the lesson with '
          '${extra == 1 ? 'its' : 'their'} study progress. Delete '
          '${extra == 1 ? 'it' : 'them'} from the lesson’s vocabulary if you no '
          'longer want ${extra == 1 ? 'it' : 'them'}.';
    }
    final moved = _wordsOnlyIn(gone, kept);
    final name = identical(kept, clash.existing) ? 'first' : 'second';
    final goneName = name == 'first' ? 'second' : 'first';
    // The removed lesson's text goes, unless the kept one has none, which
    // then takes it (AppProvider._absorbLesson).
    final goneText = gone.markdownContent.trim();
    final keptText = kept.markdownContent.trim();
    final text =
        goneText.isNotEmpty && keptText.isNotEmpty && goneText != keptText
        ? ' The $goneName lesson’s text is not kept.'
        : '';
    if (moved == 0) return text.isEmpty ? null : text.trim();
    return '${_words(moved)} only the $goneName lesson has '
        '${moved == 1 ? 'moves' : 'move'} into the $name, with '
        '${moved == 1 ? 'its' : 'their'} study progress. No words are deleted; '
        'remove ${moved == 1 ? 'it' : 'them'} from the lesson’s vocabulary if '
        'you don’t want ${moved == 1 ? 'it' : 'them'}.$text';
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
            if (_warning case final warning?)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      size: 18,
                      color: Theme.of(context).colorScheme.tertiary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        warning,
                        key: const ValueKey('clash-warning'),
                        style: Theme.of(context).textTheme.bodySmall
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
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
