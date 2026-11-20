# Releasing Magic Commit

Releases are built and published by GitHub Actions when you push a version tag.
You never upload anything by hand.

## Versioning

Magic Commit follows [Semantic Versioning](https://semver.org/):

- **Patch** (`1.0.1`): bug fixes only.
- **Minor** (`1.1.0`): new features that don't change existing behavior.
- **Major** (`2.0.0`): breaking changes, such as dropping a macOS version.

The version is never written in the source. `scripts/build-app.sh` reads it from the tag
(`v1.2.3` → `CFBundleShortVersionString` `1.2.3`) and uses the commit count as `CFBundleVersion`.

## Releasing from GitHub (recommended)

1. **Make sure `main` is green** and that **Unreleased** in [CHANGELOG.md](../CHANGELOG.md) lists
   everything that ships.

2. **Run "Prepare release".** In the Actions tab, open
   [Prepare release](../.github/workflows/prepare-release.yml), click **Run workflow**, and pick
   `patch`, `minor` or `major` (or type an exact version). From the terminal:

   ```bash
   gh workflow run prepare-release.yml -f bump=minor
   ```

   It moves the Unreleased entries under `## [1.2.3] - YYYY-MM-DD`, updates the comparison links,
   and opens a **Release 1.2.3** pull request from `release/v1.2.3`.

3. **Merge the pull request.** The [Release workflow](../.github/workflows/release.yml) then runs
   the tests, builds a universal (Apple silicon + Intel) app, tags the merge commit `v1.2.3`, and
   creates a GitHub release with `MagicCommit.zip` attached and the changelog section as notes.

   ```bash
   gh run watch
   ```

4. **Check the release.** Download `MagicCommit.zip` from the release page and confirm that the app
   launches and that Finder's **Get Info** shows the right version.

"Prepare release" needs **Settings → Actions → General → Allow GitHub Actions to create and approve
pull requests** to be enabled.

## Releasing by hand

Pushing a tag still works and runs the same Release workflow:

```bash
scripts/changelog.sh release 1.2.3   # update CHANGELOG.md
git switch -c release/v1.2.3 && git commit -am "Release 1.2.3"
# open and merge the pull request, then on the merged main:
git tag -a v1.2.3 -m "Magic Commit 1.2.3"
git push origin v1.2.3
```

Don't push the tag for a `release/v*` pull request you merged: merging it already publishes.

## Building a release locally

To reproduce what CI does, for example to test a build before tagging:

```bash
VERSION=1.2.3 ./scripts/build-app.sh --universal --zip
```

This writes `build/Magic Commit.app` and `build/MagicCommit.zip`.

## If something goes wrong

If the workflow fails before the release is created, fix the problem on `main`, then tag the fixed
commit (or move the tag if it was already pushed) to rerun it:

```bash
git tag -d v1.2.3
git push origin :refs/tags/v1.2.3
git tag -a v1.2.3 -m "Magic Commit 1.2.3"
git push origin v1.2.3
```

If a broken release has already been published, don't reuse its version number. Delete or
mark the release as a pre-release on GitHub, and ship a fix as the next patch version instead.

## Code signing and notarization

Release builds are ad-hoc signed, not signed with an Apple Developer ID or notarized. Gatekeeper
therefore blocks the first launch, and the README explains how users can get past it. Notarizing
would need a paid Apple Developer account, with its certificate and credentials stored as
repository secrets for the workflow.
