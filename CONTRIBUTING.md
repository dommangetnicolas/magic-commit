# Contributing

Thanks for your interest in Magic Commit! Bug reports, ideas and pull requests are welcome.

## Getting started

You need macOS 14+ and Xcode 15.3+ (or a Swift 5.10+ toolchain).

```bash
git clone https://github.com/dommangetnicolas/magic-commit.git
cd magic-commit
swift run          # runs the menu bar app from source
swift test         # runs the test suite
```

`swift test` does not need `oco`: the tests use a fake one.

To try the app against a fake `oco` by hand, put an executable named `oco` in a folder
and start the app with that folder prepended to its `PATH`:

```bash
MAGIC_COMMIT_EXTRA_PATH=/path/to/folder swift run
```

## Project layout

| Path | What it is |
| --- | --- |
| `Sources/MagicCommit/Git.swift` | All git operations: status parsing, commit, push, Batch oco |
| `Sources/MagicCommit/Shell.swift` | Runs child processes with the user's login-shell `PATH` |
| `Sources/MagicCommit/ProjectStore.swift` | App state: projects, statuses, running actions |
| `Sources/MagicCommit/MenuContentView.swift` | The SwiftUI menu bar panel |
| `Sources/MagicCommit/CLI.swift` | Headless `batch-oco` command |
| `scripts/build-app.sh` | Builds the `.app` bundle |

## Pull requests

- Keep changes focused; one topic per pull request.
- Add or update tests in `Tests/MagicCommitTests` when you change git logic.
- Make sure `swift build` and `swift test` pass.
- Add a line under **Unreleased** in [CHANGELOG.md](CHANGELOG.md) for user-visible changes.

## Releasing (maintainers)

See [docs/release.md](docs/release.md).
