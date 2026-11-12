import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../services/audio_service.dart';
import '../services/locale_names.dart';
import '../services/tts_voice.dart';

/// What was picked in a [TtsLanguageSheet]: a locale for the `tts` prefix
/// (`zh-TW`), or null for the default language, without a prefix.
class TtsLanguageChoice {
  final String? locale;

  const TtsLanguageChoice(this.locale);
}

/// A bottom sheet for picking the language and region a TTS text is spoken
/// in, among those the device's TTS engine can speak, by name
/// (`Chinese (Taiwan)`) or code (`zh-TW`), with a search box.
///
/// The current language comes first: that of the text's prefix, and the
/// default language. Picking a locale writes the engine and that language's
/// voices to the log (logcat on Android), for finding out why a voice is or
/// is not used.
class TtsLanguageSheet extends StatefulWidget {
  /// The locale of the text's prefix, or null without one.
  final String? current;

  /// The language spoken without a prefix (`ko`).
  final String defaultLanguage;

  const TtsLanguageSheet({
    super.key,
    required this.current,
    required this.defaultLanguage,
  });

  /// The choice, or null when the sheet was closed without one.
  static Future<TtsLanguageChoice?> show(
    BuildContext context, {
    required String? current,
    required String defaultLanguage,
  }) => showModalBottomSheet<TtsLanguageChoice>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (_) =>
        TtsLanguageSheet(current: current, defaultLanguage: defaultLanguage),
  );

  /// The locales that can speak: those with an installed offline voice or a
  /// network voice.
  static Set<String> availableLocales(List<TtsVoice> voices) => {
    for (final voice in voices)
      if (!voice.offline || voice.installed != false) voice.locale,
  };

  /// [locales] in the order the sheet lists them: those of the [first]
  /// languages, then the rest, each by name.
  static List<String> ordered(Iterable<String> locales, Set<String> first) {
    int group(String locale) =>
        first.contains(TtsVoice.languageOf(locale)) ? 0 : 1;
    return locales.toList()..sort((a, b) {
      final byGroup = group(a) - group(b);
      if (byGroup != 0) return byGroup;
      return LocaleNames.of(a).compareTo(LocaleNames.of(b));
    });
  }

  /// Writes the engine and every voice of [locale]'s language to the log.
  static void logVoices(TtsVoiceList list, String locale) {
    final language = TtsVoice.languageOf(locale);
    final voices = list.voices.where((voice) => voice.language == language);
    debugPrint(
      'TTS voices for $locale (engine ${list.engine ?? 'unknown'}):\n'
      '${voices.map(_describe).join('\n')}',
    );
  }

  static String _describe(TtsVoice voice) => [
    '  ${voice.locale} ${voice.name}',
    voice.offline ? 'offline' : 'network',
    if (voice.installed != null)
      voice.installed! ? 'installed' : 'not installed',
  ].join(', ');

  @override
  State<TtsLanguageSheet> createState() => _TtsLanguageSheetState();
}

class _TtsLanguageSheetState extends State<TtsLanguageSheet> {
  late final Future<TtsVoiceList> _voices = context
      .read<AudioService>()
      .listVoices();
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool _matches(String locale, String query) =>
      query.isEmpty ||
      locale.toLowerCase().contains(query) ||
      LocaleNames.of(locale).toLowerCase().contains(query);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, scrollController) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                controller: _search,
                decoration: const InputDecoration(
                  hintText: 'Search languages',
                  prefixIcon: Icon(Icons.search),
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
            Expanded(
              child: FutureBuilder<TtsVoiceList>(
                future: _voices,
                builder: (context, snapshot) {
                  final list = snapshot.data;
                  if (list == null) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  return _buildList(theme, list, scrollController);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildList(
    ThemeData theme,
    TtsVoiceList list,
    ScrollController scrollController,
  ) {
    final available = TtsLanguageSheet.availableLocales(list.voices);
    if (available.isEmpty) {
      return const Center(child: Text('No text-to-speech voices available.'));
    }
    final current = widget.current;
    final firstLanguages = {
      if (current != null) TtsVoice.languageOf(current),
      TtsVoice.languageOf(widget.defaultLanguage),
    };
    final query = _search.text.trim().toLowerCase();
    final locales = TtsLanguageSheet.ordered(
      available.where((locale) => _matches(locale, query)),
      firstLanguages,
    );
    final defaultName = LocaleNames.of(widget.defaultLanguage);
    final showDefault =
        _matches(widget.defaultLanguage, query) || 'default'.contains(query);
    return ListView(
      controller: scrollController,
      children: [
        if (showDefault)
          _LocaleTile(
            title: 'Default ($defaultName)',
            code: 'no prefix',
            selected: current == null,
            onTap: () =>
                Navigator.of(context).pop(const TtsLanguageChoice(null)),
          ),
        for (final (index, locale) in locales.indexed) ...[
          if (index > 0 &&
              firstLanguages.contains(
                TtsVoice.languageOf(locales[index - 1]),
              ) &&
              !firstLanguages.contains(TtsVoice.languageOf(locale)))
            const Divider(),
          _LocaleTile(
            title: LocaleNames.of(locale),
            code: locale,
            selected: locale == current,
            onTap: () {
              TtsLanguageSheet.logVoices(list, locale);
              Navigator.of(context).pop(TtsLanguageChoice(locale));
            },
          ),
        ],
        if (locales.isEmpty && !showDefault)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'No language matches "${_search.text.trim()}".',
              style: theme.textTheme.bodyMedium,
            ),
          ),
      ],
    );
  }
}

class _LocaleTile extends StatelessWidget {
  final String title;
  final String code;
  final bool selected;
  final VoidCallback onTap;

  const _LocaleTile({
    required this.title,
    required this.code,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      dense: true,
      title: Text(title),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            code,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (selected) ...[
            const SizedBox(width: 8),
            Icon(Icons.check, size: 18, color: theme.colorScheme.primary),
          ],
        ],
      ),
      selected: selected,
      onTap: onTap,
    );
  }
}
