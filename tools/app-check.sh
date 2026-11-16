#!/usr/bin/env bash
# The built app bundle, checked: `mise run app-check`
# (docs/dev-practices/on-demand-checks.md, "The app bundle, on demand").
#
# `mise run app` builds `lean/.lake/build/Leanmacs.app` first (`editorApp`
# in lean/lakefile.lean). This script then, in a temporary directory removed
# by a trap:
#
# 1. copies the bundle there with `ditto`, so everything after runs on a
#    relocated copy;
# 2. verifies the copy's signature with `codesign --verify --strict --deep`;
# 3. reads its `Info.plist` as the system does (`plutil`): it lints, its
#    `CFBundleExecutable` is an executable file under `Contents/MacOS`, its
#    `LSArchitecturePriority` starts with arm64, its
#    `LSMinimumSystemVersion` is no later than this machine's macOS, the
#    executable is arm64 alone (`lipo`), and its `CFBundleDocumentTypes`
#    are exactly two, `public.plain-text` then `public.source-code`, each
#    with the role `Editor` and the rank `Alternate`;
# 4. reads the icon with ImageIO (`sips`): 16 pixels wide;
# 5. runs the copy's `Contents/MacOS/editor headless` on the fixture
#    `tests/headless/bundle`, copied there too, with no directory argument,
#    an empty environment (`env -i`: no `HOME`, `PATH` or `LEAN_PATH`) and
#    `/` as the working directory: it must exit 0 and print exactly
#    `expected`, whose command calls compiled code of `Init` and of
#    `Editor`, so the copy found its toolchain and `.olean` files from its
#    own path;
# 6. builds `editorApp` again and checks that it copied and signed
#    nothing: the bundle's executable, its `CodeResources` and the build's
#    trace file keep their modification times and inodes. Lake's output is
#    printed, and holds no `Built editorApp` line;
# 7. in a clone of the Lean package (`cp -c`: the files share their blocks,
#    so it is quick and takes no space), with the stage script beside it and
#    a `cargo` that does nothing first on the PATH, so nothing but
#    `editorApp` builds: replaces the stage script with one that stages and
#    then fails, as a failed or interrupted rebuild would, builds
#    `editorApp`, which must fail, puts the script back, so the inputs hash
#    to the old trace again, and builds once more. The bundle must still
#    verify (`codesign --verify --strict --deep`) and be the old one: a
#    rebuild that never finished leaves no half-built bundle that the old
#    trace takes as up to date.
#
# It writes nothing outside the temporary directory but that second build,
# which is shown to write nothing. It opens no window and needs no person.
# It is macOS on arm64 only, as the bundle is.
#
# `$1` is the Lean package's directory.
set -euo pipefail

if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
  echo "app-check: the app bundle is macOS on arm64 only (this is $(uname -s) $(uname -m))" >&2
  exit 2
fi

lean_dir=$(cd "$1" && pwd)
fixtures=$(cd "$lean_dir/../tests/headless/bundle" && pwd)
built="$lean_dir/.lake/build/Leanmacs.app"
trace="$lean_dir/.lake/build/Leanmacs.app.trace"

dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT

fail() {
  echo "app-check: $*" >&2
  exit 1
}

started=$SECONDS
step() {
  echo "app-check: $1 ($((SECONDS - started)) s)"
  started=$SECONDS
}

[ -d "$built" ] || fail "no bundle at $built: run \`mise run app\`"

# 1. A relocated copy.
app="$dir/Leanmacs.app"
ditto "$built" "$app"
step "copied the bundle to a temporary directory"

# 2. The signature.
codesign --verify --strict --deep "$app" || fail "codesign --verify --strict --deep failed"
step "codesign --verify --strict --deep passed"

# 3. The property list, read as the system reads it.
plist="$app/Contents/Info.plist"
plutil -lint -s "$plist" || fail "Info.plist does not lint"
read_key() {
  plutil -extract "$1" raw -o - "$plist"
}
executable=$(read_key CFBundleExecutable)
[ -f "$app/Contents/MacOS/$executable" ] && [ -x "$app/Contents/MacOS/$executable" ] ||
  fail "CFBundleExecutable names $executable, which is no executable under Contents/MacOS"
[ "$(read_key LSArchitecturePriority.0)" = arm64 ] || fail "LSArchitecturePriority does not start with arm64"
minimum=$(read_key LSMinimumSystemVersion)
running=$(sw_vers -productVersion)
# Whether version $1 is no later than version $2, compared part by part.
not_later() {
  local IFS=.
  local -a a=($1) b=($2)
  local i
  for i in 0 1 2; do
    local x=${a[i]:-0} y=${b[i]:-0}
    if [ "$x" -lt "$y" ]; then return 0; fi
    if [ "$x" -gt "$y" ]; then return 1; fi
  done
  return 0
}
not_later "$minimum" "$running" ||
  fail "LSMinimumSystemVersion is $minimum, later than this machine's macOS $running"
archs=$(lipo -archs "$app/Contents/MacOS/$executable")
[ "$archs" = arm64 ] || fail "the executable is for $archs, not arm64 alone"
# The document types: plain text and source code, each with the app as an
# editor at rank Alternate, offered under "Open With" and never the default
# owner of the type; and no third.
types=(public.plain-text public.source-code)
for i in 0 1; do
  [ "$(read_key "CFBundleDocumentTypes.$i.CFBundleTypeRole")" = Editor ] ||
    fail "CFBundleDocumentTypes.$i.CFBundleTypeRole is not Editor"
  [ "$(read_key "CFBundleDocumentTypes.$i.LSHandlerRank")" = Alternate ] ||
    fail "CFBundleDocumentTypes.$i.LSHandlerRank is not Alternate"
  [ "$(read_key "CFBundleDocumentTypes.$i.LSItemContentTypes.0")" = "${types[i]}" ] ||
    fail "CFBundleDocumentTypes.$i.LSItemContentTypes.0 is not ${types[i]}"
done
if read_key CFBundleDocumentTypes.2 >/dev/null 2>&1; then
  fail "CFBundleDocumentTypes has more than two document types"
fi
step "Info.plist lints and names arm64, $executable, macOS $minimum (this machine runs $running), and the document types ${types[*]}, each as an editor at rank Alternate"

# 4. The icon, read by ImageIO.
width=$(sips -g pixelWidth "$app/Contents/Resources/Leanmacs.icns" | awk '/pixelWidth/ { print $2 }')
[ "$width" = 16 ] || fail "ImageIO reads the icon as ${width:-nothing} pixels wide, not 16"
step "ImageIO reads the icon, 16 pixels wide"

# 5. The headless mode from the copy, with nothing but its own path.
cp -R "$fixtures/config" "$dir/config"
cp "$fixtures/script" "$dir/script"
out=$(cd / && env -i "$app/Contents/MacOS/$executable" headless "$dir/config" "$dir/script") ||
  fail "the headless mode from the copy failed"
printf '%s\n' "$out"
printf '%s\n' "$out" | diff "$fixtures/expected" - || fail "the headless mode printed other than tests/headless/bundle/expected"
step "the copy's headless mode, with an empty environment from /, printed tests/headless/bundle/expected"

# 6. A second build copies and signs nothing.
marks() {
  stat -f '%m %i' "$built/Contents/MacOS/editor" "$built/Contents/_CodeSignature/CodeResources" "$trace"
}
before=$(marks)
(cd "$lean_dir" && LEAN_CC=/usr/bin/cc lake build --wfail editorApp)
after=$(marks)
[ "$before" = "$after" ] || fail "building editorApp again changed the bundle or its trace"
step "building editorApp again copied and signed nothing"

# 7. A rebuild that fails leaves the old bundle, never a half-built one.
clone="$dir/clone"
mkdir -p "$clone/tools" "$clone/target/release" "$clone/bin"
cp -Rpc "$lean_dir" "$clone/lean"
cp -p "$lean_dir/../tools/stage-bundle.sh" "$clone/tools/stage-bundle.real"
cp -pc "$lean_dir/../target/release/libeditor_ffi.a" "$clone/target/release/libeditor_ffi.a"
printf '#!/bin/sh\nexit 0\n' >"$clone/bin/cargo"
printf '#!/usr/bin/env bash\n"$(dirname "$0")/stage-bundle.real" "$@"\nexit 1\n' >"$clone/tools/stage-bundle.sh"
chmod +x "$clone/bin/cargo" "$clone/tools/stage-bundle.sh"
cloned="$clone/lean/.lake/build/Leanmacs.app"
clone_marks() {
  stat -f '%m %i' "$cloned/Contents/MacOS/editor" "$cloned/Contents/_CodeSignature/CodeResources"
}
build_clone() {
  (cd "$clone/lean" && PATH="$clone/bin:$PATH" LEAN_CC=/usr/bin/cc lake build --wfail editorApp)
}
before=$(clone_marks)
if build_clone >"$dir/failed.log" 2>&1; then
  cat "$dir/failed.log"
  fail "building editorApp with a stage script that fails succeeded"
fi
grep -q "stage-bundle.sh' exited with code 1" "$dir/failed.log" || {
  cat "$dir/failed.log"
  fail "building editorApp with a stage script that fails failed, but not in the stage script"
}
mv "$clone/tools/stage-bundle.real" "$clone/tools/stage-bundle.sh"
build_clone || fail "building editorApp in the clone with the stage script back failed"
codesign --verify --strict --deep "$cloned" ||
  fail "after a failed rebuild, the old trace took a half-built bundle as up to date"
[ "$before" = "$(clone_marks)" ] || fail "after a failed rebuild, the bundle is not the old one"
step "a failed rebuild left the old bundle, signed, and the next build took it as up to date"

echo "app-check: ok, $(du -sh "$built" | awk '{ print $1 }') bundle"
