#!/bin/sh
# The app bundle's layout, staged and run: `mise run bundle-test`, part of
# `ci` (docs/dev-practices/the-gate.md, "The bundle test";
# docs/dev-practices/headless-mode.md, "From an app bundle";
# docs/design/lean-runtime.md, "Build").
#
# Run from lean/, after `lean`. Cargo first builds the app's launcher
# (crates/editor-launch-std, the binary `leanmacs`), release, into target/;
# its own up-to-date check makes that quick once built. Everything else is
# in one temporary directory (its path with its links resolved, as
# CoreFoundation names a bundle), removed by a trap, its read-only bits put
# back first.
#
# 1. **The stage.** `lake -d ../packages query :editorShipped` lists what
#    the bundle ships of the default set, built (lean/lakefile.lean,
#    `editorShipped`), and tools/stage-bundle.sh lays `Leanmacs.app` out
#    from it: the default set's `editor` and the launcher in
#    `Contents/MacOS`, the whole Lean toolchain, the core and the default
#    packages with their sources and build output, the set's lakefile, the
#    Rust archive, on macOS the link stubs, and the records
#    `editor.core`, `editor.oleans` and `editor.build` in
#    `Contents/Resources`.
# 2. **The pieces.** Each tool the toolchain runs a build with is there and
#    executable (`lean`, `lake`, `clang`, `ld64.lld`), with `Init`, `Std`
#    and `Lean`, the static libraries, the Rust archive and its system
#    libraries, the core's and each default package's built modules and the
#    core's glue, the set's lakefile and, on macOS, the link stubs. It
#    prints `bundle-test: the bundle holds lean, lake, clang, ld64.lld,
#    Init, Std, Lean, the static libraries, the Rust archive, the built core
#    and default packages`.
# 3. **The headless runs.** The fixture tests/headless/bundle, whose config
#    imports `Lean` and names a declaration of Lean's elaborator, and three
#    fixtures of the default packages (packages/shipped-themes/tests/
#    headless/shipped-themes and package-names, and packages/compile/tests/
#    headless/config), each copied into the temporary directory and run by
#    the bundle's launcher, `Contents/MacOS/leanmacs`, with no directory
#    argument, an empty environment and a working directory outside the
#    bundle, must each print exactly its `expected`. They pass only if the
#    editor found its modules from its own path, through the bundle's
#    record `editor.oleans` (lean/Editor/ModuleLookup.lean).
# 4. **The generated lakefile.** The bundle's `headless --generate`, on a
#    copy of tests/headless/generate, whose config directory holds
#    `init.lean` alone, must load the config and print exactly its
#    `expected`, write `lakefile.toml` equal to
#    tests/headless/generate/expected-lakefile-bundle with `@SET@` the
#    bundle's `Contents/Resources/lean/set`, and write `lean-toolchain`
#    byte for byte `lean/lean-toolchain`.
# 5. **The version and the identity.** With the fixture's `Info.plist` in
#    `Contents/`, the bundle's `--version` prints exactly
#    tests/headless/bundle/version-expected, and the build tree's editor
#    the line of a development build; the launcher's `--probe` of the
#    bundle's editor, and of a copy outside the bundle given with
#    `--default`, both see the app as their main bundle; and with a
#    per-user editor under the bundle's core in a data directory, the
#    launcher starts that one and leaves no cold record.
#
# It prints a line for each step that passed.
set -eu

lean_dir=$(pwd -P)
repo=$(cd .. && pwd -P)
cargo build --quiet --locked --release --manifest-path ../Cargo.toml -p editor-launch-std --bin leanmacs
sysroot=$(lean --print-prefix)
shipped_editor=$repo/packages/.lake/build/bin/editor

dir=$(mktemp -d)
dir=$(cd "$dir" && pwd -P)
cleanup() {
  chmod -R u+w "$dir" 2>/dev/null || true
  rm -rf "$dir"
}
trap cleanup EXIT

fail() {
  echo "bundle-test: $*" >&2
  exit 1
}

# 1. The stage.
started=$(date +%s)
lake -d ../packages query :editorShipped >"$dir/shipped"
"$repo/tools/stage-bundle.sh" --launcher "$repo/target/release/leanmacs" "$dir/Leanmacs.app" \
  "$shipped_editor" "$sysroot" "$dir/shipped"
app=$dir/Leanmacs.app
launcher=$app/Contents/MacOS/leanmacs
lean=$app/Contents/Resources/lean
echo "bundle-test: staged the bundle ($(($(date +%s) - started)) s)"

# 2. The pieces.
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
echo 'bundle-test: the bundle holds lean, lake, clang, ld64.lld, Init, Std, Lean, the static libraries, the Rust archive, the built core and default packages'

# 3. The headless runs, through the launcher, with an empty environment,
# from a working directory outside the bundle.
mkdir "$dir/elsewhere"
headless() {
  name=$1
  fixture=$2
  config=$3
  cp -R "$fixture/$config" "$dir/$name-config"
  cp "$fixture/script" "$dir/$name-script"
  out=$(cd "$dir/elsewhere" && env -i "$launcher" headless "$dir/$name-config" "$dir/$name-script") ||
    fail "the bundle's headless run of $name exited non-zero"
  printf '%s\n' "$out" | diff "$fixture/expected" - || fail "the bundle's headless run of $name differs from its expected"
}
headless bundle "$repo/tests/headless/bundle" config
headless themes "$repo/packages/shipped-themes/tests/headless/shipped-themes" config
headless names "$repo/packages/shipped-themes/tests/headless/package-names" config
headless compile "$repo/packages/compile/tests/headless/config" config
echo 'bundle-test: the bundle ran its headless fixtures from its own modules, with an empty environment'

# 4. The generated lakefile.
generate=$repo/tests/headless/generate
cp -R "$generate/config" "$dir/generate-config"
cp "$generate/script" "$dir/generate-script"
out=$(cd "$dir/elsewhere" && env -i "$launcher" headless --generate "$dir/generate-config" "$dir/generate-script") ||
  fail "the bundle's headless --generate exited non-zero"
printf '%s\n' "$out" | diff "$generate/expected" - || fail "the bundle's headless --generate differs from its expected"
sed "s|@SET@|$lean/set|" "$generate/expected-lakefile-bundle" | diff - "$dir/generate-config/lakefile.toml" ||
  fail "the bundle generated another lakefile.toml than expected-lakefile-bundle"
cmp -s "$dir/generate-config/lean-toolchain" "$lean_dir/lean-toolchain" ||
  fail "the bundle generated another lean-toolchain than lean/lean-toolchain"
echo "bundle-test: the bundle generated lean-toolchain and a lakefile naming its own set, and the config loaded"

# 5. The version and the identity.
fixtures=$repo/tests/headless/bundle
cp "$fixtures/Info.plist" "$app/Contents/Info.plist"
env -i "$launcher" --version | diff "$fixtures/version-expected" - || fail "the bundle's --version differs"
"$shipped_editor" --version |
  grep -qxF 'Leanmacs, a development build: not run from an app bundle, so it has no version, build ID or commit' ||
  fail "the build tree's editor did not say it is a development build"
if [ "$(uname)" = Darwin ]; then
  seen="bundle $app identifier org.leanmacs.bundle-test"
else
  seen='bundle none'
fi
printf 'probe: ok\nlaunched-by %s\n%s\nexecutable %s\n' "$launcher" "$seen" "$app/Contents/MacOS/editor" >"$dir/probe-expected"
env -i "$launcher" --probe | diff "$dir/probe-expected" - || fail "the launcher's probe of the bundle's editor differs"
mkdir "$dir/outside"
cp "$shipped_editor" "$dir/outside/editor"
printf 'probe: ok\nlaunched-by %s\n%s\nexecutable %s\n' "$launcher" "$seen" "$dir/outside/editor" >"$dir/outside-expected"
env -i "$launcher" --default "$dir/outside/editor" -- --probe | diff "$dir/outside-expected" - ||
  fail "the launcher's probe of an editor outside the bundle differs"
echo 'bundle-test: the editor in the bundle and one outside it, started by the launcher, both see the app as their main bundle'
core=$(cat "$app/Contents/Resources/editor.core")
mkdir -p "$dir/data/editors/$core/1" "$dir/data/editors/other/1" "$dir/data/editors/$core/staging-9"
cp "$shipped_editor" "$dir/data/editors/$core/1/editor"
cp "$shipped_editor" "$dir/data/editors/other/1/editor"
printf 'probe: ok\nlaunched-by %s\n%s\nexecutable %s\n' "$launcher" "$seen" "$dir/data/editors/$core/1/editor" >"$dir/per-user-expected"
env -i "$launcher" --data "$dir/data" --probe | diff "$dir/per-user-expected" - ||
  fail "the launcher did not start the per-user editor of the bundle's core"
test -z "$(ls -A "$dir/data/launch")" || fail "the launcher left a cold record"
echo 'bundle-test: the launcher started the per-user editor of the bundle core, with the app as its main bundle, and left no cold record'

# 6. The first launch: a fresh data directory and a config of `init.lean`
# alone start the shipped default, with no build.
first=$dir/first-config
mkdir "$first"
cp "$generate/config/init.lean" "$first/init.lean"
out=$(cd "$dir/elsewhere" && env -i "$launcher" --data "$dir/first-data" headless --state "$dir/first-state" \
  --data "$dir/first-data" --generate "$first" "$dir/generate-script") || fail "the first launch exited non-zero"
# The state directory's jobs print their own lines; the rest is the
# fixture's.
printf '%s\n' "$out" | grep -v '^job ' | diff "$generate/expected" - ||
  fail "the first launch differs from tests/headless/generate/expected"
! printf '%s\n' "$out" | grep -q 'packages:' || fail "the first launch said something of its packages: $out"
test ! -e "$dir/first-data/editors" || fail "the first launch built an editor"
env -i "$launcher" --data "$dir/first-data" --probe | grep -qxF "executable $app/Contents/MacOS/editor" ||
  fail "after the first launch the launcher does not start the shipped default"
echo 'bundle-test: the first launch, on a config of init.lean alone, started the shipped default and built nothing'

# 7. The unchanged default set, built from the bundle alone (macOS only:
# the app is macOS on arm64 only, and whether the Linux toolchain's clang
# links the Rust archive's system libraries was never measured). The
# bundle's lean/ is made read-only and listed; a config directory holds the
# generated lakefile; the environment is empty but for a PATH whose first
# directory holds decoys of every tool a build could reach for, decoy CC
# and LEAN_SYSROOT, HOME inside the temporary directory and the bundle's
# build record. The bundle's own lake must install an editor whose core is
# the bundle's, which starts, compiling nothing of the bundle (a compile
# would fail writing into the read-only tree, and the listing is compared)
# and running no decoy.
if [ "$(uname)" != Darwin ]; then
  echo 'bundle-test: the build from the bundle alone is macOS only; skipped'
  echo 'bundle-test: ok'
  exit 0
fi
decoys=$dir/decoys
mkdir "$decoys" "$dir/home"
for tool in lean lake clang cc ld xcrun cargo git; do
  printf '#!/bin/sh\necho %s >>"%s"\nexit 1\n' "$tool" "$dir/decoys.log" >"$decoys/$tool"
  chmod +x "$decoys/$tool"
done
: >"$dir/decoys.log"
listing() {
  find "$lean" -print0 | xargs -0 stat -f '%N %z %m' | sort
}
chmod -R a-w "$lean"
listing >"$dir/listing-before"
build=$dir/build-config
mkdir "$build"
cp "$dir/generate-config/init.lean" "$dir/generate-config/lakefile.toml" "$dir/generate-config/lean-toolchain" "$build/"
record=$(cat "$app/Contents/Resources/editor.build")
started=$(date +%s)
# shellcheck disable=SC2086 # the record's lines are NAME=value words
env -i PATH="$decoys:/usr/bin:/bin" HOME="$dir/home" CC="$decoys/cc" LEAN_SYSROOT="$decoys" \
  EDITOR_INSTALL_DIR="$dir/install" $record \
  "$lean/toolchain/bin/lake" -d "$build" build :editorInstall >"$dir/build.log" 2>&1 || {
  cat "$dir/build.log" >&2
  fail "the unchanged default set did not build from the bundle alone"
}
ended=$(date +%s)
listing | diff "$dir/listing-before" - >&2 || fail "the build from the bundle changed the bundle"
test ! -s "$dir/decoys.log" || fail "the build from the bundle ran $(tr '\n' ' ' <"$dir/decoys.log")"
cmp -s "$dir/install/editor.core" "$app/Contents/Resources/editor.core" ||
  fail "the editor built from the bundle has another core than the bundle's"
"$dir/install/editor" --probe | grep -qxF 'probe: ok' || fail "the editor built from the bundle did not start"
echo "bundle-test: the unchanged default set built from the bundle alone, read-only, with decoys first on the PATH, compiled nothing of it, and its editor has the bundle's core ($((ended - started)) s)"

# 8. A package installed from a path and a default package dropped, by the
# bundled editor's own build, from the bundle alone (tools/bundle-sets.sh).
mkdir "$dir/sets"
sh "$repo/tools/bundle-sets.sh" "$app" "$dir/sets" "$repo"

echo 'bundle-test: ok'
