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
# 2. **The pieces** (tools/bundle-sets.sh `pieces`): each tool a build
#    runs, `Init`, `Std` and `Lean`, the static libraries, the Rust archive,
#    the built core and default packages, the link stubs and the records.
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
#    tests/headless/generate/expected-lakefile-bundle with `@CORE@` the
#    bundle's `Contents/Resources/lean/lean` and `@SET@` its
#    `Contents/Resources/lean/set`, and write `lean-toolchain`
#    byte for byte `lean/lean-toolchain`.
# 5. **The version and the identity.** With the fixture's `Info.plist` in
#    `Contents/`, the bundle's `--version` prints exactly
#    tests/headless/bundle/version-expected, and the build tree's editor
#    the line of a development build; the launcher's `--probe` of the
#    bundle's editor, and of a copy outside the bundle given with
#    `--default`, both see the app as their main bundle; and with a
#    per-user editor under the bundle's core in a data directory, the
#    launcher starts that one and leaves no cold record.
# 6. **The first launch** (tools/bundle-sets.sh `first-launch`): a fresh
#    data directory and a config of `init.lean` alone start the shipped
#    default and build nothing.
# 7. to 9. **From the bundle alone**, macOS only (tools/bundle-sets.sh
#    `default-set`, `sets` and `c-glue`), with the bundle's `lean/`
#    read-only and decoys of every tool first on the PATH: the unchanged
#    default set built by the bundle's `lake`, compiling nothing of it; a
#    package installed from a path and a default package dropped by the
#    bundled editor's own build; and a package with C, compiled by the
#    bundled `clang`.
#
# It prints a line for each step that passed, and `bundle-test: ok` once no
# process a step started is still running (tools/leftovers.sh); on its way
# out, whatever the outcome, it kills any that is, before it removes its
# temporary directory.
set -eu

lean_dir=$(pwd -P)
repo=$(cd .. && pwd -P)
cargo build --quiet --locked --release --manifest-path ../Cargo.toml -p editor-launch-std --bin leanmacs
sysroot=$(lean --print-prefix)
shipped_editor=$repo/packages/.lake/build/bin/editor

dir=$(mktemp -d)
dir=$(cd "$dir" && pwd -P)
# `no_leftovers` and `reap` (tools/leftovers.sh): every process the steps
# start names $dir, and none may outlive this script.
. "$repo/tools/leftovers.sh"
cleanup() {
  reap "$dir"
  chmod -R u+w "$dir" 2>/dev/null || true
  rm -rf "$dir"
}
trap cleanup EXIT
# A signal ends the script through the EXIT trap, so an interrupted run
# reaps too.
trap 'exit 1' HUP INT TERM

fail() {
  echo "bundle-test: $*" >&2
  exit 1
}

# Passes, once nothing a step started is still running.
passed() {
  no_leftovers "$dir" || fail "an editor, a launcher or a watcher it started is still running"
  echo 'bundle-test: ok'
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

# 2. The pieces (tools/bundle-sets.sh).
mkdir "$dir/pieces"
sh "$repo/tools/bundle-sets.sh" pieces "$app" "$dir/pieces" "$repo"

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
sed "s|@SET@|$lean/set|; s|@CORE@|$lean/lean|" "$generate/expected-lakefile-bundle" | diff - "$dir/generate-config/lakefile.toml" ||
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
# alone start the shipped default, with no build (tools/bundle-sets.sh).
mkdir "$dir/first"
sh "$repo/tools/bundle-sets.sh" first-launch "$app" "$dir/first" "$repo"

# 7 to 9, from the bundle alone, with its lean/ read-only and decoys of
# every tool first on the PATH (tools/bundle-sets.sh): the unchanged default
# set built by the bundle's lake; a package installed from a path and a
# default package dropped, by the bundled editor's own build; and a package
# with C, compiled by the bundled clang. macOS only: the app is macOS on
# arm64 only, and whether the Linux toolchain's clang links the Rust
# archive's system libraries was never measured.
if [ "$(uname)" != Darwin ]; then
  echo 'bundle-test: the builds from the bundle alone are macOS only; skipped'
  passed
  exit 0
fi
chmod -R a-w "$lean"
for check in default-set sets c-glue; do
  mkdir "$dir/$check"
  sh "$repo/tools/bundle-sets.sh" "$check" "$app" "$dir/$check" "$repo"
done

passed
