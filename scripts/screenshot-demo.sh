#!/usr/bin/env bash
# Sets up demo git repositories in every state Magic Commit can show, and points
# the app at them so the landing page screenshots can be taken. Your own project
# list is backed up first and put back with `restore`.
#
#   ./scripts/screenshot-demo.sh setup     # build demo repos, back up and swap the project list
#   ./scripts/screenshot-demo.sh restore   # put your project list back
#   ./scripts/screenshot-demo.sh clean     # restore, then delete the demo repos
set -euo pipefail

DEMO_DIR="${DEMO_DIR:-$HOME/MagicCommitDemo}"
REMOTES="$DEMO_DIR/.remotes"
BACKUP="$DEMO_DIR/.projects-backup.plist"
DOMAIN="local.magic-commit"
APP="/Applications/Magic Commit.app"

say() { printf '\033[1;35m›\033[0m %s\n' "$*"; }

quit_app() {
  osascript -e 'tell application id "local.magic-commit" to quit' >/dev/null 2>&1 || true
  pkill -x MagicCommit 2>/dev/null || true
  sleep 1
}

launch_app() { open "$APP"; }

# --- repo helpers -----------------------------------------------------------

new_repo() { # name branch
  local name=$1 branch=$2 dir="$DEMO_DIR/$1"
  git init -q --bare -b "$branch" "$REMOTES/$name.git"
  git init -q -b "$branch" "$dir"
  git -C "$dir" config user.name "Demo"
  git -C "$dir" config user.email "demo@example.com"
  git -C "$dir" config commit.gpgsign false
  git -C "$dir" remote add origin "$REMOTES/$name.git"
}

write() { # repo path content
  mkdir -p "$(dirname "$DEMO_DIR/$1/$2")"
  printf '%s\n' "$3" > "$DEMO_DIR/$1/$2"
}

commit() { # repo message
  git -C "$DEMO_DIR/$1" add -A
  git -C "$DEMO_DIR/$1" commit -q -m "$2"
}

publish() { # repo
  git -C "$DEMO_DIR/$1" push -q -u origin HEAD 2>/dev/null
}

base_project() { # repo title
  write "$1" README.md "# $2"
  write "$1" .gitignore "node_modules/"
  commit "$1" "Initial commit"
  write "$1" src/index.ts "export const app = \"$2\";"
  commit "$1" "Add entry point"
  publish "$1"
}

# --- demo states ------------------------------------------------------------

build_repos() {
  # Uncommitted changes, WIP commits and unpushed work: every action at once.
  new_repo aurora-web main
  base_project aurora-web "Aurora"
  write aurora-web src/theme.ts "export const accent = '#6d4aff';"; commit aurora-web "WIP"
  write aurora-web src/nav.tsx "export function Nav() { return null; }"; commit aurora-web "WIP"
  write aurora-web src/footer.tsx "export function Footer() { return null; }"; commit aurora-web "wip footer"
  write aurora-web src/hero.tsx "export function Hero() { return null; }"
  write aurora-web src/pricing.tsx "export function Pricing() { return null; }"
  write aurora-web src/index.ts "export const app = 'Aurora'; export const version = 2;"

  # Feature branch with WIP commits mixed with a real one: Batch oco + Push warning.
  new_repo pocket-api main
  base_project pocket-api "Pocket API"
  git -C "$DEMO_DIR/pocket-api" checkout -q -b feature/oauth-login
  publish pocket-api
  write pocket-api src/auth/oauth.ts "export const providers = ['github', 'google'];"; commit pocket-api "WIP"
  write pocket-api src/auth/session.ts "export const ttl = 3600;"; commit pocket-api "Add session expiry setting"
  write pocket-api src/auth/callback.ts "export function callback() {}"; commit pocket-api "WIP"
  write pocket-api src/auth/tokens.ts "export function refresh() {}"; commit pocket-api "WIP"

  # Only uncommitted changes: Commit and WIP.
  new_repo design-tokens main
  base_project design-tokens "Design Tokens"
  write design-tokens tokens/color.json '{ "accent": "#6d4aff", "surface": "#ffffff" }'
  write design-tokens tokens/spacing.json '{ "sm": 8, "md": 16, "lg": 24 }'
  write design-tokens src/index.ts "export * from './tokens';"

  # Clean, real commits waiting to be pushed: Push only.
  new_repo ios-companion main
  base_project ios-companion "iOS Companion"
  write ios-companion Sources/Widget.swift "struct Widget {}"; commit ios-companion "Add home screen widget"
  write ios-companion Sources/Settings.swift "struct Settings {}"; commit ios-companion "Move settings to a sheet"

  # Behind its upstream.
  new_repo infra main
  base_project infra "Infra"
  git clone -q "$REMOTES/infra.git" "$DEMO_DIR/.infra-teammate"
  git -C "$DEMO_DIR/.infra-teammate" -c user.name=Teammate -c user.email=t@example.com \
    commit -q --allow-empty -m "Bump Terraform to 1.9"
  git -C "$DEMO_DIR/.infra-teammate" -c user.name=Teammate -c user.email=t@example.com \
    commit -q --allow-empty -m "Add staging database"
  git -C "$DEMO_DIR/.infra-teammate" push -q
  rm -rf "$DEMO_DIR/.infra-teammate"
  git -C "$DEMO_DIR/infra" fetch -q

  # All committed and pushed.
  new_repo docs-site main
  base_project docs-site "Docs"
}

# --- project list swap ------------------------------------------------------

swap_projects() {
  if [[ ! -f "$BACKUP" ]]; then
    if defaults read "$DOMAIN" projects >/dev/null 2>&1; then
      defaults export "$DOMAIN" "$BACKUP"
    else
      echo "none" > "$BACKUP"
    fi
    say "Backed up your project list to $BACKUP"
  fi
  local json="[" sep="" name
  for name in aurora-web pocket-api design-tokens ios-companion infra docs-site; do
    json+="$sep{\"id\":\"$(uuidgen)\",\"path\":\"$DEMO_DIR/$name\"}"
    sep=","
  done
  json+="]"
  defaults write "$DOMAIN" projects -data "$(printf '%s' "$json" | xxd -p | tr -d '\n')"
}

restore_projects() {
  if [[ ! -f "$BACKUP" ]]; then
    say "No backup found, nothing to restore."
    return
  fi
  if [[ "$(cat "$BACKUP")" == "none" ]]; then
    defaults delete "$DOMAIN" projects 2>/dev/null || true
  else
    defaults import "$DOMAIN" "$BACKUP"
  fi
  rm -f "$BACKUP"
  say "Restored your project list."
}

# --- commands ---------------------------------------------------------------

case "${1:-}" in
  setup)
    if [[ -e "$DEMO_DIR" && ! -d "$DEMO_DIR/aurora-web" ]]; then
      echo "$DEMO_DIR exists but isn't a demo folder. Set DEMO_DIR to another path." >&2; exit 1
    fi
    quit_app
    if [[ ! -d "$DEMO_DIR/aurora-web" ]]; then
      mkdir -p "$REMOTES"
      build_repos
      say "Created demo repos in $DEMO_DIR"
    fi
    swap_projects
    launch_app
    say "Magic Commit now shows the demo projects. Run '$0 restore' when you're done."
    ;;
  restore)
    quit_app
    restore_projects
    launch_app
    ;;
  clean)
    quit_app
    restore_projects
    rm -rf "$DEMO_DIR"
    say "Deleted $DEMO_DIR"
    launch_app
    ;;
  *)
    sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
