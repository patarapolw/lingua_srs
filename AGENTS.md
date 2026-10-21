# AGENTS.md

Flutter app (Dart, `provider` state management). See [README.md](README.md) for an overview and [docs/architecture.md](docs/architecture.md) for the source layout.

## Commands

- `flutter pub get`: install dependencies
- `flutter test`: run all tests (`flutter test test/<file>.dart` for one)
- `dart format .`: format (the repo formats on save; keep diffs formatted)
- `flutter analyze`: must stay free of warnings

## Conventions

- 2-space indentation, Dart defaults.
- Lesson/vocabulary parsing lives only in `lib/services/yaml_parser_service.dart`. Do not parse lesson syntax elsewhere.
- SRS scheduling lives in `lib/services/srs_service.dart`.

## Rules

- Every behavior change or bug fix needs a test in `test/`.
- When the lesson syntax changes, update `docs/lesson-format.md`. `test/docs_test.dart` parses its examples and will fail if they break.
- Keep `README.md` short; put detail in `docs/`.
- Don't commit machine-specific paths or personal study data.
