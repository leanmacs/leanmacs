#!/usr/bin/env bash
# Install the built app: `mise run install`
# (docs/dev-practices/on-demand-checks.md, "Installing the app").
#
# `mise run app-check` runs first (the task depends on it), so the bundle is
# built and checked. This script then:
#
# 1. refuses unless this is macOS on arm64, as the bundle is;
# 2. replaces `$apps/Leanmacs.app` with the built bundle (`ditto`) and
#    verifies the installed copy with `codesign --verify --strict --deep`.
#    `$apps` is `/Applications`, or `$LEANMACS_APPLICATIONS` (for testing on
#    a scratch prefix only);
# 3. installs the default config `config/default`, a starter `SPC` map, its
#    root `init.lean` and the files under `Config/`, to
#    `$HOME/.config/leanmacs` only when that directory does not exist; when
#    it does, it only says where the default config is, so an existing
#    config is never touched;
# 4. deletes the `Leanmacs.app.backup-*` and `leanmacs.backup-*` directories
#    the earlier install script left beside them.
#
# It keeps no backups: the app is rebuilt from any commit with `mise run app`.
# It uses no `sudo`, and opens, registers or runs nothing.
#
# `$1` is the default package set's directory, `packages/`, whose build
# directory holds the bundle.
set -euo pipefail

if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
  echo "install: the app bundle is macOS on arm64 only (this is $(uname -s) $(uname -m))" >&2
  exit 2
fi

set_dir=$(cd "$1" && pwd)
repo=$(cd "$set_dir/.." && pwd)
built="$set_dir/.lake/build/Leanmacs.app"
apps=${LEANMACS_APPLICATIONS:-/Applications}
app="$apps/Leanmacs.app"
cfg="$HOME/.config/leanmacs"
default="$repo/config/default"

if [ ! -d "$built" ]; then
  echo "install: no bundle at $built: run \`mise run app\`" >&2
  exit 1
fi

rm -rf "$app"
ditto "$built" "$app"
codesign --verify --strict --deep "$app"
echo "install: installed $app ($(git -C "$repo" describe --always --dirty)), signature verified"

if [ ! -e "$cfg" ]; then
  mkdir -p "$cfg"
  # The whole tree: the root, `init.lean`, and the files under `Config/`.
  cp -R "$default"/. "$cfg/"
  echo "install: no config found; installed the default config in $cfg (SPC f f finds a file)"
else
  echo "install: kept the config in $cfg as it is; the default config is in $default"
fi

for old in "$apps"/Leanmacs.app.backup-* "$cfg".backup-*; do
  [ -e "$old" ] || continue
  rm -rf "$old"
  echo "install: removed $old"
done
