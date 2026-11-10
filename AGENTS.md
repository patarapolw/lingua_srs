# AGENTS.md

Flutter app (Dart, `provider` state management). See [README.md](README.md) for an overview and [docs/architecture.md](docs/architecture.md) for the source layout.

## Commands

- `flutter pub get`: install dependencies
- `flutter test`: run all tests (`flutter test test/<file>.dart` for one)
- `dart format lib test`: format (the same folders `ci.yml` checks; the repo formats on save)
- `flutter analyze`: must stay free of warnings
- `flutter test integration_test -d macos` (or `-d linux`): keychain and network checks on a real desktop build; CI runs them in `.github/workflows/desktop.yml` when platform code changes
- `cd worker; npm test`: run the sync Worker tests (run from `worker/`; `npm run typecheck` type-checks it)

## Conventions

- 2-space indentation, Dart defaults.
- Lesson/vocabulary parsing lives only in `lib/services/yaml_parser_service.dart`. Do not parse lesson syntax elsewhere.
- SRS scheduling lives in `lib/services/srs_service.dart`.
- Make commits using a conventional commit message with a scope and a detailed body, e.g. `feat(study): …` or `fix(sync): …`. The scope is the area of the app; `git log` shows the ones in use.
- Name branches `<type>-<issue>-<what-it-does>`: the conventional commit type, the issue number when there is one, and a few lowercase hyphenated words, e.g. `fix-92-undo-review-count` or `docs-agents-branch-naming`. Claude agents prefix the name with `claude/` (`claude/fix-92-undo-review-count`). A session may start on, or be told to push to, a generated name such as `ccr-…`: rename the branch to a meaningful one (`git branch -m <name>`) before the first push to `origin` and before opening a PR. A PR can't change its branch later. Use one branch per PR; after a merge, start a new branch.

## Rules

- Run `dart format lib test` before every commit and commit everything it changes, including files you didn't edit. Cloud agents often can't run the formatter, so unformatted code can reach `main`; the next local commit cleans it up.
- Every behavior change or bug fix needs a test in `test/`.
- When the lesson syntax changes, update `docs/lesson-format.md`. `test/docs_test.dart` parses its examples and will fail if they break.
- When you add, rename or delete a Dart file under `lib/`, update its line in `docs/architecture.md`. `test/docs_test.dart` fails if a file is missing from it or listed after it is gone.
- Keep `README.md` short; put detail in `docs/`.
- Don't commit machine-specific paths or personal study data.
- Don't commit secrets. Real values go in the git-ignored `env.json`, `worker/.dev.vars` and `worker/wrangler.jsonc`, or in `wrangler secret put`; commit only the `*.example*` files. GitGuardian scans every PR as a GitHub App, outside `ci.yml`. If it flags a real secret, revoke the secret at its provider; removing it from the branch is not enough.
- Track bugs and planned work in GitHub Issues, not in the repo. Reference the issue in PRs (e.g. "Fixes #12")
- In `testWidgets`, wrap real async work (`Future.delayed`, timers, storage I/O) in `tester.runAsync`; the fake-async zone otherwise hangs the test.

## Debug sessions and hot restart

- If the person has a Flutter debug session running and the Dart MCP server is connected to it, hot reload after your change passes `flutter analyze` (hot restart after changing state or `main`). Don't start a second session for an app that is already running; if you start one, end it before you finish.
- A Dart MCP server that is missing or fails to start is expected, not a failure to report. Don't write it into commit messages or PR descriptions (for example "The Dart MCP server failed to start, so hot restart was never done"), and don't list hot restart as unverified. Verify with `flutter analyze` and `flutter test`; checking the running app is left to the person.

## Environments without Flutter/Dart (e.g. cloud agents)

If `flutter` or `dart` isn't available, you can't run tests or `flutter analyze`. In that case:

- Formatting does not need Flutter. Install the Dart SDK alone with `tool/install_dart_sdk.sh`, which prints the path of `dart` (latest stable, like CI; pass a version to pin one), then run `"$(tool/install_dart_sdk.sh)" format lib test` before committing. It downloads Google's official zip from `storage.googleapis.com`, which cloud sessions can reach. Don't use micromamba or conda: micromamba is not installed in cloud sessions, and its installer hosts (`micro.mamba.pm`, `api.anaconda.org`) and GitHub release downloads are blocked there. Do not run `dart analyze` or `dart test` on the app with it: the app depends on Flutter.
- If the Dart SDK can't be installed either, hand-format to Dart style: 2-space indent, trailing commas on multi-line argument lists and collections, lines ≤ 80 columns, and expect `dart format` to change something.
- Still add or update tests in `test/`, written carefully since they can't be run.
- Keep changes small and focused so they are easy to fix locally.
- In the PR description, state that tests, analyze and format were not run here. CI runs all three; once CI passes, count them as done, with no checkbox.
- Give checkboxes only to checks CI doesn't cover: manual checks (below) and checks that must be run locally, such as `flutter test integration_test -d macos` when `desktop.yml` didn't run it. Leave them unticked for the person; never tick one, or write that a check ran locally, unless the person says so. When told a check passed without being told where it ran, ask rather than guess.
- Open the PR anyway. It's fine for CI to fail on format, analyze or tests; a local agent with Flutter will fix it on the same PR.
- CI runs on your pushes, `flutter test` before the format check. You may fix a failure from here only when the log names its cause: an analyzer warning at a file and line, or a failing test whose expected/actual or stack trace points into the changed code. Push at most one fix per failure. If CI still fails, or finding the cause needs the app or a debugger, stop and leave it for a local session.
- Never push for formatting alone. The next local commit formats.
- In the PR description, list any step that needs a manual check outside CI (for example deploying the Worker, applying a migration, or trying a change in the running app) as unticked boxes too, or say that none does.
