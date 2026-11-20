#!/usr/bin/env bash
# Reads and updates CHANGELOG.md for releases.
#
# Usage:
#   scripts/changelog.sh next patch|minor|major   print the next version after the latest tag
#   scripts/changelog.sh release 1.2.3 [DATE]     move Unreleased entries under ## [1.2.3] - DATE
#   scripts/changelog.sh notes 1.2.3|Unreleased   print the entries of one section
set -euo pipefail
cd "$(dirname "$0")/.."

CHANGELOG=CHANGELOG.md
REPO_URL="https://github.com/dommangetnicolas/magic-commit"

usage() { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

# Prints the body of a "## [name]" section, without leading/trailing blank lines.
notes() {
  awk -v name="$1" '
    /^## \[/ { insec = (index($0, "## [" name "]") == 1); next }
    /^\[[^]]+\]: / { insec = 0 }
    insec { lines[n++] = $0 }
    END {
      s = 0; while (s < n && lines[s] ~ /^[[:space:]]*$/) s++
      e = n - 1; while (e >= s && lines[e] ~ /^[[:space:]]*$/) e--
      for (i = s; i <= e; i++) print lines[i]
    }
  ' "$CHANGELOG"
}

case "${1:-}" in
  next)
    bump="${2:-}"
    latest="$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || echo v0.0.0)"
    IFS=. read -r major minor patch <<<"${latest#v}"
    case "$bump" in
      major) echo "$((major + 1)).0.0" ;;
      minor) echo "$major.$((minor + 1)).0" ;;
      patch) echo "$major.$minor.$((patch + 1))" ;;
      *) usage ;;
    esac
    ;;

  notes)
    [[ -n "${2:-}" ]] || usage
    notes "$2"
    ;;

  release)
    version="${2:-}"
    date="${3:-$(date +%Y-%m-%d)}"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid version: $version" >&2; exit 1; }
    if grep -q "^## \[$version\]" "$CHANGELOG"; then
      echo "$CHANGELOG already has a $version section" >&2; exit 1
    fi
    if [[ -z "$(notes Unreleased)" ]]; then
      echo "Nothing under Unreleased in $CHANGELOG" >&2; exit 1
    fi
    previous="$(grep -m1 -oE '^\[Unreleased\]: .*/compare/v[0-9.]+\.\.\.HEAD' "$CHANGELOG" \
      | sed -E 's#.*/compare/(v[0-9.]+)\.\.\.HEAD#\1#')"
    [[ -n "$previous" ]] || { echo "Could not find the [Unreleased] comparison link" >&2; exit 1; }

    tmp="$(mktemp)"
    awk -v v="$version" -v d="$date" -v prev="$previous" -v url="$REPO_URL" '
      /^## \[Unreleased\]/ { print; print ""; print "## [" v "] - " d; next }
      /^\[Unreleased\]: / {
        print "[Unreleased]: " url "/compare/v" v "...HEAD"
        print "[" v "]: " url "/compare/" prev "...v" v
        next
      }
      { print }
    ' "$CHANGELOG" >"$tmp"
    mv "$tmp" "$CHANGELOG"
    echo "Released $version ($date) in $CHANGELOG"
    ;;

  *) usage ;;
esac
