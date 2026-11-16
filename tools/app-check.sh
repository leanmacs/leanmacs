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
#    executable's own minimum macOS (`vtool -show-build`, its `minos`) is
#    no later than `LSMinimumSystemVersion`, the executable is arm64 alone
#    (`lipo`), and its `CFBundleDocumentTypes`
#    are exactly two, `public.plain-text` then `public.source-code`, each
#    with the role `Editor` and the rank `Alternate`. Its
#    `CFBundleShortVersionString` and `CFBundleVersion` are each the line of
#    `lean/app/version`, read here from the file the build reads; its
#    `LSApplicationCategoryType` is `public.app-category.developer-tools`
#    and its `NSHumanReadableCopyright` is not empty;
# 4. converts the icon back to an iconset (`iconutil -c iconset`), which
#    must hold exactly the ten standard images, each read by ImageIO
#    (`sips`) at its nominal size, 16 to 1024 pixels;
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
#    trace takes as up to date;
# 8. in the same clone, writes another version, 9.8.7, into
#    `lean/app/version` and builds: the bundle must be rebuilt, verify, and
#    name 9.8.7 as both version keys;
# 9. turns the clone's artwork, `lean/app/Leanmacs.png`, a quarter
#    (`sips -r 90`) and builds: the bundle must be rebuilt and verify, its
#    icon must pass step 4's check, and its 1024-pixel image must differ
#    from before. So the artwork must not look the same turned a quarter;
# 10. writes malformed versions into the clone's `lean/app/version` (a
#    trailing space, an empty file, `1.x`, a second line, four parts) and
#    builds each: each build must fail on the version file and leave the
#    old bundle, which must still verify.
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

# The version, read from the file the build reads, so the two cannot drift.
version_file="$lean_dir/app/version"
IFS= read -r version <"$version_file" || fail "cannot read a line from $version_file"
[ -n "$version" ] || fail "$version_file is empty"

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
# The executable's own minimum macOS (its LC_BUILD_VERSION `minos`), which
# LaunchServices checks before it starts the app from Finder: no later than
# LSMinimumSystemVersion.
minos=$(vtool -show-build "$app/Contents/MacOS/$executable" | awk '$1 == "minos" { print $2; exit }')
[ -n "$minos" ] || fail "the executable records no minimum macOS"
not_later "$minos" "$minimum" ||
  fail "the executable needs macOS $minos, later than LSMinimumSystemVersion $minimum: Finder refuses to start it"
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
# The version, from the file the build reads, as both version keys.
for key in CFBundleShortVersionString CFBundleVersion; do
  value=$(read_key "$key" 2>/dev/null) || fail "Info.plist has no $key"
  [ "$value" = "$version" ] || fail "Info.plist's $key is $value, not $version (lean/app/version)"
done
category=$(read_key LSApplicationCategoryType 2>/dev/null) || fail "Info.plist has no LSApplicationCategoryType"
[ "$category" = public.app-category.developer-tools ] ||
  fail "Info.plist's LSApplicationCategoryType is $category, not public.app-category.developer-tools"
copyright=$(read_key NSHumanReadableCopyright 2>/dev/null) || fail "Info.plist has no NSHumanReadableCopyright"
[ -n "$copyright" ] || fail "Info.plist's NSHumanReadableCopyright is empty"
step "Info.plist lints and names arm64, $executable, macOS $minimum (this machine runs $running), the document types ${types[*]}, each as an editor at rank Alternate, version $version, the category $category and the copyright \"$copyright\""

# 4. The icon, converted back to its images and each read by ImageIO.
# Whether the iconset at $1 holds exactly the ten standard images, each at
# its nominal size.
icon_names=(icon_16x16.png icon_16x16@2x.png icon_32x32.png icon_32x32@2x.png icon_128x128.png
  icon_128x128@2x.png icon_256x256.png icon_256x256@2x.png icon_512x512.png icon_512x512@2x.png)
icon_sizes=(16 32 32 64 128 256 256 512 512 1024)
check_iconset() {
  local found expected i width height
  found=$(ls "$1" | sort)
  expected=$(printf '%s\n' "${icon_names[@]}" | sort)
  [ "$found" = "$expected" ] ||
    fail "the icon holds the images
$found
not the ten standard ones
$expected"
  for i in "${!icon_names[@]}"; do
    width=$(sips -g pixelWidth "$1/${icon_names[i]}" | awk '/pixelWidth/ { print $2 }')
    height=$(sips -g pixelHeight "$1/${icon_names[i]}" | awk '/pixelHeight/ { print $2 }')
    [ "$width" = "${icon_sizes[i]}" ] && [ "$height" = "${icon_sizes[i]}" ] ||
      fail "the icon's ${icon_names[i]} is ${width:-nothing}x${height:-nothing} pixels, not ${icon_sizes[i]}x${icon_sizes[i]}"
  done
}
iconutil -c iconset "$app/Contents/Resources/Leanmacs.icns" -o "$dir/icon.iconset" ||
  fail "iconutil cannot convert the icon back to an iconset"
check_iconset "$dir/icon.iconset"
step "the icon has the ten standard images, 16 to 1024 pixels"

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

# 8. A change of version rebuilds the bundle with the new version.
before=$(clone_marks)
printf '9.8.7\n' >"$clone/lean/app/version"
build_clone || fail "building editorApp in the clone after a change of version failed"
[ "$before" != "$(clone_marks)" ] || fail "a change of version did not rebuild the bundle"
codesign --verify --strict --deep "$cloned" || fail "after a change of version, the bundle does not verify"
for key in CFBundleShortVersionString CFBundleVersion; do
  value=$(plutil -extract "$key" raw -o - "$cloned/Contents/Info.plist" 2>/dev/null) ||
    fail "after a change of version, Info.plist has no $key"
  [ "$value" = 9.8.7 ] || fail "after a change of version to 9.8.7, Info.plist's $key is $value"
done
step "a change of version rebuilt the bundle, signed, with the new version"

# 9. A change of artwork rebuilds the bundle with the new icon. The
# artwork is turned a quarter, so it must not look the same turned.
iconutil -c iconset "$cloned/Contents/Resources/Leanmacs.icns" -o "$dir/before.iconset" ||
  fail "iconutil cannot convert the clone's icon back to an iconset"
before=$(clone_marks)
sips -r 90 "$clone/lean/app/Leanmacs.png" --out "$dir/turned.png" >/dev/null ||
  fail "sips cannot turn the artwork"
mv "$dir/turned.png" "$clone/lean/app/Leanmacs.png"
build_clone || fail "building editorApp in the clone after a change of artwork failed"
[ "$before" != "$(clone_marks)" ] || fail "a change of artwork did not rebuild the bundle"
codesign --verify --strict --deep "$cloned" || fail "after a change of artwork, the bundle does not verify"
iconutil -c iconset "$cloned/Contents/Resources/Leanmacs.icns" -o "$dir/after.iconset" ||
  fail "iconutil cannot convert the rebuilt icon back to an iconset"
check_iconset "$dir/after.iconset"
if cmp -s "$dir/before.iconset/icon_512x512@2x.png" "$dir/after.iconset/icon_512x512@2x.png"; then
  fail "the icon did not change after the artwork did (is lean/app/Leanmacs.png the same turned a quarter?)"
fi
step "a change of artwork rebuilt the bundle, signed, with the new icon"

# 10. A malformed version fails the build, naming the version file, and
# leaves the old bundle.
before=$(clone_marks)
for malformed in '0.1.0 \n' '' '1.x\n' '0.1.0\n0.2.0\n' '1.2.3.4\n'; do
  printf "$malformed" >"$clone/lean/app/version"
  if build_clone >"$dir/malformed.log" 2>&1; then
    cat "$dir/malformed.log"
    fail "building editorApp with the version file written by printf '$malformed' succeeded"
  fi
  grep -q "app/version must be one line" "$dir/malformed.log" || {
    cat "$dir/malformed.log"
    fail "building editorApp with the version file written by printf '$malformed' failed, but not on the version file"
  }
  [ "$before" = "$(clone_marks)" ] || fail "a build with a malformed version changed the bundle"
done
codesign --verify --strict --deep "$cloned" || fail "after a malformed version, the bundle does not verify"
printf '9.8.7\n' >"$clone/lean/app/version"
step "a malformed version failed the build on the version file and left the old bundle"

echo "app-check: ok, $(du -sh "$built" | awk '{ print $1 }') bundle"
