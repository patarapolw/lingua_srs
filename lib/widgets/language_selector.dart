import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../providers/app_provider.dart';
import '../services/locale_names.dart';

/// Picks the language shown, in an app bar: lessons, pools, the study queue
/// and Study activity are of one language at a time (`AppProvider
/// .activeLanguage`). Renders nothing while only one language is being
/// learned, so there is nothing to pick.
class LanguageSelector extends StatelessWidget {
  const LanguageSelector({super.key});

  /// The name shown for [language], a `Lesson.languageKey`:
  /// `Chinese (Taiwan)` for `zh-tw`.
  static String nameOf(String language) => LocaleNames.of(language);

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppProvider>();
    final languages = provider.languages;
    final active = provider.activeLanguage;
    if (languages.length < 2 || active == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    // The name on a wide screen; the code where the app bar is short of room.
    final compact = MediaQuery.sizeOf(context).width < 700;
    return PopupMenuButton<String>(
      key: const ValueKey('language-selector'),
      tooltip: 'Language: ${nameOf(active)}',
      initialValue: active,
      onSelected: provider.setActiveLanguage,
      itemBuilder: (_) => [
        for (final language in languages)
          PopupMenuItem<String>(
            value: language,
            child: Row(
              children: [
                Icon(
                  Icons.check,
                  size: 20,
                  color: language == active
                      ? theme.colorScheme.primary
                      : Colors.transparent,
                ),
                const SizedBox(width: 12),
                Flexible(child: Text(nameOf(language))),
              ],
            ),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.language, size: 20),
            const SizedBox(width: 6),
            Text(
              compact ? active.toUpperCase() : nameOf(active),
              style: theme.textTheme.labelLarge,
            ),
            const Icon(Icons.arrow_drop_down),
          ],
        ),
      ),
    );
  }
}
