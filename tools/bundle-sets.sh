#!/bin/sh
# A user's package set built by a bundled editor from its own toolchain:
# run by `mise run bundle-test` (tools/bundle-test.sh) on a staged bundle
# and by `mise run app-check` (tools/app-check.sh) on a copy of the built
# app (docs/design/packages.md, "User package sets";
# docs/design/lean-runtime.md, "The app ships the toolchain"). macOS only.
#
#   tools/bundle-sets.sh <bundle> <work dir> <repository>
#
# `<work dir>` is an empty directory of the caller's, removed by it; HOME
# points inside it. The bundle's `Contents/Resources/lean` must already be
# read-only (`chmod -R a-w`): this lists it before and after and requires
# the listings to be equal, so no build wrote into it.
#
# The fixture package `hello-init` (tests/user-sets/hello-init) is copied
# into the work directory, its `.lake/` left behind, with its
# `editor-core` require pointed at the bundle's core,
# `Contents/Resources/lean/lean`, in its lakefile and its manifest, so the
# set resolves one core, the bundle's. Three processes of
# tests/user-sets/bundle-script run through the bundle's launcher, with an
# empty environment but for a PATH whose first directory holds decoys of
# `lean`, `lake`, `clang`, `cc`, `ld`, `xcrun`, `cargo` and `git` that log
# their name and exit 1, and decoy `LEAN_CC`, `CC` and `LEAN_SYSROOT`: the
# build job must clear those and run the bundle's own `lake`, which finds
# `lean` and `clang` beside itself.
#
# - P0, a first launch on a config of `init.lean` alone, which loads,
#   generates the lakefile naming the bundle's set
#   (tests/headless/generate/expected-lakefile-bundle). Then `init.lean`
#   is replaced by one that imports `HelloInit`: a reload refused at its
#   imports generates nothing, so the import comes after, as a user's would.
# - P1, the shipped default, refuses that config, and
#   `:package-install hello-init <copy>` builds the set from the bundle,
#   which reload refuses again saying the set needs a rebuild, and
#   restarts into version 1.
# - P2 installs the config, runs `hello-init` (`hello-init: initialize
#   ran`), and `:package-remove compile`, a default package, builds
#   version 2.
# - P3 answers `run compile: no such command` and still runs `hello-init`.
#
# Then the output, with the work directory, the bundle and the core's
# identity written `@DIR@`, `@APP@` and `@CORE@` and the lines that vary
# from run to run left out (tools/user-sets-test.sh's `scrub` and
# `stable`), must equal tests/user-sets/expected-bundle; both builds
# published, as versions 1 and 2 of the bundle's core, and nothing else
# is in the data directory's editors; no decoy ran; the bundle's
# listing is unchanged; and the launcher's probe names version 2.
#
# It prints one line, with the time the three processes took.
set -eu

app=$1
work=$2
repo=$3
lean=$app/Contents/Resources/lean
launcher=$app/Contents/MacOS/leanmacs
fixtures=$repo/tests/user-sets

fail() {
  echo "bundle-sets: $*" >&2
  exit 1
}

[ "$(uname)" = Darwin ] || fail "macOS only"

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

hello=$work/hello-init
cp -R "$fixtures/hello-init" "$hello"
rm -rf "$hello/.lake"
sed "s|^path = \"../../../lean\"|path = \"$lean/lean\"|" "$fixtures/hello-init/lakefile.toml" >"$hello/lakefile.toml"
sed "s|\"dir\": \"../../../lean\"|\"dir\": \"$lean/lean\"|" "$fixtures/hello-init/lake-manifest.json" >"$hello/lake-manifest.json"
grep -qF "$lean/lean" "$hello/lakefile.toml" && grep -qF "$lean/lean" "$hello/lake-manifest.json" ||
  fail "could not point hello-init's editor-core require at the bundle's core"

# P0, the first launch: on a config of `init.lean` alone, which loads, the
# shipped default generates the lakefile, naming the bundle's set. A reload
# refused at its imports generates nothing (docs/design/packages.md, "A
# config directory requires the set"), so the import of `HelloInit` is
# written after, as a user would.
config=$work/config
mkdir "$config"
cp "$repo/tests/headless/generate/config/init.lean" "$config/init.lean"
(cd / && env -i PATH="$decoys:/usr/bin:/bin" HOME="$work/home" "$launcher" --data "$work/data" headless \
  --data "$work/data" --generate "$config" "$repo/tests/headless/generate/script") >"$work/first" 2>&1 ||
  { cat "$work/first" >&2; fail "the first launch exited non-zero"; }
sed "s|@SET@|$lean/set|" "$repo/tests/headless/generate/expected-lakefile-bundle" | diff - "$config/lakefile.toml" ||
  fail "the first launch generated another lakefile than expected-lakefile-bundle"
cp "$fixtures/config/init.lean" "$config/init.lean"
sed "s|@HELLO@|$hello|" "$fixtures/bundle-script" >"$work/script"

core=$(cat "$app/Contents/Resources/editor.core")
scrub() {
  sed "s|$work|@DIR@|g; s|$app|@APP@|g; s|$core|@CORE@|g"
}
stable() {
  { grep -v '^job ' | grep -v 'Package build of' | grep -v '\*package-build\*' || true; } |
    sed 's/, published [0-9]*,/, published @N@,/'
}

started=$(date +%s)
status=0
(cd / && env -i PATH="$decoys:/usr/bin:/bin" HOME="$work/home" LEAN_CC="$decoys/cc" CC="$decoys/cc" \
  LEAN_SYSROOT="$decoys" "$launcher" --data "$work/data" headless --state "$work/state" --data "$work/data" \
  "$config" "$work/script") >"$work/out" 2>"$work/err" || status=$?
ended=$(date +%s)
scrub <"$work/out" >"$work/scrubbed"
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
test ! -s "$work/decoys.log" || fail "a build ran $(tr '\n' ' ' <"$work/decoys.log")"
listing | diff "$work/listing-before" - >&2 || fail "a build wrote into the bundle"
probe=$(env -i "$launcher" --data "$work/data" --probe | grep '^executable ')
test "$probe" = "executable $work/data/editors/$core/2/editor" || fail "the launcher chose $probe, not version 2"
echo "bundle-sets: installed hello-init from a path into the bundled editor and ran its command, dropped compile and started the result, from the bundle's own toolchain, read-only, with decoys first on the PATH ($((ended - started)) s)"
