#!/usr/bin/env bash
# Install the built app: `mise run install`
# (docs/dev-practices/on-demand-checks.md, "Installing the app").
#
# `mise run app` runs first (the task depends on it), so the bundle is
# built. This script then:
#
# 1. refuses unless this is macOS on arm64, as the bundle is;
# 2. with `--agents`, before anything is replaced, builds acp's library
#    from this checkout with the developer's Cargo (`cargo build --release
#    --locked --lib -p acp-service`, the same command as the `.cargo` form
#    of acp's `editorLibrary` target, packages/acp/lakefile.lean) and places
#    it in the package's `lib/` (gitignored): copied beside it and renamed
#    over it, so the file is a new one, as the core's `stageLibrary` makes
#    it. No Cargo, or a failed build, exits 1 with nothing changed;
# 3. replaces `$apps/Leanmacs.app` with the built bundle (`ditto`) and
#    verifies the installed copy with `codesign --verify --strict --deep`.
#    `$apps` is `/Applications`, or `$LEANMACS_APPLICATIONS` (for testing on
#    a scratch prefix only);
# 4. installs the default config `config/default`, a starter `SPC` map, its
#    root `init.lean` and the files under `Config/`, to `$cfg`,
#    `$HOME/.config/leanmacs` or `$LEANMACS_CONFIG_DIR` (for testing on a
#    scratch prefix only), only when that directory does not exist; when
#    it does, it only says where the default config is, so an existing
#    config is never touched;
# 5. with `--agents`, adds the opt-in agent packages, `agents-api` and
#    `acp`, by this checkout's paths, to the config's `lakefile.toml`, just
#    ahead of its `editor-core` require, skipping any already there. With no
#    lakefile it writes the one the editor would generate
#    (`lean/Editor/Config/LakePackage.lean`) with the two added, and the
#    editor still writes `lean-toolchain` itself. A `lakefile.lean` is
#    refused, as the editor's package commands refuse to edit one.
#    `default-set` and `editor-core` stay at the bundle, since the installed
#    app refuses any other core. The editor's next `:reload` builds the set
#    with acp's library from its `lib/` and runs no Cargo (acp's
#    `editorLibrary` takes the library already built for a set outside the
#    repository). After updating the checkout, run the install again, so
#    the core, acp's Lean, read from the checkout at `:reload`, and its
#    library agree (docs/packages/installing-packages.md);
# 6. deletes the `Leanmacs.app.backup-*` and `leanmacs.backup-*` directories
#    the earlier install script left beside them.
#
# It keeps no backups: the app is rebuilt from any commit with `mise run app`.
# It uses no `sudo`, and opens, registers or runs nothing.
#
# `$1` is the default package set's directory, `packages/`, whose build
# directory holds the bundle; `--agents` may follow it
# (`mise run install -- --agents`).
set -euo pipefail

agents=false
for arg in "${@:2}"; do
  case "$arg" in
    --agents) agents=true ;;
    *)
      echo "install: unknown argument $arg (the one flag is --agents)" >&2
      exit 2
      ;;
  esac
done

if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
  echo "install: the app bundle is macOS on arm64 only (this is $(uname -s) $(uname -m))" >&2
  exit 2
fi

set_dir=$(cd "$1" && pwd)
repo=$(cd "$set_dir/.." && pwd)
built="$set_dir/.lake/build/Leanmacs.app"
apps=${LEANMACS_APPLICATIONS:-/Applications}
app="$apps/Leanmacs.app"
cfg=${LEANMACS_CONFIG_DIR:-$HOME/.config/leanmacs}
default="$repo/config/default"

if [ ! -d "$built" ]; then
  echo "install: no bundle at $built: run \`mise run app\`" >&2
  exit 1
fi

if $agents; then
  if ! command -v cargo >/dev/null 2>&1; then
    echo "install: --agents builds acp's library with Cargo, which is not on PATH: install it with rustup (https://rustup.rs)" >&2
    exit 1
  fi
  # The same command as the `.cargo` form of acp's `editorLibrary` target
  # (packages/acp/lakefile.lean).
  cargo build --release --locked --lib -p acp-service --manifest-path "$repo/Cargo.toml" --target-dir "$repo/target"
  lib="$repo/packages/acp/lib"
  mkdir -p "$lib"
  cp "$repo/target/release/libacp_service.dylib" "$lib/libacp_service.dylib.new"
  mv "$lib/libacp_service.dylib.new" "$lib/libacp_service.dylib"
  echo "install: built acp's library from this checkout into $lib"
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

if $agents; then
  lakefile="$cfg/lakefile.toml"
  if [ -e "$cfg/lakefile.lean" ]; then
    echo "install: $cfg/lakefile.lean is a program and is never edited; require agents-api and acp from $repo/packages in it by hand" >&2
    exit 1
  fi
  if [ ! -e "$lakefile" ]; then
    # The lakefile the editor generates for the app's set and core.
    cat >"$lakefile" <<EOF
name = "config"

[[require]]
name = "default-set"
path = "$app/Contents/Resources/lean/set"

[[require]]
name = "editor-core"
path = "$app/Contents/Resources/lean/lean"

[[lean_lib]]
name = "Config"
globs = ["Config.+"]
EOF
    echo "install: wrote $lakefile, the lakefile the editor would generate"
  fi
  for pkg in agents-api acp; do
    if grep -Eq "^name *= *\"$pkg\"" "$lakefile"; then
      echo "install: $lakefile already requires $pkg"
      continue
    fi
    table=$(printf '[[require]]\nname = "%s"\npath = "%s"\n' "$pkg" "$repo/packages/$pkg")
    # Ahead of the `[[require]]` table naming editor-core, which stays last;
    # appended when there is none.
    TABLE="$table" awk '
      { lines[NR] = $0 }
      /^name *= *"editor-core"/ && lines[NR-1] ~ /^\[\[require\]\]/ { core = NR - 1 }
      END {
        for (i = 1; i <= NR; i++) {
          if (i == core) print ENVIRON["TABLE"] "\n"
          print lines[i]
        }
        if (!core) print "\n" ENVIRON["TABLE"]
      }' "$lakefile" >"$lakefile.new"
    mv "$lakefile.new" "$lakefile"
    echo "install: $lakefile now requires $pkg from $repo/packages/$pkg"
  done
  echo "install: :reload in the editor builds the set with acp's library, built now from this checkout, and runs no Cargo; after updating the checkout, run \`mise run install -- --agents\` again"
fi

for old in "$apps"/Leanmacs.app.backup-* "$cfg".backup-*; do
  [ -e "$old" ] || continue
  rm -rf "$old"
  echo "install: removed $old"
done
