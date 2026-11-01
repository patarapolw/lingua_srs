# LinguaSRS

SRS that puts language learning first: custom lessons, lesson-by-lesson vocabulary review, and a shared sentence pool. A Flutter app for **Windows, macOS, Linux, Android and iOS**, using an Anki-style SM-2 spaced repetition system.

## Screenshots

<p align="center">
  <img src="docs/images/desktop-lessons.png" alt="Desktop lessons dashboard with daily review queue" width="49%">
  <img src="docs/images/desktop-vocab-pool.png" alt="Desktop vocabulary pool with search and part-of-speech filters" width="49%">
</p>
<p align="center">
  <img src="docs/images/desktop-sentences.png" alt="Desktop shared sentence pool" width="49%">
</p>
<p align="center">
  <img src="docs/images/android-lessons.png" alt="LinguaSRS lessons dashboard on a Pixel Fold Android emulator" width="32%">
</p>

## Highlights

- **Lessons as Markdown + YAML**: import files, folders or ZIPs; group lessons into units and nested folders with `::`; read the full Markdown lesson in-app. See [lesson format](docs/lesson-format.md).
- **Smart cards**: direction defaults by part of speech, per-item overrides, random example sentence on the front, cloze deletion for EN ➔ KO.
- **Sentence pool**: browse, edit and link sentences across lessons.
- **Vocab pool**: browse and search every word across lessons, in Korean or English.
- **Audio**: stream-on-first-play with offline caching; offline system TTS on Android.
- **Adaptive review**: *Again* cards return a few cards later, interleaved with new cards; review recent mistakes across lessons at any time.
- **Review controls**: flip cards, navigate back through answered cards, and undo a rating.
- **Reset progress**: reset SRS for a whole lesson or an individual word without changing card visibility.
- **AI discussions**: ask DeepSeek about the current card or a whole lesson; chats are saved locally.
- **Keyboard-first**: Anki-style [hotkeys](docs/hotkeys.md), with undo.

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
