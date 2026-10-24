# LinguaSRS

SRS that puts language learning first: custom lessons, lesson-by-lesson vocabulary review, and a shared sentence pool. A Flutter app for **Windows, macOS, Linux, Android and iOS**, using an Anki-style SM-2 spaced repetition system.

<!--
Add screenshots here once captured, e.g.:
<p align="center">
  <img src="docs/images/dashboard.png" alt="Lesson dashboard" width="48%">
  <img src="docs/images/study-mobile.png" alt="Study view on mobile" width="22%">
</p>
-->

## Highlights

- **Lessons as Markdown + YAML**: import files, folders or ZIPs; nested lesson hierarchy with `::`. See [lesson format](docs/lesson-format.md).
- **Smart cards**: direction defaults by part of speech, per-item overrides, random example sentence on the front, cloze deletion for EN ➔ KO.
- **Sentence pool**: browse, edit and link sentences across lessons.
- **Audio**: stream-on-first-play with offline caching; offline system TTS on Android.
- **Adaptive review**: recent-mistakes queue, re-queuing of *Again* cards, rolling 24-hour review limit.
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
