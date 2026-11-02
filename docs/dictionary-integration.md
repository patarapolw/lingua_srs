# Dictionary app integration (proposal)

How a dedicated dictionary app could send a new lesson, or vocab for an existing lesson, to LinguaSRS. This is a design note; the inbound interface is not implemented yet.

## Payload

Send text in the [lesson format](lesson-format.md). The dictionary may carry sentences that are not in the Sentence Pool; they only enter the pool once the vocab that owns them is added to a lesson.

- **New lesson**: a full lesson document with a lesson name (`Unit::Lesson`).
- **Add vocab to an existing lesson**: a document with the same lesson name and only the new entries under `vocabulary:`.

All parsing stays in `YamlParserService.parseLessonYaml`; the receiver must not parse lesson syntax itself.

## Receiving side

1. The OS hands the app text through a share/intent entry point, or a custom URL (for example `linguasrs://import?lesson=...`). Android needs an `intent-filter` for `ACTION_SEND` with `text/plain` in `AndroidManifest.xml` (the app only declares the launcher filter today); iOS needs a share extension or URL scheme; desktop can use a URL scheme or a watched drop folder.
2. A thin listener (a plugin such as `app_links` or `receive_sharing_intent`) forwards the text to `AppProvider`.
3. `AppProvider.importYaml(text, defaultTitle:, defaultUnitTitle:)` creates the lesson. For adding to an existing one, parse the vocab and call `AppProvider.addVocabToLesson(lessonId, vocab)`, which reuses progress for vocab already known.
4. Show the existing import preview/validation (`yaml_import_view.dart`) before saving, so a bad payload from another app never changes data silently.
