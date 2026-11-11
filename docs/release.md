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

## Checklist

1. **Make sure `main` is green.** CI must pass on the commit you're about to release.

   ```bash
   git switch main && git pull
   swift test
   ```

2. **Update the changelog.** In [CHANGELOG.md](../CHANGELOG.md), move the entries under
   **Unreleased** to a new heading such as `## [1.2.3] - YYYY-MM-DD`, and update the comparison
   links at the bottom. Commit it:

   ```bash
   git commit -am "Release 1.2.3"
   git push
   ```

3. **Tag and push.**

   ```bash
   git tag -a v1.2.3 -m "Magic Commit 1.2.3"
   git push origin v1.2.3
   ```

4. **Watch the workflow.** The [Release workflow](../.github/workflows/release.yml) runs the tests,
   builds a universal (Apple silicon + Intel) app, and creates a GitHub release with
   `MagicCommit.zip` attached and notes generated from the merged pull requests.

   ```bash
   gh run watch
   ```

5. **Check the release.** Open the release page, download `MagicCommit.zip`, and confirm that the
   app launches and that Finder's **Get Info** shows the right version. Edit the release notes if needed. The
   changelog section for this version is usually the best summary.

## Building a release locally

To reproduce what CI does, for example to test a build before tagging:

```bash
VERSION=1.2.3 ./scripts/build-app.sh --universal --zip
```

This writes `build/Magic Commit.app` and `build/MagicCommit.zip`.

## If something goes wrong

If the workflow fails before the release is created, fix the problem on `main`, then move the tag:

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
