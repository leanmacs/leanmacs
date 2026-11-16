#!/usr/bin/env bash
# The owner's Finder session, prepared: `mise run finder-session-prepare`
# (docs/dev-practices/finder-session.md, docs/dev-practices/
# on-demand-checks.md, "The Finder session, by hand").
#
# `mise run app-check` runs first (the task depends on it), so the bundle is
# built and checked. This script then:
#
# 1. refuses unless this is macOS on arm64, as the bundle is;
# 2. refuses a checkout with uncommitted changes (`git status
#    --porcelain`), unless `PREPARE_ALLOW_DIRTY=1`, and prints the commit;
# 3. refuses if `lean/.lake/build/Leanmacs.app` is missing;
# 4. moves any existing `$apps/Leanmacs.app` aside to
#    `$apps/Leanmacs.app.backup-<ts>`, a name that does not end in `.app`, so
#    LaunchServices takes it for no second Leanmacs; then copies the built
#    bundle there with `ditto` and verifies the installed copy with
#    `codesign --verify --strict --deep`. `$apps` is `/Applications`, or
#    `$LEANMACS_APPLICATIONS` (for testing on a scratch prefix only);
# 5. moves any existing config directory aside to `<dir>.backup-<ts>` and
#    installs the fixture `tests/headless/finder-session/config` in its
#    place, `$HOME/.config/leanmacs`. It refuses when this shell's
#    `XDG_CONFIG_HOME` is set, not empty and not `$HOME/.config`: the app
#    opened from Finder gets launchd's environment, not this shell's, and
#    would not see it;
# 6. prints what it did and the commands that undo it.
#
# It removes nothing, uses no `sudo`, and opens, registers or runs nothing:
# it calls only `git`, `date`, `mv`, `mkdir`, `cp`, `ditto` and `codesign
# --verify`. A backup name that exists already is refused, never replaced.
#
# `$1` is the Lean package's directory.
set -euo pipefail

if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
  echo "finder-session-prepare: the app bundle is macOS on arm64 only (this is $(uname -s) $(uname -m))" >&2
  exit 2
fi

fail() {
  echo "finder-session-prepare: $*" >&2
  exit 1
}

lean_dir=$(cd "$1" && pwd)
repo=$(cd "$lean_dir/.." && pwd)
fixture="$repo/tests/headless/finder-session/config"
built="$lean_dir/.lake/build/Leanmacs.app"

if [ -n "$(git -C "$repo" status --porcelain)" ] && [ "${PREPARE_ALLOW_DIRTY:-}" != 1 ]; then
  fail "the checkout has uncommitted changes: commit them first (git status)"
fi
echo "finder-session-prepare: commit $(git -C "$repo" rev-parse HEAD)"

[ -d "$built" ] || fail "no bundle at $built: run \`mise run app\`"

ts=$(date +%Y%m%d-%H%M%S)
apps=${LEANMACS_APPLICATIONS:-/Applications}
# An app opened from Finder gets launchd's environment, not this shell's, so
# it reads `$HOME/.config/leanmacs` even when this shell exports another
# `XDG_CONFIG_HOME`: installing there would put the config where the app
# never looks.
if [ -n "${XDG_CONFIG_HOME:-}" ] && [ "$XDG_CONFIG_HOME" != "$HOME/.config" ]; then
  fail "XDG_CONFIG_HOME is $XDG_CONFIG_HOME in this shell, but the app opened from Finder gets launchd's environment and will not see it: it reads $HOME/.config/leanmacs. Run \`unset XDG_CONFIG_HOME\`, or \`launchctl setenv XDG_CONFIG_HOME $XDG_CONFIG_HOME\` so the app sees it too, then run this again"
fi
cfg="$HOME/.config/leanmacs"
app="$apps/Leanmacs.app"
app_backup="$app.backup-$ts"
cfg_backup="$cfg.backup-$ts"

if [ -e "$app_backup" ] || [ -L "$app_backup" ]; then
  fail "$app_backup exists already: try again in a second"
fi
if [ -e "$cfg_backup" ] || [ -L "$cfg_backup" ]; then
  fail "$cfg_backup exists already: try again in a second"
fi

app_moved=0
if [ -e "$app" ] || [ -L "$app" ]; then
  mv "$app" "$app_backup"
  app_moved=1
  echo "finder-session-prepare: moved $app to $app_backup"
else
  echo "finder-session-prepare: no $app, nothing to back up"
fi
ditto "$built" "$app"
codesign --verify --strict --deep "$app"
echo "finder-session-prepare: installed $app, signature verified"

cfg_moved=0
if [ -e "$cfg" ] || [ -L "$cfg" ]; then
  mv "$cfg" "$cfg_backup"
  cfg_moved=1
  echo "finder-session-prepare: moved $cfg to $cfg_backup"
else
  echo "finder-session-prepare: no $cfg, nothing to back up"
fi
mkdir -p "$cfg"
cp "$fixture"/*.lean "$cfg/"
echo "finder-session-prepare: installed the config fixture in $cfg"

echo "finder-session-prepare: timestamp $ts"
echo "finder-session-prepare: to restore, quit Leanmacs, then:"
echo "  mv '$app' '$app.finder-session-$ts'"
if [ "$app_moved" = 1 ]; then
  echo "  mv '$app_backup' '$app'"
fi
echo "  mv '$cfg' '$cfg.finder-session-$ts'"
if [ "$cfg_moved" = 1 ]; then
  echo "  mv '$cfg_backup' '$cfg'"
fi
echo "finder-session-prepare: nothing is deleted; remove the set-aside copies by hand"
echo "finder-session-prepare: now follow docs/dev-practices/finder-session.md"
