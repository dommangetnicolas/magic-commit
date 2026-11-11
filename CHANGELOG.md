# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.0.0] - 2026-11-11

### Added

- Menu bar panel listing your git projects with branch, changes, WIP and ahead/behind counts.
- **Commit**: stage everything and let `oco` write the message.
- **WIP**: instant commit with a `WIP` message.
- **Batch oco**: give every unpushed WIP commit an `oco`-generated message, safely, in a temporary worktree.
- **Push**: with a warning when WIP commits are still unpushed, and upstream setup for new branches.
- `batch-oco` command-line mode.
- Launch at login.

[Unreleased]: https://github.com/dommangetnicolas/magic-commit/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/dommangetnicolas/magic-commit/releases/tag/v1.0.0
