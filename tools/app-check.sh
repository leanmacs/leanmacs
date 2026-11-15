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
#    `LSMinimumSystemVersion` is no later than this machine's macOS, and
#    the executable is arm64 alone (`lipo`);
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
#    printed, and holds no `Built editorApp` line.
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
step "Info.plist lints and names arm64, $executable, and macOS $minimum (this machine runs $running)"

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

echo "app-check: ok, $(du -sh "$built" | awk '{ print $1 }') bundle"
