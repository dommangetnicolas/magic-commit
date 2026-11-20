# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.2.0] - 2026-11-20

### Added

- OpenCode as a message generator: pick **OpenCode** from the ✨ menu in the panel's footer. It runs your local `opencode` CLI (your OpenCode default model, override with the `opencodeModel` default) with the same prompt as Claude Code.
- `--generator opencode` option for the `batch-oco` command.

## [1.1.0] - 2026-11-15

### Added

- Worktree support: linked worktrees of each project are discovered automatically and listed under it, each with its own status and Commit, WIP, Batch oco and Push buttons. Clean worktrees fold behind a toggle.
- **Remove Worktree** in a worktree's menu, for clean worktrees (the branch is kept).
- Claude Code as a message generator: pick **Claude Code** or **OpenCommit** from the ✨ menu in the panel's footer. Claude mode runs your local `claude` CLI (Haiku by default, override with the `claudeModel` default) and follows your repository's commit style.
- `--generator claude|oco` option for the `batch-oco` command.

### Changed

- Adding a linked worktree's folder adds its main repository; projects saved as worktrees are migrated the same way.
- Batch oco locks its temporary worktree, and temporary worktrees left behind by a crash are cleaned up on the next refresh.

## [1.0.0] - 2026-11-11

### Added

- Menu bar panel listing your git projects with branch, changes, WIP and ahead/behind counts.
- **Commit**: stage everything and let `oco` write the message.
- **WIP**: instant commit with a `WIP` message.
- **Batch oco**: give every unpushed WIP commit an `oco`-generated message, safely, in a temporary worktree.
- **Push**: with a warning when WIP commits are still unpushed, and upstream setup for new branches.
- `batch-oco` command-line mode.
- Launch at login.

[Unreleased]: https://github.com/dommangetnicolas/magic-commit/compare/v1.2.0...HEAD
[1.2.0]: https://github.com/dommangetnicolas/magic-commit/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/dommangetnicolas/magic-commit/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/dommangetnicolas/magic-commit/releases/tag/v1.0.0
