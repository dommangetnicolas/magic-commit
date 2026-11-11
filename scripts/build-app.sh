#!/usr/bin/env bash
# Builds a release binary and wraps it in "build/Magic Commit.app".
#
# Usage:
#   scripts/build-app.sh [--universal] [--install] [--zip]
#
#   --universal  build for both Apple silicon and Intel
#   --install    copy the app to /Applications
#   --zip        also create build/MagicCommit.zip (for releases)
#
# The version comes from $VERSION, or from the latest git tag (v1.2.3 -> 1.2.3).
set -euo pipefail
cd "$(dirname "$0")/.."

UNIVERSAL=false INSTALL=false ZIP=false
for arg in "$@"; do
  case "$arg" in
    --universal) UNIVERSAL=true ;;
    --install) INSTALL=true ;;
    --zip) ZIP=true ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

BUILD_ARGS=(-c release)
if $UNIVERSAL; then BUILD_ARGS+=(--arch arm64 --arch x86_64); fi
swift build "${BUILD_ARGS[@]}"
BIN="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)/MagicCommit"

VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null || echo 0.0.0)}"
VERSION="${VERSION#v}"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

APP="build/Magic Commit.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MagicCommit"
cp Resources/Info.plist "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null 2>&1

echo "Built $APP ($VERSION, build $BUILD_NUMBER)"

if $ZIP; then
  rm -f build/MagicCommit.zip
  ditto -c -k --keepParent "$APP" build/MagicCommit.zip
  echo "Created build/MagicCommit.zip"
fi

if $INSTALL; then
  rm -rf "/Applications/Magic Commit.app"
  cp -R "$APP" /Applications/
  echo "Installed to /Applications/Magic Commit.app"
fi
