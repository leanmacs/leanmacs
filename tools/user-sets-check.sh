#!/bin/sh
# The user package sets checks that stay off the gate
# (`mise run user-sets-check`; docs/dev-practices/on-demand-checks.md, "User
# package sets, on demand"; docs/design/packages.md, "User package sets").
# Run from lean/, after `lean` and `launcher`, on a machine with git and
# Cargo. Everything it writes is in a fresh temporary directory, removed at
# the end, with HOME and XDG_* inside it (Cargo's and rustup's homes are
# kept, so G builds offline from the registry cache), but the fixture
# packages' own .lake/ and, for G, the checkout's target/, which every Rust
# build of a set shares.
#
#   E. The first launch after an editor update: a version 1 is built; a copy
#      of the shipped default whose `editor.core` is another core is
#      started by the launcher in its place, builds the set and restarts
#      into the new version. With a lakefile naming `broken-elab`, the copy
#      keeps running and the buffer shows Lean's error.
#   F. Git update: a package in a local git repository (`file://`), which
#      names the core from git (a `file://` stand-in, tools/core-repo.sh),
#      is installed and pinned; after a new commit, `:package-update x`
#      moves the pin and builds; `:package-update x <old rev>` writes the
#      rev into the lakefile and builds. The lakefile then requires the
#      running core at its root, as its last require, and no core is
#      cloned.
#   G. Rust: a set holding the fixture package `echo`, whose crate the
#      editor's Cargo workspace holds, builds with Cargo, and the new
#      editor passes its probe.
#   H. A probe failure: `init-throws` links, its `initialize` throws, the
#      probe fails, nothing is published, and the editor keeps running.
#
# It ends `user-sets-check: ok`, with the time of each step, once no
# process a step started is still running (tools/leftovers.sh); on its way
# out, whatever the outcome, it kills any that is.
set -eu

lean_dir=$(pwd -P)
repo=$(cd .. && pwd -P)
sysroot=$(lean --print-prefix)
oleans=$lean_dir/.lake/build/lib/lean
shipped=$repo/packages/.lake/build/bin/editor
launcher=$repo/target/release/leanmacs
fixtures=$repo/tests/user-sets
core=$(cat "$shipped.core")

tmp=$(mktemp -d)
tmp=$(cd "$tmp" && pwd -P)
# `no_leftovers` and `reap` (tools/leftovers.sh): every process a step
# starts names $tmp, and none may outlive this script. A signal ends it
# through the EXIT trap, so an interrupted run reaps too.
. "$repo/tools/leftovers.sh"
trap 'reap "$tmp"; rm -rf "$tmp"' EXIT
trap 'exit 1' HUP INT TERM
export CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}" RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup}"
export HOME="$tmp/home" XDG_DATA_HOME="$tmp/xdg-data" XDG_STATE_HOME="$tmp/xdg-state" XDG_CONFIG_HOME="$tmp/xdg-config"
mkdir -p "$HOME"

fail() {
  echo "user-sets-check: $*" >&2
  exit 1
}

# A config directory at $1 whose lakefile requires the default set, then
# the lines given as $2 (more TOML), with the pin.
config_at() {
  mkdir -p "$1"
  cp "$lean_dir/lean-toolchain" "$1/lean-toolchain"
  printf 'name = "config"\n\n[[require]]\nname = "default-set"\npath = "%s/packages"\n%s' "$repo" "${2:-}" >"$1/lakefile.toml"
}

# A script at $1 that types each of the ex lines after it, each followed by
# the waits a package-set build needs with no state directory.
script_at() {
  out=$1
  shift
  printf 'reload\nsettle\n' >"$out"
  for line in "$@"; do
    printf 'key : Semicolon shift\ncommit %s\nkey <Enter> Enter -\njoin 600\nsettle\njoin 600\nscene\n' "$line" >>"$out"
  done
}

# E. The first launch after an editor update.
started=$(date +%s)
config_at "$tmp/e/config"
script_at "$tmp/e/install" "package-install hello-init $fixtures/hello-init"
out=$("$shipped" headless --data "$tmp/e/data" "$sysroot" "$oleans" "$tmp/e/config" "$tmp/e/install")
printf '%s\n' "$out" | grep -q "packages: built $tmp/e/data/editors/$core/1/editor; it starts at the next launch" ||
  { printf '%s\n' "$out"; fail "E did not build version 1"; }
mkdir "$tmp/e/shipped"
for file in "" .oleans .set .build .coredir; do
  cp "$shipped$file" "$tmp/e/shipped/editor$file"
done
echo 0000000000000000 >"$tmp/e/shipped/editor.core"
probe=$("$launcher" --data "$tmp/e/data" --default "$tmp/e/shipped/editor" -- --probe | grep '^executable ')
test "$probe" = "executable $tmp/e/shipped/editor" ||
  fail "E: after the update the launcher started $probe, not the shipped default"
cat >"$tmp/e/update" <<'EOF'
reload
settle
restarted 600

settle
reload
settle
indexed
run hello-init
scene
EOF
cp "$fixtures/config/init.lean" "$tmp/e/config/init.lean"
out=$("$launcher" --data "$tmp/e/data" --default "$tmp/e/shipped/editor" -- headless --state "$tmp/e/state" \
  --data "$tmp/e/data" "$sysroot" "$oleans" "$tmp/e/config" "$tmp/e/update")
printf '%s\n' "$out" | grep -q 'echo "hello-init: initialize ran"' ||
  { printf '%s\n' "$out"; fail "E: the copy did not build the set and restart into it"; }
test -x "$tmp/e/data/editors/$core/2/editor" || fail "E published no version 2"
config_at "$tmp/e/broken" "
[[require]]
name = \"broken-elab\"
path = \"$fixtures/broken-elab\"
"
printf 'reload\nsettle\njoin 600\nsettle\njoin 600\nscene\nrun tab-new\n' >"$tmp/e/broken-script"
out=$("$launcher" --data "$tmp/e/data-broken" --default "$tmp/e/shipped/editor" -- headless \
  --data "$tmp/e/data-broken" "$sysroot" "$oleans" "$tmp/e/broken" "$tmp/e/broken-script")
printf '%s\n' "$out" | grep -q 'packages: lake build exited with status 1; this editor keeps running' ||
  { printf '%s\n' "$out"; fail "E: the failed build was not said"; }
printf '%s\n' "$out" | grep 'Package build of' | grep -q 'Type mismatch' || fail "E: the buffer does not show Lean's error"
printf '%s\n' "$out" | grep -q '^run tab-new: ok' || fail "E: the copy did not keep running"
ended=$(date +%s)
echo "user-sets-check: E, the first launch after an update rebuilds, and a failure keeps the shipped default: ok ($((ended - started)) s)"

# F. Git update. The package names the core from git, from a `file://`
# stand-in for the core's repository (tools/core-repo.sh), as a published
# package does; the config's lakefile requires the running core at its
# root, which wins.
started=$(date +%s)
. "$repo/tools/core-repo.sh"
core_repo "$tmp/f/core-repo" "$lean_dir/lean-toolchain"
mkdir -p "$tmp/f/repo/GitPackage"
(
  cd "$tmp/f/repo"
  cp "$lean_dir/lean-toolchain" lean-toolchain
  printf 'name = "git-package"\n\n[[require]]\nname = "editor-core"\ngit = "file://%s"\nsubDir = "lean"\nrev = "%s"\n\n[[lean_lib]]\nname = "GitPackage"\n' \
    "$tmp/f/core-repo" "$core_repo_tag" >lakefile.toml
  write_version() {
    printf 'import Editor.Api\nimport Editor.Package\n\nnamespace GitPackage\n\n/-- The package. -/\ndef package : Editor.Package :=\n  { name := "git-package", setup := Editor.command "git-package" (Editor.message "git-package %s") }\n\nend GitPackage\n' "$1" >GitPackage.lean
  }
  printf 'import GitPackage\n\nnamespace GitPackage.EditorPackage\n\n/-- The packages. -/\ndef packages : Array Editor.Package :=\n  #[GitPackage.package]\n\nend GitPackage.EditorPackage\n' >GitPackage/EditorPackage.lean
  write_version v1
  git init -q
  git add -A
  git -c user.name=check -c user.email=check@example.invalid commit -qm v1
)
first=$(git -C "$tmp/f/repo" rev-parse HEAD)
config_at "$tmp/f/config"
script_at "$tmp/f/install" "package-install git-package file://$tmp/f/repo"
"$shipped" headless --data "$tmp/f/data" "$sysroot" "$oleans" "$tmp/f/config" "$tmp/f/install" >"$tmp/f/out1" ||
  { cat "$tmp/f/out1"; fail "F: the install failed"; }
grep -qxF "pin git-package file://$tmp/f/repo $first" "$tmp/f/data/editors/$core/1/editor.packages" ||
  { cat "$tmp/f/out1"; fail "F: version 1 does not record the pin $first"; }
(
  cd "$tmp/f/repo"
  sed -i.old 's/git-package v1/git-package v2/' GitPackage.lean
  rm GitPackage.lean.old
  git -c user.name=check -c user.email=check@example.invalid commit -qam v2
)
second=$(git -C "$tmp/f/repo" rev-parse HEAD)
# Each later step runs on the version the one before built, whose
# fingerprint is the config's, so its start-up reload builds nothing.
script_at "$tmp/f/update" "package-update git-package"
"$tmp/f/data/editors/$core/1/editor" headless --data "$tmp/f/data" "$sysroot" "$oleans" "$tmp/f/config" "$tmp/f/update" >"$tmp/f/out2" ||
  { cat "$tmp/f/out2"; fail "F: the update failed"; }
grep -qxF "pin git-package file://$tmp/f/repo $second" "$tmp/f/data/editors/$core/2/editor.packages" ||
  { cat "$tmp/f/out2"; fail "F: version 2 does not record the new pin $second"; }
script_at "$tmp/f/back" "package-update git-package $first"
"$tmp/f/data/editors/$core/2/editor" headless --data "$tmp/f/data" "$sysroot" "$oleans" "$tmp/f/config" "$tmp/f/back" >"$tmp/f/out3" ||
  { cat "$tmp/f/out3"; fail "F: the update to a rev failed"; }
grep -qxF "rev = \"$first\"" "$tmp/f/config/lakefile.toml" || fail "F: the rev was not written into the lakefile"
# Each edit wrote the running core's require at the root, as its last.
last_table=$(awk '/^\[\[require\]\]/ { getline name; getline path; last = name "\n" path } END { print last }' "$tmp/f/config/lakefile.toml")
test "$last_table" = "name = \"editor-core\"
path = \"$lean_dir\"" || { cat "$tmp/f/config/lakefile.toml"; fail "F: the lakefile's last require is not the running core at $lean_dir"; }
test ! -e "$tmp/f/config/.lake/packages/editor-core" || fail "F cloned a core into the set's .lake/packages"
grep -qxF "pin git-package file://$tmp/f/repo $first" "$tmp/f/data/editors/$core/3/editor.packages" ||
  { cat "$tmp/f/out3"; fail "F: version 3 does not record the pin $first"; }
ended=$(date +%s)
echo "user-sets-check: F, install from git a package naming the core from git, update, and update to a rev, the core required at the root: ok ($((ended - started)) s)"

# G. Rust: a set holding `echo`, built with Cargo.
started=$(date +%s)
config_at "$tmp/g/config"
script_at "$tmp/g/install" "package-install echo $repo/tests/packages/echo"
"$shipped" headless --data "$tmp/g/data" "$sysroot" "$oleans" "$tmp/g/config" "$tmp/g/install" >"$tmp/g/out" ||
  { cat "$tmp/g/out"; fail "G: the install failed"; }
grep -q "packages: built $tmp/g/data/editors/$core/1/editor" "$tmp/g/out" ||
  { cat "$tmp/g/out"; fail "G: the set with echo's crate was not built"; }
"$tmp/g/data/editors/$core/1/editor" --probe | head -1 | grep -qx 'probe: ok' || fail "G: the new editor did not pass its probe"
ended=$(date +%s)
echo "user-sets-check: G, a set with a Rust crate builds with Cargo: ok ($((ended - started)) s)"

# H. A probe failure.
started=$(date +%s)
config_at "$tmp/h/config"
script_at "$tmp/h/install" "package-install init-throws $fixtures/init-throws"
printf 'run tab-new\n' >>"$tmp/h/install"
"$shipped" headless --data "$tmp/h/data" "$sysroot" "$oleans" "$tmp/h/config" "$tmp/h/install" >"$tmp/h/out" ||
  { cat "$tmp/h/out"; fail "H: the editor did not keep running"; }
grep -q 'packages: the new editor did not start: ' "$tmp/h/out" || { cat "$tmp/h/out"; fail "H: the probe failure was not said"; }
grep -q '^run tab-new: ok' "$tmp/h/out" || fail "H: the editor did not keep running"
test -z "$(ls "$tmp/h/data/editors")" || fail "H published $(ls "$tmp/h/data/editors")"
ended=$(date +%s)
echo "user-sets-check: H, a probe failure publishes nothing: ok ($((ended - started)) s)"

no_leftovers "$tmp" || fail "an editor, a launcher or a watcher it started is still running"
echo "user-sets-check: ok"
