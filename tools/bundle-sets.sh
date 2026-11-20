#!/bin/sh
# What a bundle must hold and do for a user's package set to build from it
# alone, checked on a staged bundle by `mise run bundle-test`
# (tools/bundle-test.sh) and on a copy of the built app by `mise run
# app-check` (tools/app-check.sh) (docs/design/packages.md, "User package
# sets"; docs/design/lean-runtime.md, "The app ships the toolchain").
#
#   tools/bundle-sets.sh <check> <bundle> <work dir> <repository>
#
# `<work dir>` is an empty directory of the caller's, removed by it; HOME
# points inside it. Each check prints one line when it passes, and one that
# starts an editor passes only once nothing it started is still running
# (tools/leftovers.sh).
#
# - `pieces`: `lean`, `lake`, `clang` and `ld64.lld` are in the bundle's
#   toolchain and executable, with `Init`, `Std`, `Lean` and `Lake`,
#   `lean.h`, the static libraries, the Rust archive and its system
#   libraries, the core's and each default package's built modules, the
#   core's glue, the set's lakefile, on macOS the link stubs, and the
#   records `editor.core`, `editor.oleans` and `editor.build`, the last
#   without `LEAN_CC`.
# - `first-launch`: with a fresh data directory, a state directory and a
#   config of `init.lean` alone (tests/headless/generate), the bundle's
#   editor, through its launcher, prints exactly the fixture's `expected`
#   (but its state jobs' lines), generates the lakefile naming the bundle's
#   set (tests/headless/generate/expected-lakefile-bundle) and
#   `lean-toolchain`, says nothing of its packages and builds nothing (no
#   `<data>/editors`); the launcher's probe then names the bundle's
#   `Contents/MacOS/editor`.
#
# The checks below are macOS only, and need the bundle's
# `Contents/Resources/lean` read-only already (`chmod -R a-w`): each lists
# it before and after (path, size, modification time) and requires the
# listings to be equal, so no build wrote into it. Each runs with an empty
# environment but for a PATH whose first directory holds decoys of `lean`,
# `lake`, `clang`, `cc`, `ld`, `xcrun`, `cargo` and `git` that log their
# name and exit 1, decoy `CC` and `LEAN_SYSROOT` and `HOME` in the work
# directory, and requires no decoy to have run.
#
# - `default-set`: the bundle's own `lake -d <config> build :editorInstall`
#   on a config whose lakefile is the generated one, the unchanged default
#   set, with the bundle's `editor.build` set, exits 0, compiles nothing of
#   the bundle (a compile would fail writing into the read-only tree) and
#   installs an editor whose `editor.core` is the bundle's and whose
#   `--probe` prints `probe: ok`.
# - `sets`: the user's package set built by the editor's own job, with a
#   decoy `LEAN_CC` too, which the job clears. The fixture package
#   `hello-init` (tests/user-sets/hello-init) is copied into the work
#   directory, its `.lake/` left behind, with its `editor-core` require
#   pointed at the bundle's core, `Contents/Resources/lean/lean`, in its
#   lakefile and its manifest, so the set resolves one core, the bundle's.
#   P0, a first launch, generates the lakefile; then `init.lean` is
#   replaced by one that imports `HelloInit` (a reload refused at its
#   imports generates nothing, so the import comes after, as a user's
#   would). Three processes of tests/user-sets/bundle-script run through the
#   launcher: P1 refuses the config, and `:package-install hello-init
#   <copy>` builds the set and restarts into version 1; P2 installs the
#   config, runs `hello-init` (`hello-init: initialize ran`), and
#   `:package-remove compile`, a default package, builds version 2; P3
#   answers `run compile: no such command` and still runs `hello-init`. The
#   output, with the work directory, the bundle and the core's identity
#   written `@DIR@`, `@APP@` and `@CORE@` and the lines that vary from run
#   to run left out (`scrub` and `stable`, tools/user-sets-filters.sh), must
#   equal tests/user-sets/expected-bundle; versions 1 and 2 of the bundle's
#   core, and nothing else, are published; and the launcher's probe names
#   version 2.
# - `c-glue`: the C FFI, the way a package brings native code (decided
#   2026-11-20): on a generated config, `:package-install c-glue <copy>`
#   of tests/user-sets/c-glue, its require pointed at the bundle's core,
#   builds its C with the bundled `clang` and the toolchain's `lean.h` and
#   restarts into version 1, whose `run c-glue` says `c-glue: 42`, the
#   answer of its C function.
set -eu

check=$1
app=$2
work=$3
repo=$4
lean=$app/Contents/Resources/lean
launcher=$app/Contents/MacOS/leanmacs
fixtures=$repo/tests/user-sets
generate=$repo/tests/headless/generate

fail() {
  echo "bundle-sets: $*" >&2
  exit 1
}

# `no_leftovers` (tools/leftovers.sh): every process a check starts names
# the work directory, and each check that starts one passes only once none
# is still running. The caller, which owns the directory, reaps on its way
# out.
. "$repo/tools/leftovers.sh"
settled() {
  no_leftovers "$work" || fail "$check: an editor, a launcher or a watcher it started is still running"
}

# Generates the config directory `$1` on a first launch with the data
# directory `$2`, from tests/headless/generate's `init.lean`, and requires
# the generated lakefile to name the bundle's set. The environment is `$3`
# words more (the decoys' PATH and HOME, where the caller has them).
generated() {
  mkdir -p "$1"
  cp "$generate/config/init.lean" "$1/init.lean"
  # shellcheck disable=SC2086 # the environment's words
  (cd / && env -i $3 "$launcher" --data "$2" headless --data "$2" --generate "$1" "$generate/script") \
    >"$1.first" 2>&1 || {
    cat "$1.first" >&2
    fail "the first launch on $1 exited non-zero"
  }
  sed "s|@SET@|$lean/set|" "$generate/expected-lakefile-bundle" | diff - "$1/lakefile.toml" ||
    fail "the first launch generated another lakefile than expected-lakefile-bundle"
  cmp -s "$1/lean-toolchain" "$repo/lean/lean-toolchain" ||
    fail "the first launch generated another lean-toolchain than lean/lean-toolchain"
}

case "$check" in
pieces)
  for tool in lean lake clang ld64.lld; do
    test -f "$lean/toolchain/bin/$tool" && test -x "$lean/toolchain/bin/$tool" ||
      fail "the bundle has no executable $tool in its toolchain"
  done
  for path in \
    toolchain/lib/lean/Init.olean toolchain/lib/lean/Std.olean toolchain/lib/lean/Lean.olean \
    toolchain/lib/lean/Lake.olean toolchain/include/lean/lean.h \
    toolchain/lib/lean/libInit.a toolchain/lib/lean/libStd.a toolchain/lib/lean/libLean.a \
    toolchain/lib/lean/libleanrt.a toolchain/lib/lean/libleancpp.a \
    toolchain/lib/libgmp.a toolchain/lib/libuv.a \
    target/release/libeditor_rust.a target/editor-rust/core/native-static-libs \
    lean/lakefile.lean lean/lean-toolchain lean/lake-manifest.json \
    lean/.lake/build/lib/lean/Editor.olean lean/.lake/build/lib/lean/Editor.trace \
    lean/.lake/build/ir/Editor.c.o.export lean/.lake/build/ffi/glue.o \
    set/lakefile.toml set/lake-manifest.json set/lean-toolchain \
    set/shipped-themes/lakefile.toml set/shipped-themes/.lake/build/lib/lean/ShippedThemes/EditorPackage.olean \
    set/compile/lakefile.toml set/compile/.lake/build/lib/lean/Compile/EditorPackage.olean; do
    test -f "$lean/$path" || fail "the bundle has no Contents/Resources/lean/$path"
  done
  if [ "$(uname)" = Darwin ]; then
    test -f "$lean/link-stubs/platform-version" || fail "the bundle has no link stubs"
  fi
  for record in editor.core editor.oleans editor.build; do
    test -f "$app/Contents/Resources/$record" || fail "the bundle has no Contents/Resources/$record"
  done
  ! grep -q '^LEAN_CC=' "$app/Contents/Resources/editor.build" ||
    fail "the bundle's editor.build sets LEAN_CC, so its builds would not use the bundled clang"
  echo 'bundle-sets: the bundle holds lean, lake, clang, ld64.lld, Init, Std, Lean, the static libraries, the Rust archive, the built core and default packages'
  exit 0
  ;;
first-launch)
  config=$work/config
  mkdir "$config"
  cp "$generate/config/init.lean" "$config/init.lean"
  out=$(cd / && env -i "$launcher" --data "$work/data" headless --state "$work/state" --data "$work/data" \
    --generate "$config" "$generate/script") || fail "the first launch exited non-zero"
  # The state directory's jobs print their own lines; the rest is the
  # fixture's.
  printf '%s\n' "$out" | grep -v '^job ' | diff "$generate/expected" - ||
    fail "the first launch differs from tests/headless/generate/expected"
  ! printf '%s\n' "$out" | grep -q 'packages:' || fail "the first launch said something of its packages: $out"
  sed "s|@SET@|$lean/set|" "$generate/expected-lakefile-bundle" | diff - "$config/lakefile.toml" ||
    fail "the first launch generated another lakefile than expected-lakefile-bundle"
  cmp -s "$config/lean-toolchain" "$repo/lean/lean-toolchain" ||
    fail "the first launch generated another lean-toolchain than lean/lean-toolchain"
  test ! -e "$work/data/editors" || fail "the first launch built an editor"
  env -i "$launcher" --data "$work/data" --probe | grep -qxF "executable $app/Contents/MacOS/editor" ||
    fail "after the first launch the launcher does not start the shipped default"
  settled
  echo 'bundle-sets: the first launch, on a config of init.lean alone, generated the lakefile naming the bundle'"'"'s set, started the shipped default and built nothing'
  exit 0
  ;;
default-set | sets | c-glue) ;;
*) fail "no check $check: pieces, first-launch, default-set, sets or c-glue" ;;
esac

[ "$(uname)" = Darwin ] || fail "$check is macOS only"
test ! -w "$lean" || fail "the bundle's Contents/Resources/lean is writable: make it read-only first"

listing() {
  find "$lean" -print0 | xargs -0 stat -f '%N %z %m' | sort
}
listing >"$work/listing-before"

decoys=$work/decoys
mkdir -p "$decoys" "$work/home"
: >"$work/decoys.log"
for tool in lean lake clang cc ld xcrun cargo git; do
  printf '#!/bin/sh\necho %s >>"%s"\nexit 1\n' "$tool" "$work/decoys.log" >"$decoys/$tool"
  chmod +x "$decoys/$tool"
done
quiet="PATH=$decoys:/usr/bin:/bin HOME=$work/home"

# Whether no decoy ran and the bundle is as it was.
untouched() {
  test ! -s "$work/decoys.log" || fail "$check ran $(tr '\n' ' ' <"$work/decoys.log")"
  listing | diff "$work/listing-before" - >&2 || fail "$check wrote into the bundle"
}

core=$(cat "$app/Contents/Resources/editor.core")

if [ "$check" = default-set ]; then
  generated "$work/config" "$work/data" "$quiet"
  record=$(cat "$app/Contents/Resources/editor.build")
  started=$(date +%s)
  # shellcheck disable=SC2086 # the record's lines are NAME=value words
  env -i PATH="$decoys:/usr/bin:/bin" HOME="$work/home" CC="$decoys/cc" LEAN_SYSROOT="$decoys" \
    EDITOR_INSTALL_DIR="$work/install" $record \
    "$lean/toolchain/bin/lake" -d "$work/config" build :editorInstall >"$work/build.log" 2>&1 || {
    cat "$work/build.log" >&2
    fail "the unchanged default set did not build from the bundle alone"
  }
  ended=$(date +%s)
  untouched
  cmp -s "$work/install/editor.core" "$app/Contents/Resources/editor.core" ||
    fail "the editor built from the bundle has another core than the bundle's"
  "$work/install/editor" --probe | grep -qxF 'probe: ok' || fail "the editor built from the bundle did not start"
  settled
  echo "bundle-sets: the unchanged default set built from the bundle alone, read-only, with decoys first on the PATH, compiled nothing of it, and its editor has the bundle's core ($((ended - started)) s)"
  exit 0
fi

if [ "$check" = c-glue ]; then
  glue=$work/c-glue
  cp -R "$fixtures/c-glue" "$glue"
  rm -rf "$glue/.lake"
  sed "s|^require «editor-core» from \".*|require «editor-core» from \"$lean/lean\"|" "$fixtures/c-glue/lakefile.lean" >"$glue/lakefile.lean"
  sed "s|\"dir\": \"../../../lean\"|\"dir\": \"$lean/lean\"|" "$fixtures/c-glue/lake-manifest.json" >"$glue/lake-manifest.json"
  grep -qF "$lean/lean" "$glue/lakefile.lean" && grep -qF "$lean/lean" "$glue/lake-manifest.json" ||
    fail "could not point c-glue's editor-core require at the bundle's core"
  generated "$work/config" "$work/data" "$quiet"
  printf 'reload\nsettle\nkey : Semicolon shift\ncommit package-install c-glue %s\nkey <Enter> Enter -\nrestarted 300\n\nsettle\nreload\nsettle\nrun c-glue\nscene\n' \
    "$glue" >"$work/script"
  started=$(date +%s)
  out=$(cd / && env -i PATH="$decoys:/usr/bin:/bin" HOME="$work/home" LEAN_CC="$decoys/cc" CC="$decoys/cc" \
    LEAN_SYSROOT="$decoys" "$launcher" --data "$work/data" headless --state "$work/state" --data "$work/data" \
    "$work/config" "$work/script" 2>"$work/err") || {
    printf '%s\n' "$out" | tail -20 >&2
    cat "$work/err" >&2
    fail "the bundle's editor exited non-zero installing c-glue"
  }
  ended=$(date +%s)
  printf '%s\n' "$out" | grep -q 'echo "c-glue: 42"' || {
    printf '%s\n' "$out" | tail -20 >&2
    fail "c-glue's command did not answer 42 from its C function"
  }
  test "$(ls "$work/data/editors/$core" | tr '\n' ' ')" = "1 " || fail "c-glue's build did not publish version 1"
  untouched
  settled
  echo "bundle-sets: installed c-glue, whose C the bundled clang compiled, into the bundled editor, and its command answered from its C function ($((ended - started)) s)"
  exit 0
fi

hello=$work/hello-init
cp -R "$fixtures/hello-init" "$hello"
rm -rf "$hello/.lake"
sed "s|^path = \"../../../lean\"|path = \"$lean/lean\"|" "$fixtures/hello-init/lakefile.toml" >"$hello/lakefile.toml"
sed "s|\"dir\": \"../../../lean\"|\"dir\": \"$lean/lean\"|" "$fixtures/hello-init/lake-manifest.json" >"$hello/lake-manifest.json"
grep -qF "$lean/lean" "$hello/lakefile.toml" && grep -qF "$lean/lean" "$hello/lake-manifest.json" ||
  fail "could not point hello-init's editor-core require at the bundle's core"

# P0, the first launch: the lakefile is generated, naming the bundle's set.
# A reload refused at its imports generates nothing (docs/design/packages.md,
# "A config directory requires the set"), so the import of `HelloInit` is
# written after, as a user would.
config=$work/config
generated "$config" "$work/data" "$quiet"
cp "$fixtures/config/init.lean" "$config/init.lean"
sed "s|@HELLO@|$hello|" "$fixtures/bundle-script" >"$work/script"

# `scrub` and `stable`, shared with tools/user-sets-test.sh.
. "$repo/tools/user-sets-filters.sh"

started=$(date +%s)
status=0
(cd / && env -i PATH="$decoys:/usr/bin:/bin" HOME="$work/home" LEAN_CC="$decoys/cc" CC="$decoys/cc" \
  LEAN_SYSROOT="$decoys" "$launcher" --data "$work/data" headless --state "$work/state" --data "$work/data" \
  "$config" "$work/script") >"$work/out" 2>"$work/err" || status=$?
ended=$(date +%s)
scrub "$work" @DIR@ "$app" @APP@ "$core" @CORE@ <"$work/out" >"$work/scrubbed"
if [ "$status" -ne 0 ]; then
  cat "$work/scrubbed" "$work/err" >&2
  fail "the bundle's editor exited $status"
fi
stable <"$work/scrubbed" | diff "$fixtures/expected-bundle" - || {
  grep 'Package build of' "$work/scrubbed" | tail -40 >&2
  fail "the output differs from tests/user-sets/expected-bundle"
}
test "$(ls "$work/data/editors" | tr '\n' ' ')" = "$core " || fail "the builds left $(ls "$work/data/editors") in the editors directory"
test "$(ls "$work/data/editors/$core" | tr '\n' ' ')" = "1 2 " ||
  fail "the builds did not publish versions 1 and 2 of the bundle's core: $(ls "$work/data/editors/$core")"
untouched
probe=$(env -i "$launcher" --data "$work/data" --probe | grep '^executable ')
test "$probe" = "executable $work/data/editors/$core/2/editor" || fail "the launcher chose $probe, not version 2"
settled
echo "bundle-sets: installed hello-init from a path into the bundled editor and ran its command, dropped compile and started the result, from the bundle's own toolchain, read-only, with decoys first on the PATH ($((ended - started)) s)"
