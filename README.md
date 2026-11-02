# LinguaSRS

SRS that puts language learning first: custom lessons, lesson-by-lesson vocabulary review, and a shared sentence pool. A Flutter app for **Windows, macOS, Linux, Android and iOS**, using an Anki-style SM-2 spaced repetition system.

## Screenshots

<table>
  <tr>
    <th align="center">Desktop</th>
    <th align="center">Android</th>
  </tr>
  <tr>
    <td valign="top"><img src="docs/images/desktop-lessons.png" alt="Desktop lessons dashboard with daily review queue" width="100%"></td>
    <td valign="top"><img src="docs/images/android-lessons.png" alt="LinguaSRS lessons dashboard on Android" width="100%"></td>
  </tr>
</table>

<details>
<summary>More desktop screenshots</summary>

<p align="center">
  <img src="docs/images/desktop-vocab-pool.png" alt="Desktop vocabulary pool with search and part-of-speech filters" width="49%">
  <img src="docs/images/desktop-sentences.png" alt="Desktop shared sentence pool" width="49%">
</p>
</details>

## Highlights

- **Lessons**: create lessons in-app or import Markdown/YAML files, folders, and ZIPs. Organize lessons into nested units, re-import updates without losing review progress, and read Markdown lessons in-app. See [lesson format](docs/lesson-format.md).
- **Flexible flashcards**: study Korean ➔ English or English ➔ Korean, with defaults by part of speech and per-word overrides. Cards can show random example sentences, cloze deletions, disambiguation cues, and Markdown notes.
- **Adaptive review**: SM-2 scheduling with due and new cards, configurable rolling review limits, and short-interval repeats. *Again* cards return later in the session; review recent mistakes across lessons or reset progress for a lesson, word, or card direction.
- **Shared pools**: browse, search, edit, and link sentences across lessons. Find distinct vocabulary in Korean or English, with part-of-speech filters and lesson references.
- **Audio and pronunciation**: stream recordings on first play and cache them for offline playback. Use offline system TTS on Android or streamed, cached TTS on other platforms.
- **AI discussions**: ask DeepSeek about a vocabulary card or lesson, explore suggested and related questions, and revisit locally saved discussions.
- **Responsive interface**: desktop navigation and review controls alongside touch-friendly mobile navigation and editors.
- **Keyboard-first**: Anki-style [hotkeys](docs/hotkeys.md), including card navigation and undo.

Currently only Korean ➔ English is supported. Full details in [docs/features.md](docs/features.md).

## Running

```bash
flutter pub get
flutter run -d windows            # or macos, linux, <android/ios device id>
flutter test
```

## Docs

- [Features](docs/features.md)
- [Lesson format](docs/lesson-format.md)
- [Keyboard shortcuts](docs/hotkeys.md)
- [Architecture](docs/architecture.md)
- [Issues](https://github.com/patarapolw/lingua_srs/issues): bugs, ideas and planned work
- [AGENTS.md](AGENTS.md): conventions for contributors and coding agents
