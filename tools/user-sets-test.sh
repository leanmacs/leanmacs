#!/bin/sh
# A user's package set end to end, through the app's launcher
# (`mise run user-sets-test`, part of `ci`; docs/design/packages.md, "User
# package sets"; docs/dev-practices/the-gate.md, "The user sets test").
#
# Run from lean/, after `lean` and `launcher`. Everything it writes is in a
# fresh temporary directory, removed at the end: the config, the state and
# data directories, and HOME and XDG_* point inside it, so a missed flag
# still lands there. The fixture packages (tests/user-sets/<name>) are
# built in place, into their own .lake/, as the fixture set's packages are.
#
#   A. Install, then drop a default package: three processes of one script
#      (tests/user-sets/install-script), started through the launcher.
#      P1, the shipped default, loads a lakefile that requires the default
#      set and starts no build; the config, which imports `HelloInit`, is
#      refused. It opens a file, types unsaved text, splits the window and
#      opens a tab, then `:package-install hello-init <dir>`: the set is
#      built and the editor restarts into version 1. P2 shows the session
#      as it was, runs `hello-init` (`hello-init: initialize ran`), installs
#      `broken-link`, whose link fails, keeps running, removes it (no
#      build), then removes `compile`, a default package: version 2. P3
#      answers `run compile: no such command` and still runs `hello-init`.
#   B. A set that fails to elaborate (`broken-elab`), on the shipped default
#      with no state directory: the buffer ends failed with the
#      elaborator's error, the editor keeps running, and nothing is
#      published.
#   C. Git missing, through the launcher: a lakefile naming a git
#      dependency, with no git on the PATH, says git is required and how to
#      get it, and fetches and builds nothing.
#
# It prints `user-sets-test: ok` and the time of each step on success.
set -eu

lean_dir=$(pwd -P)
repo=$(cd .. && pwd -P)
sysroot=$(lean --print-prefix)
oleans=$lean_dir/.lake/build/lib/lean
shipped=$repo/packages/.lake/build/bin/editor
launcher=$repo/target/release/leanmacs
fixtures=$repo/tests/user-sets

tmp=$(mktemp -d)
tmp=$(cd "$tmp" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home" XDG_DATA_HOME="$tmp/xdg-data" XDG_STATE_HOME="$tmp/xdg-state" XDG_CONFIG_HOME="$tmp/xdg-config"
mkdir -p "$HOME"

fail() {
  echo "user-sets-test: $*" >&2
  exit 1
}

# The fixture packages, resolved in place: their manifests are committed,
# so this builds nothing and fetches nothing.
for package in hello-init broken-link broken-elab; do
  test -f "$fixtures/$package/lake-manifest.json" || fail "$package has no lake-manifest.json"
done

# Substitutes the temporary directory, the repository, the shipped editor
# and the core's identity in the output on stdin.
core=$(cat "$shipped.core")
scrub() {
  sed "s|$tmp|@DIR@|g; s|$repo|@REPO@|g; s|$core|@CORE@|g"
}

# The lines of the output on stdin that are stable from run to run: job
# lines go, and so does every line of the build buffer's views, which hold
# Lake's own output and the build's time; those are checked apart. A
# scene's count of publishes is written @N@: each delivery of Lake's output
# is a post, and how Lake's lines fall into deliveries varies.
stable() {
  { grep -v '^job ' | grep -v 'Package build of' | grep -v '\*package-build\*' || true; } |
    sed 's/, published [0-9]*,/, published @N@,/'
}

# A. Install, then drop a default package.
config="$tmp/config"
mkdir -p "$config"
cp "$fixtures/config/init.lean" "$config/init.lean"
cp "$lean_dir/lean-toolchain" "$config/lean-toolchain"
printf 'name = "config"\n\n[[require]]\nname = "default-set"\npath = "%s/packages"\n\n[[lean_lib]]\nname = "Config"\nglobs = ["Config.+"]\n' "$repo" >"$config/lakefile.toml"
printf 'first line\nsecond line\n' >"$tmp/note.txt"
sed "s|@NOTE@|$tmp/note.txt|; s|@HELLO@|$fixtures/hello-init|; s|@LINK@|$fixtures/broken-link|" \
  "$fixtures/install-script" >"$tmp/install-script"
started=$(date +%s)
status=0
"$launcher" --data "$tmp/data" --default "$shipped" -- headless --state "$tmp/state" --data "$tmp/data" \
  "$sysroot" "$oleans" "$config" "$tmp/install-script" >"$tmp/install-out" 2>"$tmp/install-err" || status=$?
ended=$(date +%s)
scrub <"$tmp/install-out" >"$tmp/install-scrubbed"
if [ "$status" -ne 0 ]; then
  cat "$tmp/install-scrubbed" "$tmp/install-err" >&2
  fail "A exited $status"
fi
stable <"$tmp/install-scrubbed" | diff "$fixtures/expected-install" - || fail "A's output differs from expected-install"
grep 'Package build of' "$tmp/install-scrubbed" >"$tmp/install-buffer" || true
grep -q 'Package build failed: lake build exited with status 1' "$tmp/install-buffer" ||
  fail "A's build buffer does not end the broken-link build failed"
grep -q 'leanmacs_no_such_symbol' "$tmp/install-buffer" ||
  fail "A's build buffer does not show the linker's error, naming leanmacs_no_such_symbol"
sed "s|$repo|@REPO@|g" "$config/lakefile.toml" | diff "$fixtures/expected-lakefile" - ||
  fail "A's lakefile differs from expected-lakefile"
test "$(ls "$tmp/data/editors" | tr '\n' ' ')" = "$core " || fail "A left $(ls "$tmp/data/editors") in the editors directory"
test "$(ls "$tmp/data/editors/$core" | tr '\n' ' ')" = "1 2 " || fail "A left $(ls "$tmp/data/editors/$core") of its core"
probe=$("$launcher" --data "$tmp/data" --default "$shipped" -- --probe | grep '^executable ')
test "$probe" = "executable $tmp/data/editors/$core/2/editor" || fail "the launcher chose $probe, not version 2"
test ! -e "$tmp/state/session/handover" || fail "A left a hand-over record"
test -z "$(ls -A "$tmp/data/launch" 2>/dev/null)" || fail "A left a cold record"
LEAN_CC=/usr/bin/cc lake -d ../packages build --no-build -q :editor ||
  fail "the user set's builds made the default set's editor out of date"
echo "user-sets-test: A, install hello-init, fail broken-link, drop compile: ok ($((ended - started)) s)"

# B. A set that does not elaborate.
config="$tmp/config-b"
mkdir -p "$config"
cp "$lean_dir/lean-toolchain" "$config/lean-toolchain"
printf 'name = "config"\n\n[[require]]\nname = "default-set"\npath = "%s/packages"\n' "$repo" >"$config/lakefile.toml"
sed "s|@ELAB@|$fixtures/broken-elab|" "$fixtures/elab-script" >"$tmp/elab-script"
started=$(date +%s)
out=$("$shipped" headless --data "$tmp/data-b" "$sysroot" "$oleans" "$config" "$tmp/elab-script") ||
  fail "B exited non-zero"
ended=$(date +%s)
printf '%s\n' "$out" | scrub | stable | diff "$fixtures/expected-elab" - || fail "B's output differs from expected-elab"
printf '%s\n' "$out" | grep 'Package build of' | grep -q 'Package build failed: lake build exited with status 1' ||
  fail "B's build buffer does not end failed"
printf '%s\n' "$out" | grep 'Package build of' | grep -q 'Type mismatch' ||
  fail "B's build buffer does not show the elaborator's error"
test -z "$(ls "$tmp/data-b/editors" 2>/dev/null)" || fail "B left $(ls "$tmp/data-b/editors")"
echo "user-sets-test: B, broken-elab fails and the editor keeps running: ok ($((ended - started)) s)"

# C. Git missing, through the launcher.
mkdir -p "$tmp/empty"
f=$fixtures/git-missing
out=$(PATH="$tmp/empty" "$launcher" --data "$tmp/data-c" --default "$shipped" -- headless --data "$tmp/data-c" \
  "$sysroot" "$oleans" "$f/config" "$f/script") || fail "C exited non-zero"
printf '%s\n' "$out" | grep -q 'packages: git is required to fetch x, and none works here' ||
  fail "C did not say git is required"
test ! -e "$tmp/data-c" || fail "C wrote into its data directory"
echo "user-sets-test: C, git missing is said and nothing is fetched: ok"

echo "user-sets-test: ok"
