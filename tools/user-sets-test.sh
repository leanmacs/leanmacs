#!/bin/sh
# A user's package set end to end, through the app's launcher
# (`mise run user-sets-test`, part of `ci`; docs/design/packages.md, "User
# package sets"; docs/dev-practices/the-gate.md, "The user sets test").
#
# Run from lean/, after `lean` and `launcher`. Everything it writes is in a
# fresh temporary directory, removed at the end: the config, the state and
# data directories, and HOME and XDG_* point inside it, so a missed flag
# still lands there. The `lean` and `lake` it runs are those of the
# toolchain `lean --print-prefix` names before HOME moves, as elan
# resolves its toolchains under $HOME. The fixture packages (tests/user-sets/<name>) are
# built in place, into their own .lake/, as the fixture set's packages are,
# but hello-init: a copy of it in the temporary directory names the core
# from git, from a `file://` stand-in for the core's repository
# (tools/core-repo.sh), as a published package does.
#
#   A. Install, then drop a default package: three processes of one script
#      (tests/user-sets/install-script), started through the launcher.
#      P1, the shipped default, loads a lakefile that requires the default
#      set and starts no build; the config, which imports `HelloInit`, is
#      refused. It opens a file, types unsaved text, splits the window and
#      opens a tab, then `:package-install hello-init <dir>`, the copy that
#      names the core from git: the install writes the running core's
#      require at the lakefile's root, the set is built against that core,
#      with no core cloned, and the editor restarts into version 1. P2 shows the session
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
#   D. A set that resolves another core: a lakefile written by hand that
#      reaches the core only through the default set, and holds a copy of
#      hello-init naming the core from git (a `file://` stand-in for the
#      core's repository, tools/core-repo.sh), so Lake resolves the core
#      to that clone. The build stops after the resolve, before it links,
#      saying the set resolves editor-core to git and how to fix it; the
#      editor keeps running and nothing is built into the data directory.
#
# It prints `user-sets-test: ok` and the time of each step on success, once
# no process a step started is still running (tools/leftovers.sh); on its
# way out, whatever the outcome, it kills any that is.
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
# `no_leftovers` and `reap` (tools/leftovers.sh): every process a step
# starts names $tmp, and none may outlive this script. A signal ends it
# through the EXIT trap, so an interrupted run reaps too.
. "$repo/tools/leftovers.sh"
trap 'reap "$tmp"; rm -rf "$tmp"' EXIT
trap 'exit 1' HUP INT TERM
# The `lean` and `lake` run from here on are the toolchain's own
# ($sysroot/bin), not whatever the PATH names: elan, CI's toolchain
# manager, resolves its toolchains under $HOME, so once HOME moves its
# proxy installs and runs another copy of the toolchain, and the default
# editor's link trace names the toolchain's directory. Wrappers, not
# symlinks, so Lake still finds its install from the real binary's path;
# only these two, as $sysroot/bin also holds the toolchain's clang.
mkdir "$tmp/toolchain-bin"
for tool in lean lake; do
  printf '#!/bin/sh\nexec "%s/bin/%s" "$@"\n' "$sysroot" "$tool" >"$tmp/toolchain-bin/$tool"
  chmod +x "$tmp/toolchain-bin/$tool"
done
export PATH="$tmp/toolchain-bin:$PATH"
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

# `scrub` and `stable`, shared with tools/bundle-sets.sh
# (tools/user-sets-filters.sh). The output is scrubbed of the temporary
# directory, the repository and the core's identity.
. "$repo/tools/user-sets-filters.sh"
core=$(cat "$shipped.core")
# The scrub takes a path only where it is a whole path, never inside a
# longer name: with the repository at /work, as in the Linux container, the
# default set's packages/workspace stays itself (host-tests-on-fakes phase
# 7, F3, where the lakefile's check read `@REPO@/packages@REPO@space`).
scrubbed=$(printf 'path = "/work/packages/workspace" /work /work/packages/working-set\n' | scrub /work @REPO@)
[ "$scrubbed" = 'path = "@REPO@/packages/workspace" @REPO@ @REPO@/packages/working-set' ] ||
  fail "the scrub took a path inside a longer name: $scrubbed"

# The stand-in for the core's repository (tools/core-repo.sh), and a copy
# of hello-init that names the core from it by git, as a published package
# does: A installs that copy, and D another.
. "$repo/tools/core-repo.sh"
core_repo "$tmp/core-repo" "$lean_dir/lean-toolchain"
git_core_copy "$fixtures/hello-init" "$tmp/hello-init" "$tmp/core-repo"

# A. Install, then drop a default package.
config="$tmp/config"
mkdir -p "$config"
cp "$fixtures/config/init.lean" "$config/init.lean"
cp "$lean_dir/lean-toolchain" "$config/lean-toolchain"
printf 'name = "config"\n\n[[require]]\nname = "default-set"\npath = "%s/packages"\n\n[[lean_lib]]\nname = "Config"\nglobs = ["Config.+"]\n' "$repo" >"$config/lakefile.toml"
printf 'first line\nsecond line\n' >"$tmp/note.txt"
sed "s|@NOTE@|$tmp/note.txt|; s|@HELLO@|$tmp/hello-init|; s|@LINK@|$fixtures/broken-link|" \
  "$fixtures/install-script" >"$tmp/install-script"
started=$(date +%s)
status=0
"$launcher" --data "$tmp/data" --default "$shipped" -- headless --state "$tmp/state" --data "$tmp/data" \
  "$sysroot" "$oleans" "$config" "$tmp/install-script" >"$tmp/install-out" 2>"$tmp/install-err" || status=$?
ended=$(date +%s)
scrub "$tmp" @DIR@ "$repo" @REPO@ "$core" @CORE@ <"$tmp/install-out" >"$tmp/install-scrubbed"
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
scrub "$repo" @REPO@ "$tmp" @DIR@ <"$config/lakefile.toml" | diff "$fixtures/expected-lakefile" - ||
  fail "A's lakefile differs from expected-lakefile"
# The root's core won: no core was cloned, under .lake/packages or anywhere
# else in the set's .lake.
test ! -e "$config/.lake/packages/editor-core" || fail "A cloned a core into $config/.lake/packages/editor-core"
test -z "$(find "$config/.lake" -name EditorCoreStub.lean 2>/dev/null)" ||
  fail "A cloned the stand-in core under $config/.lake"
test "$(ls "$tmp/data/editors" | tr '\n' ' ')" = "$core " || fail "A left $(ls "$tmp/data/editors") in the editors directory"
test "$(ls "$tmp/data/editors/$core" | tr '\n' ' ')" = "1 2 " || fail "A left $(ls "$tmp/data/editors/$core") of its core"
probe=$("$launcher" --data "$tmp/data" --default "$shipped" -- --probe | grep '^executable ')
test "$probe" = "executable $tmp/data/editors/$core/2/editor" || fail "the launcher chose $probe, not version 2"
test ! -e "$tmp/state/session/handover" || fail "A left a hand-over record"
test -z "$(ls -A "$tmp/data/launch" 2>/dev/null)" || fail "A left a cold record"
LEAN_CC=/usr/bin/cc lake -d ../packages build --no-build -q :editor ||
  fail "the user set's builds made the default set's editor out of date"
echo "user-sets-test: A, install hello-init naming the core from git, fail broken-link, drop compile, and no core cloned: ok ($((ended - started)) s)"

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
printf '%s\n' "$out" | scrub "$tmp" @DIR@ "$repo" @REPO@ "$core" @CORE@ | stable | diff "$fixtures/expected-elab" - || fail "B's output differs from expected-elab"
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

# D. A set that resolves another core: the lakefile, written by hand,
# reaches the core only through the default set, and holds a copy of
# hello-init that names the core from git (the stand-in, tools/core-repo.sh),
# so Lake takes the package's git require. The build stops before it links.
git_core_copy "$fixtures/hello-init" "$tmp/hello-init-d" "$tmp/core-repo"
config="$tmp/config-d"
mkdir -p "$config"
cp "$lean_dir/lean-toolchain" "$config/lean-toolchain"
cp "$repo/tests/headless/generate/config/init.lean" "$config/init.lean"
printf 'name = "config"\n\n[[require]]\nname = "default-set"\npath = "%s/packages"\n\n[[require]]\nname = "hello-init"\npath = "%s"\n' \
  "$repo" "$tmp/hello-init-d" >"$config/lakefile.toml"
printf 'reload\nsettle\njoin 600\nsettle\nscene\nrun tab-new\n' >"$tmp/core-script"
started=$(date +%s)
out=$("$shipped" headless --data "$tmp/data-d" "$sysroot" "$oleans" "$config" "$tmp/core-script") ||
  { printf '%s\n' "$out"; fail "D exited non-zero"; }
ended=$(date +%s)
printf '%s\n' "$out" | grep -qF "echo \"packages: the package set resolves editor-core to git file://$tmp/core-repo at " ||
  { printf '%s\n' "$out"; fail "D did not say the set resolves another core"; }
printf '%s\n' "$out" | grep 'Package build of' | grep -q 'Package build failed: the package set resolves editor-core' ||
  fail "D's build buffer does not end failed on the core"
printf '%s\n' "$out" | grep -q '^run tab-new: ok' || fail "D: the editor did not keep running"
test ! -e "$tmp/data-d/editors/$core" || fail "D built into $tmp/data-d/editors/$core"
echo "user-sets-test: D, a set that resolves another core is refused before linking, and the editor keeps running: ok ($((ended - started)) s)"

no_leftovers "$tmp" || fail "an editor, a launcher or a watcher it started is still running"
echo "user-sets-test: ok"
