# AGENTS.md

Flutter app (Dart, `provider` state management). See [README.md](README.md) for an overview and [docs/architecture.md](docs/architecture.md) for the source layout.

## Commands

- `flutter pub get`: install dependencies
- `flutter test`: run all tests (`flutter test test/<file>.dart` for one)
- `dart format .`: format (the repo formats on save; keep diffs formatted)
- `flutter analyze`: must stay free of warnings
- `flutter test integration_test -d macos` (or `-d linux`): keychain and network checks on a real desktop build; CI runs them in `.github/workflows/desktop.yml` when platform code changes
- `cd worker; npm test`: run the sync Worker tests (run from `worker/`; `npm run typecheck` type-checks it)

## Conventions

- 2-space indentation, Dart defaults.
- Lesson/vocabulary parsing lives only in `lib/services/yaml_parser_service.dart`. Do not parse lesson syntax elsewhere.
- SRS scheduling lives in `lib/services/srs_service.dart`.
- Make commits using a conventional commit message and a detailed body.

## Rules

- Every behavior change or bug fix needs a test in `test/`.
- When the lesson syntax changes, update `docs/lesson-format.md`. `test/docs_test.dart` parses its examples and will fail if they break.
- Keep `README.md` short; put detail in `docs/`.
- Don't commit machine-specific paths or personal study data.
- Don't commit secrets. Real values go in the git-ignored `env.json`, `worker/.dev.vars` and `worker/wrangler.jsonc`, or in `wrangler secret put`; commit only the `*.example*` files. GitGuardian scans every PR as a GitHub App, outside `ci.yml`. If it flags a real secret, revoke the secret at its provider; removing it from the branch is not enough.
- Track bugs and planned work in GitHub Issues, not in the repo. Reference the issue in PRs (e.g. "Fixes #12")
- In `testWidgets`, wrap real async work (`Future.delayed`, timers, storage I/O) in `tester.runAsync`; the fake-async zone otherwise hangs the test.

## Debug sessions and hot restart

- Don't start a Flutter debug session and don't try to hot restart the running app. VS Code doesn't start a Flutter debug session by itself, the Dart MCP server needs one, and a session that an agent starts is never ended by the agent. This is waiting for an upstream fix from Microsoft.
- A Dart MCP server that is missing or fails to start is expected, not a failure to report. Don't write it into commit messages or PR descriptions (for example "The Dart MCP server failed to start, so hot restart was never done"), and don't list hot restart as unverified. Verify with `flutter analyze` and `flutter test`; checking the running app is left to the person.

## Environments without Flutter/Dart (e.g. cloud agents)

If `flutter` or `dart` isn't available, you can't run tests or `flutter analyze`, and the CI workflow needs manual approval to run. In that case:

- Formatting does not need Flutter. Install the Dart SDK from conda-forge (`dart-sdk`, any version meeting the `sdk:` constraint in `pubspec.yaml`), e.g. `micromamba create -y -p "$HOME/.dart-env" -c conda-forge dart-sdk`, then run `"$HOME/.dart-env/bin/dart" format lib test` before committing. Do not run `dart analyze` or `dart test` with it: the app depends on Flutter, which conda-forge does not have.
- If the Dart SDK can't be installed either, hand-format to Dart style: 2-space indent, trailing commas on multi-line argument lists and collections, lines ≤ 80 columns, and expect `dart format` to change something.
- Still add or update tests in `test/`, written carefully since they can't be run.
- Keep changes small and focused so they are easy to fix locally.
- State in the PR description that tests, analyze and format were not run.
- Before opening a PR, tell the person what to fetch and run locally first (the commands from `ci.yml` that could not run here, scoped to the changed files where possible), so the PR does not trigger a failing CI. Also list any step that needs a manual check outside CI (for example deploying the Worker, applying a migration, or trying a change in the running app), or say that none does. Open the PR only after they confirm.
