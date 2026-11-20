#!/usr/bin/env bash
# The built app bundle, checked: `mise run app-check`
# (docs/dev-practices/on-demand-checks.md, "The app bundle, on demand").
#
# `mise run app` builds `packages/.lake/build/Leanmacs.app` first, from the
# default package set (the facet `editorApp` of lean/lakefile.lean, built as
# `lake -d ../packages build :editorApp` in `lean/`), stamped with the build
# ID and the commit. This
# script first works out the stamp it expects with the same tool, `cargo
# run -p editor-release-std --bin leanmacs-release -- build-id` and
# `-- commit`, which take LEANMACS_BUILD_ID and LEANMACS_COMMIT when they
# are set (as in CI) and read HEAD otherwise, and exports both, so its own
# builds below see the values `mise run app` used. When neither variable
# was set, it also requires the two to be HEAD's committer time in UTC and
# HEAD's SHA as git itself prints them (`TZ=UTC git log -1
# --date=format-local:%Y%m%d%H%M%S --format=%cd`, `git rev-parse HEAD`), so
# the tool that stamps the bundle is not the only judge of what it reads
# from HEAD. Then, in a temporary directory removed by a trap:
#
# 1. copies the bundle there with `ditto --clone`, so everything after runs
#    on a relocated copy, which costs no disk on APFS;
# 2. verifies the copy's signature with `codesign --verify --strict --deep`;
# 3. reads its `Info.plist` as the system does (`plutil`): it lints, its
#    `CFBundleExecutable` is `leanmacs`, the launcher, an executable file
#    under `Contents/MacOS` beside the editor it starts, `editor`; its
#    `LSArchitecturePriority` starts with arm64, its
#    `LSMinimumSystemVersion` is no later than this machine's macOS, the
#    launcher's and the editor's own minimum macOS (`vtool -show-build`,
#    their `minos`) is no later than `LSMinimumSystemVersion`, each is
#    arm64 alone (`lipo`), and its `CFBundleDocumentTypes` are exactly two, each with
#    the role `Editor` and one content type: `public.text` at rank
#    `Alternate`, then `public.data` at rank `None`. A walk over the whole
#    plist finds no `LSHandlerRank` of `Default` or `Owner` and no
#    `UTImportedTypeDeclarations` or `UTExportedTypeDeclarations`. Both
#    checks run on mutated copies too (a wrong rank, role, content-type
#    count or entry count; a `Default`, an `Owner`, an inserted
#    `UTExportedTypeDeclarations`, an `Owner` under a dotted key the walk
#    cannot address), and each must fail naming the key. Its
#    `CFBundleShortVersionString` is the line of `lean/app/version`, read
#    here from the file the build reads, its `CFBundleVersion` the expected
#    build ID and its `LeanmacsCommit` the expected commit; its
#    `LSApplicationCategoryType` is `public.app-category.developer-tools`
#    and its `NSHumanReadableCopyright` is not empty;
# 4. converts the icon back to an iconset (`iconutil -c iconset`), which
#    must hold exactly the ten standard images, each read by ImageIO
#    (`sips`) at its nominal size, 16 to 1024 pixels;
# 5. runs the copy's `editor headless` on the fixture
#    `tests/headless/bundle`, copied there too, with no directory argument,
#    an empty environment (`env -i`: no `HOME`, `PATH` or `LEAN_PATH`) and
#    `/` as the working directory: it must exit 0 and print exactly
#    `expected`, whose command calls compiled code of `Init` and of
#    `Editor`, and whose root imports `Lean`, so the copy found its
#    toolchain and `.olean` files from its own path, Lean's among them;
# 5a. runs the copy's `editor headless --generate` the same way on a copy of
#    the fixture `tests/headless/generate`, whose config directory holds
#    `init.lean` alone: the config must load, printing exactly the
#    fixture's `expected`; the directory must then hold a `lean-toolchain`
#    that is `lean/lean-toolchain` byte for byte, and a `lakefile.toml`
#    equal to `tests/headless/generate/expected-lakefile-bundle` with
#    `@SET@` the copy's `Contents/Resources/lean/set`, the set the app ships;
# 5b. runs the copy's `editor --version` the same way, through the launcher,
#    with an empty environment from `/`: it must print exactly `Leanmacs
#    <version>`, `build <build ID>` and `commit <commit>`, so the Lean plist
#    reader (lean/Editor/Version.lean) reads the keys the build writes;
# 5c. runs the launcher's `--probe` of the copy's editor, and of a copy of
#    the editor outside the bundle with `--default`, each with an empty
#    environment from `/`: each must print `probe: ok`, the launcher, the
#    copy as CoreFoundation's main bundle with the app's identifier, and the
#    executable the launcher started, so the
#    launcher's `CFProcessPath` gives an editor outside the bundle the app's
#    identity (docs/design/lean-runtime.md, "The app's identity across an
#    exec");
# 5d. runs tools/bundle-sets.sh's checks on the copy: the pieces a
#    package-set build needs; the first launch, which builds nothing; and,
#    with the copy's `Contents/Resources/lean` read-only and decoys of every
#    tool first on the PATH, the unchanged default set built by the copy's
#    `lake`, compiling nothing of it; `hello-init` installed from a path and
#    run, and the default package `compile` dropped, by the editor's own
#    build; and the C FFI fixture `c-glue`, compiled by the bundled `clang`;
# 6. builds `editorApp` again and checks that it copied and signed
#    nothing: the bundle's executable, its `CodeResources` and the build's
#    trace file keep their modification times and inodes. Lake's output is
#    printed, and holds no `Built «default-set»:editorApp` line;
# 7. in a clone of the core and of the default set, `lean/` and `packages/`
#    side by side as they are in the checkout (`cp -c`: the files share
#    their blocks, so it is quick and takes no space), with the stage script
#    beside them and
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
#    name 9.8.7 as `CFBundleShortVersionString`, with `CFBundleVersion`
#    still the expected build ID;
# 9. turns the clone's artwork, `lean/app/Leanmacs.png`, a quarter
#    (`sips -r 90`) and builds: the bundle must be rebuilt and verify, its
#    icon must pass step 4's check, and its 1024-pixel image must differ
#    from before. So the artwork must not look the same turned a quarter;
# 10. writes malformed versions into the clone's `lean/app/version` (a
#    trailing space, an empty file, `1.x`, a second line, four parts) and
#    builds each: each build must fail on the version file and leave the
#    old bundle, which must still verify;
# 11. writes `0.1.0` with no newline after it and builds: the build must
#    succeed with 0.1.0 as `CFBundleShortVersionString`, with
#    `CFBundleVersion` still the expected build ID, and this check must read
#    0.1.0 from the file, so the build and the check take the same version
#    files;
# 12. replaces the clone's artwork with a 512x300 PNG, a 256x256 PNG and a
#    1024x1024 JPEG and builds each: each build must fail on the artwork,
#    which must be a 1024x1024 PNG, and leave the old bundle, which must
#    still verify. The artwork is then put back;
# 13. builds the clone with LEANMACS_BUILD_ID=20010203040506 and
#    LEANMACS_COMMIT forty `a`s (20010203040507 and forty `b`s when the
#    stamp expected is that one): the bundle must be rebuilt and verify, its
#    `CFBundleVersion` and `LeanmacsCommit` must be those two, and its
#    `editor --version` must print them;
# 14. builds the clone with LEANMACS_BUILD_ID unset, `2026` and
#    `2001020304050x`, and with LEANMACS_COMMIT unset, in upper case and
#    39 digits long: each build must fail naming the variable and leave the
#    old bundle, which must still verify.
#
# It writes nothing outside the temporary directory but that second build,
# which is shown to write nothing. It opens no window and needs no person.
# It is macOS on arm64 only, as the bundle is.
#
# `$1` is the core's directory, `lean/`, and `$2` the default package
# set's, `packages/`, whose build directory holds the bundle.
set -euo pipefail

if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
  echo "app-check: the app bundle is macOS on arm64 only (this is $(uname -s) $(uname -m))" >&2
  exit 2
fi

lean_dir=$(cd "$1" && pwd)
set_dir=$(cd "$2" && pwd)
fixtures=$(cd "$lean_dir/../tests/headless/bundle" && pwd)
built="$set_dir/.lake/build/Leanmacs.app"
trace="$set_dir/.lake/build/Leanmacs.app.trace"

dir=$(mktemp -d)
# The read-only bits step 5d sets are put back first.
trap 'chmod -R u+w "$dir" 2>/dev/null || true; rm -rf "$dir"' EXIT
# The temporary directory's own path, its links resolved: CoreFoundation
# names the main bundle so (step 5c).
dir=$(cd "$dir" && pwd -P)

fail() {
  echo "app-check: $*" >&2
  exit 1
}

# The version, read from the file the build reads, so the two cannot drift.
# Into `version_read`, the first line of the file at $1, with or without a
# newline after it, as the build takes it (step 11).
read_version() {
  version_read=
  # `read` fails at an end of file with no newline before it, but has read
  # the line.
  IFS= read -r version_read <"$1" || [ -n "$version_read" ] || fail "cannot read a line from $1"
  [ -n "$version_read" ] || fail "$1 is empty"
}
version_file="$lean_dir/app/version"
read_version "$version_file"
version=$version_read

# The stamp `mise run app` built with, worked out as it does and exported,
# so every build below sees it. Before the clone puts a `cargo` that does
# nothing first on the PATH.
stamp_given=
if [ -n "${LEANMACS_BUILD_ID+set}" ] || [ -n "${LEANMACS_COMMIT+set}" ]; then
  stamp_given=1
fi
release_tool() {
  (cd "$lean_dir" && cargo run --quiet --locked --manifest-path ../Cargo.toml -p editor-release-std --bin leanmacs-release -- "$1")
}
build_id=$(release_tool build-id) || fail "leanmacs-release build-id failed"
commit=$(release_tool commit) || fail "leanmacs-release commit failed"
export LEANMACS_BUILD_ID=$build_id LEANMACS_COMMIT=$commit
if [ -z "$stamp_given" ]; then
  # HEAD as git itself prints it, not as the tool reads it.
  git_id=$(cd "$lean_dir" && TZ=UTC git log -1 --date=format-local:%Y%m%d%H%M%S --format=%cd) ||
    fail "git cannot read HEAD's committer time"
  git_commit=$(cd "$lean_dir" && git rev-parse HEAD) || fail "git cannot read HEAD"
  [ "$build_id" = "$git_id" ] ||
    fail "leanmacs-release build-id says $build_id, but HEAD's committer time in UTC is $git_id"
  [ "$commit" = "$git_commit" ] || fail "leanmacs-release commit says $commit, but HEAD is $git_commit"
fi
sha_a=$(printf 'a%.0s' $(seq 40))

started=$SECONDS
step() {
  echo "app-check: $1 ($((SECONDS - started)) s)"
  started=$SECONDS
}

[ -d "$built" ] || fail "no bundle at $built: run \`mise run app\`"
if [ -n "$stamp_given" ]; then
  step "expecting build $build_id from commit $commit, as LEANMACS_BUILD_ID and LEANMACS_COMMIT give them"
else
  step "expecting build $build_id from commit $commit, HEAD's as git prints them"
fi

# 1. A relocated copy.
app="$dir/Leanmacs.app"
ditto --clone "$built" "$app"
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
[ "$executable" = leanmacs ] || fail "CFBundleExecutable is $executable, not the launcher, leanmacs"
[ -f "$app/Contents/MacOS/$executable" ] && [ -x "$app/Contents/MacOS/$executable" ] ||
  fail "CFBundleExecutable names $executable, which is no executable under Contents/MacOS"
[ -f "$app/Contents/MacOS/editor" ] && [ -x "$app/Contents/MacOS/editor" ] ||
  fail "Contents/MacOS/editor, the shipped editor the launcher starts, is no executable"
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
# The launcher and the editor it starts, each.
for binary in "$executable" editor; do
  minos=$(vtool -show-build "$app/Contents/MacOS/$binary" | awk '$1 == "minos" { print $2; exit }')
  [ -n "$minos" ] || fail "Contents/MacOS/$binary records no minimum macOS"
  not_later "$minos" "$minimum" ||
    fail "Contents/MacOS/$binary needs macOS $minos, later than LSMinimumSystemVersion $minimum: Finder refuses to start it"
  archs=$(lipo -archs "$app/Contents/MacOS/$binary")
  [ "$archs" = arm64 ] || fail "Contents/MacOS/$binary is for $archs, not arm64 alone"
done
# The document types: every text type (public.text) at rank Alternate,
# offered under "Open With" and never the default, and any file
# (public.data) at rank None, accepted but never offered or chosen; each with
# the app as an editor, and no third. Into `types_problem`, the first way the
# plist at $1 differs from that, naming the key path; returns 1 if it does.
check_document_types() {
  local p=$1 i n value
  local -a expected=(public.text public.data) ranks=(Alternate None)
  types_problem=
  n=$(plutil -extract CFBundleDocumentTypes raw -o - "$p" 2>/dev/null) || n=0
  if [ "$n" != 2 ]; then
    types_problem="CFBundleDocumentTypes has $n document types, not 2"
    return 1
  fi
  for i in 0 1; do
    value=$(plutil -extract "CFBundleDocumentTypes.$i.CFBundleTypeRole" raw -o - "$p" 2>/dev/null) || value=nothing
    if [ "$value" != Editor ]; then
      types_problem="CFBundleDocumentTypes.$i.CFBundleTypeRole is $value, not Editor"
      return 1
    fi
    value=$(plutil -extract "CFBundleDocumentTypes.$i.LSHandlerRank" raw -o - "$p" 2>/dev/null) || value=nothing
    if [ "$value" != "${ranks[i]}" ]; then
      types_problem="CFBundleDocumentTypes.$i.LSHandlerRank is $value, not ${ranks[i]}"
      return 1
    fi
    value=$(plutil -extract "CFBundleDocumentTypes.$i.LSItemContentTypes" raw -o - "$p" 2>/dev/null) || value=0
    if [ "$value" != 1 ]; then
      types_problem="CFBundleDocumentTypes.$i.LSItemContentTypes has $value types, not 1"
      return 1
    fi
    value=$(plutil -extract "CFBundleDocumentTypes.$i.LSItemContentTypes.0" raw -o - "$p" 2>/dev/null) || value=nothing
    if [ "$value" != "${expected[i]}" ]; then
      types_problem="CFBundleDocumentTypes.$i.LSItemContentTypes.0 is $value, not ${expected[i]}"
      return 1
    fi
  done
}
# No claim on any type: walks the whole plist at $1 and, into
# `claims_problem`, names the first `LSHandlerRank` of Default or Owner (by
# its dotted key path) or the first type declaration; returns 1 if it finds
# one. plutil cannot address the root by key path, so the root's keys are
# read from `plutil -p`, whose top-level keys are the lines indented by two
# spaces; below the root, `plutil -type` and `-extract … raw` (keys of a
# dictionary, count of an array) walk it. A key path plutil cannot read
# (a key holding a dot) fails the check as `cannot read <path>`.
check_no_claims() {
  local p=$1 key
  claims_problem=
  local -a root_keys=()
  while IFS= read -r key; do root_keys+=("$key"); done < <(
    plutil -p "$p" | sed -n 's/^  "\([^"]*\)" => .*/\1/p'
  )
  for key in "${root_keys[@]}"; do
    case $key in
      UTImportedTypeDeclarations | UTExportedTypeDeclarations)
        claims_problem="Info.plist declares $key"
        return 1
        ;;
    esac
  done
  for key in "${root_keys[@]}"; do
    walk_claims "$p" "$key" "$key" || return 1
  done
}
# Walks the value at key path $2, whose last key is $3, in the plist at $1.
walk_claims() {
  local p=$1 path=$2 last=$3 type child n i value
  type=$(plutil -type "$path" "$p" 2>/dev/null) || {
    claims_problem="cannot read $path"
    return 1
  }
  case $type in
    dictionary)
      value=$(plutil -extract "$path" raw -o - "$p" 2>/dev/null) || {
        claims_problem="cannot read $path"
        return 1
      }
      while IFS= read -r child; do
        [ -n "$child" ] || continue
        walk_claims "$p" "$path.$child" "$child" || return 1
      done <<<"$value"
      ;;
    array)
      n=$(plutil -extract "$path" raw -o - "$p" 2>/dev/null) || {
        claims_problem="cannot read $path"
        return 1
      }
      for ((i = 0; i < n; i++)); do
        walk_claims "$p" "$path.$i" "$i" || return 1
      done
      ;;
    string)
      if [ "$last" = LSHandlerRank ]; then
        value=$(plutil -extract "$path" raw -o - "$p" 2>/dev/null) || {
          claims_problem="cannot read $path"
          return 1
        }
        case $value in
          Default | Owner)
            claims_problem="$path is $value"
            return 1
            ;;
        esac
      fi
      ;;
  esac
}
check_document_types "$plist" || fail "$types_problem"
check_no_claims "$plist" || fail "$claims_problem"
# Both checks are shown to catch what they are for, on mutated copies that
# still lint.
# Copies the plist to $dir/mutated.plist and applies plutil arguments $@.
mutate() {
  cp "$plist" "$dir/mutated.plist"
  plutil "$@" "$dir/mutated.plist" || fail "plutil $* failed on a copy of Info.plist"
  plutil -lint -s "$dir/mutated.plist" || fail "a copy of Info.plist after plutil $* does not lint"
}
types_mutations=(
  "-replace CFBundleDocumentTypes.0.LSHandlerRank -string Default|CFBundleDocumentTypes.0.LSHandlerRank is Default, not Alternate"
  "-replace CFBundleDocumentTypes.1.CFBundleTypeRole -string Viewer|CFBundleDocumentTypes.1.CFBundleTypeRole is Viewer, not Editor"
  "-insert CFBundleDocumentTypes.0.LSItemContentTypes.1 -string public.json|CFBundleDocumentTypes.0.LSItemContentTypes has 2 types, not 1"
  "-insert CFBundleDocumentTypes.2 -dictionary|CFBundleDocumentTypes has 3 document types, not 2"
)
for m in "${types_mutations[@]}"; do
  read -r -a args <<<"${m%%|*}"
  mutate "${args[@]}"
  if check_document_types "$dir/mutated.plist" || [ "$types_problem" != "${m#*|}" ]; then
    fail "the check of the document types missed ${m%%|*} (it said: ${types_problem:-nothing})"
  fi
done
claims_mutations=(
  "-replace CFBundleDocumentTypes.1.LSHandlerRank -string Default|CFBundleDocumentTypes.1.LSHandlerRank is Default"
  "-replace CFBundleDocumentTypes.0.LSHandlerRank -string Owner|CFBundleDocumentTypes.0.LSHandlerRank is Owner"
  "-insert UTExportedTypeDeclarations -array|Info.plist declares UTExportedTypeDeclarations"
  "-insert X -xml <dict><key>has.dot</key><dict><key>LSHandlerRank</key><string>Owner</string></dict></dict>|cannot read X.has.dot"
)
for m in "${claims_mutations[@]}"; do
  read -r -a args <<<"${m%%|*}"
  mutate "${args[@]}"
  if check_no_claims "$dir/mutated.plist" || [ "$claims_problem" != "${m#*|}" ]; then
    fail "the check for Default, Owner and type declarations missed ${m%%|*} (it said: ${claims_problem:-nothing})"
  fi
done
# The version, from the file the build reads, the build ID and the commit.
# Whether the plist at $1 has key $2 with the value $3; $4 says what $3 is.
check_key() {
  local value
  value=$(plutil -extract "$2" raw -o - "$1" 2>/dev/null) || fail "Info.plist has no $2"
  [ "$value" = "$3" ] || fail "Info.plist's $2 is $value, not $3 ($4)"
}
check_key "$plist" CFBundleShortVersionString "$version" lean/app/version
check_key "$plist" CFBundleVersion "$build_id" "the build ID"
check_key "$plist" LeanmacsCommit "$commit" "the commit"
category=$(read_key LSApplicationCategoryType 2>/dev/null) || fail "Info.plist has no LSApplicationCategoryType"
[ "$category" = public.app-category.developer-tools ] ||
  fail "Info.plist's LSApplicationCategoryType is $category, not public.app-category.developer-tools"
copyright=$(read_key NSHumanReadableCopyright 2>/dev/null) || fail "Info.plist has no NSHumanReadableCopyright"
[ -n "$copyright" ] || fail "Info.plist's NSHumanReadableCopyright is empty"
step "Info.plist lints and names arm64, $executable, macOS $minimum (this machine runs $running), the document types public.text (Editor, Alternate) and public.data (Editor, None), no rank of Default or Owner and no type declarations (each check catching its mutated copies), version $version, build $build_id, commit $commit, the category $category and the copyright \"$copyright\""

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

# 5a. The generated files: the toolchain file, and the lakefile naming the
# set the copy ships.
generate=$(cd "$lean_dir/../tests/headless/generate" && pwd)
cp -R "$generate/config" "$dir/generate-config"
cp "$generate/script" "$dir/generate-script"
out=$(cd / && env -i "$app/Contents/MacOS/$executable" headless --generate "$dir/generate-config" "$dir/generate-script") ||
  fail "the headless mode with --generate from the copy failed"
printf '%s\n' "$out"
printf '%s\n' "$out" | diff "$generate/expected" - ||
  fail "the headless mode with --generate printed other than tests/headless/generate/expected"
cmp -s "$dir/generate-config/lean-toolchain" "$lean_dir/lean-toolchain" ||
  fail "the generated lean-toolchain is not lean/lean-toolchain"
sed "s|@SET@|$app/Contents/Resources/lean/set|" "$generate/expected-lakefile-bundle" |
  diff - "$dir/generate-config/lakefile.toml" ||
  fail "the generated lakefile.toml is not expected-lakefile-bundle naming the copy's set"
step "the copy's headless mode with --generate loaded the config, and generated lean-toolchain and a lakefile naming the copy's set"

# 5b. What the copy says of its build, read from its own Info.plist.
# Whether the bundle at $1 says version $2, build $3 and commit $4.
check_says() {
  local said
  said=$(cd / && env -i "$1/Contents/MacOS/leanmacs" --version) || fail "$1's editor --version failed"
  [ "$said" = "$(printf 'Leanmacs %s\nbuild %s\ncommit %s' "$2" "$3" "$4")" ] ||
    fail "$1's editor --version printed
$said
not version $2, build $3, commit $4"
}
check_says "$app" "$version" "$build_id" "$commit"
step "the copy's editor --version, with an empty environment from /, printed version $version, build $build_id and commit $commit"

# 5c. The app's identity, through the launcher: the bundle's editor, and a
# copy of it outside the bundle started with --default, each see the copy as
# CoreFoundation's main bundle, with its identifier.
identifier=$(read_key CFBundleIdentifier)
printf 'probe: ok\nlaunched-by %s\nbundle %s identifier %s\nexecutable %s\n' "$app/Contents/MacOS/leanmacs" "$app" "$identifier" "$app/Contents/MacOS/editor" >"$dir/probe-expected"
(cd / && env -i "$app/Contents/MacOS/leanmacs" --probe) | diff "$dir/probe-expected" - ||
  fail "the launcher's probe of the bundle's editor printed other than the copy and its identifier"
mkdir "$dir/outside"
cp "$app/Contents/MacOS/editor" "$dir/outside/editor"
printf 'probe: ok\nlaunched-by %s\nbundle %s identifier %s\nexecutable %s\n' "$app/Contents/MacOS/leanmacs" "$app" "$identifier" "$dir/outside/editor" >"$dir/outside-expected"
(cd / && env -i "$app/Contents/MacOS/leanmacs" --default "$dir/outside/editor" -- --probe) |
  diff "$dir/outside-expected" - ||
  fail "the launcher's probe of an editor outside the bundle printed other than the copy and its identifier"
step "the bundle's editor and a copy outside it, started by the launcher, both see the copy, $identifier, as their main bundle"

# 5d. A user's package set from the copy alone (tools/bundle-sets.sh): the
# pieces a build needs are there; a first launch builds nothing; and, with
# the copy's Contents/Resources/lean read-only and decoys of every tool
# first on the PATH, the unchanged default set builds compiling nothing of
# it, a package installed from a path runs its command and a default one
# dropped starts, and a package with C builds with the bundled clang.
for check in pieces first-launch; do
  mkdir "$dir/sets-$check"
  sh "$lean_dir/../tools/bundle-sets.sh" "$check" "$app" "$dir/sets-$check" "$lean_dir/.."
done
chmod -R a-w "$app/Contents/Resources/lean"
for check in default-set sets c-glue; do
  mkdir "$dir/sets-$check"
  sh "$lean_dir/../tools/bundle-sets.sh" "$check" "$app" "$dir/sets-$check" "$lean_dir/.."
done
step "the copy holds every piece a package-set build needs, starts at first launch with no build, builds the default set compiling nothing of it, installs hello-init and runs its command, drops compile and starts the result, and builds c-glue's C, all from its own toolchain with its resources read-only"

# 6. A second build copies and signs nothing.
marks() {
  stat -f '%m %i' "$built/Contents/MacOS/editor" "$built/Contents/_CodeSignature/CodeResources" "$trace"
}
before=$(marks)
(cd "$lean_dir" && LEAN_CC=/usr/bin/cc lake -d "$set_dir" build --wfail :editorApp)
after=$(marks)
[ "$before" = "$after" ] || fail "building editorApp again changed the bundle or its trace"
step "building editorApp again copied and signed nothing"

# 7. A rebuild that fails leaves the old bundle, never a half-built one.
clone="$dir/clone"
mkdir -p "$clone/tools" "$clone/target/release" "$clone/target/editor-rust" "$clone/bin"
cp -Rpc "$lean_dir" "$clone/lean"
cp -Rpc "$set_dir" "$clone/packages"
cp -p "$lean_dir/../tools/stage-bundle.sh" "$clone/tools/stage-bundle.real"
cp -p "$lean_dir/../tools/link-stubs.sh" "$clone/tools/link-stubs.sh"
# The default set's Rust archive and the crate generated for it, with the
# system libraries it needs and the root lock it is seeded from: the fake
# `cargo` below builds nothing, so they must be there already.
cp -pc "$lean_dir/../target/release/libeditor_rust.a" "$clone/target/release/libeditor_rust.a"
cp -Rpc "$lean_dir/../target/editor-rust/core" "$clone/target/editor-rust/core"
cp -p "$lean_dir/../Cargo.lock" "$clone/Cargo.lock"
mkdir -p "$clone/crates/editor-ffi"
cp -pc "$lean_dir/../target/release/leanmacs" "$clone/target/release/leanmacs"
printf '#!/bin/sh\nexit 0\n' >"$clone/bin/cargo"
printf '#!/usr/bin/env bash\n"$(dirname "$0")/stage-bundle.real" "$@"\nexit 1\n' >"$clone/tools/stage-bundle.sh"
chmod +x "$clone/bin/cargo" "$clone/tools/stage-bundle.sh"
cloned="$clone/packages/.lake/build/Leanmacs.app"
clone_marks() {
  stat -f '%m %i' "$cloned/Contents/MacOS/editor" "$cloned/Contents/_CodeSignature/CodeResources"
}
build_clone() {
  (cd "$clone/lean" && PATH="$clone/bin:$PATH" LEAN_CC=/usr/bin/cc lake -d ../packages build --wfail :editorApp)
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
check_key "$cloned/Contents/Info.plist" CFBundleShortVersionString 9.8.7 "the new version"
check_key "$cloned/Contents/Info.plist" CFBundleVersion "$build_id" "the build ID, unchanged"
step "a change of version rebuilt the bundle, signed, with the new version and the same build ID"

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

# 11. A version file whose one line has no newline after it: the build takes
# it, and this check reads the same version from it.
printf '0.1.0' >"$clone/lean/app/version"
build_clone || fail "building editorApp in the clone with a version file of 0.1.0 and no newline failed"
read_version "$clone/lean/app/version"
[ "$version_read" = 0.1.0 ] ||
  fail "this check read $version_read, not 0.1.0, from a version file of 0.1.0 and no newline"
check_key "$cloned/Contents/Info.plist" CFBundleShortVersionString 0.1.0 "a version file of 0.1.0 and no newline"
check_key "$cloned/Contents/Info.plist" CFBundleVersion "$build_id" "the build ID, unchanged"
codesign --verify --strict --deep "$cloned" || fail "with a version file with no newline, the bundle does not verify"
step "a version file with no newline built the bundle with that version, and this check read the same version"

# 12. Artwork that is not a 1024x1024 PNG fails the build, naming the
# artwork, and leaves the old bundle: sips would stretch it into a blurred
# icon.
cp -pc "$clone/lean/app/Leanmacs.png" "$dir/artwork.png"
before=$(clone_marks)
for wrong in 512x300.png 256x256.png 1024x1024.jpeg; do
  size=${wrong%.*} format=${wrong##*.}
  sips -s format "$format" -z "${size#*x}" "${size%x*}" "$dir/artwork.png" --out "$dir/wrong.$format" >/dev/null ||
    fail "sips cannot make the $wrong artwork"
  mv "$dir/wrong.$format" "$clone/lean/app/Leanmacs.png"
  if build_clone >"$dir/artwork.log" 2>&1; then
    cat "$dir/artwork.log"
    fail "building editorApp with $wrong artwork succeeded"
  fi
  grep -q "app/Leanmacs.png must be a 1024x1024 PNG" "$dir/artwork.log" || {
    cat "$dir/artwork.log"
    fail "building editorApp with $wrong artwork failed, but not on the artwork"
  }
  [ "$before" = "$(clone_marks)" ] || fail "a build with $wrong artwork changed the bundle"
done
codesign --verify --strict --deep "$cloned" || fail "after wrong artwork, the bundle does not verify"
mv "$dir/artwork.png" "$clone/lean/app/Leanmacs.png"
step "artwork that is not a 1024x1024 PNG failed the build on the artwork and left the old bundle"

# 13. The stamp comes from the environment: another build ID and commit
# rebuild the bundle with them.
# Builds the clone with the environment changed by `env` arguments $@.
build_clone_env() {
  (cd "$clone/lean" && env "$@" PATH="$clone/bin:$PATH" LEAN_CC=/usr/bin/cc lake -d ../packages build --wfail :editorApp)
}
# The fake stamp, or the next one when this check was given the fake stamp
# itself (the by-hand run in docs/dev-practices/on-demand-checks.md), so
# that it always differs from the stamp the clone was built with.
other_id=20010203040506 other_sha=$sha_a
if [ "$build_id" = "$other_id" ] || [ "$commit" = "$other_sha" ]; then
  other_id=20010203040507 other_sha=$(printf 'b%.0s' $(seq 40))
fi
before=$(clone_marks)
build_clone_env LEANMACS_BUILD_ID=$other_id LEANMACS_COMMIT="$other_sha" ||
  fail "building editorApp in the clone with a build ID and commit of its own failed"
[ "$before" != "$(clone_marks)" ] || fail "another build ID and commit did not rebuild the bundle"
codesign --verify --strict --deep "$cloned" || fail "after another build ID and commit, the bundle does not verify"
check_key "$cloned/Contents/Info.plist" CFBundleVersion "$other_id" "LEANMACS_BUILD_ID"
check_key "$cloned/Contents/Info.plist" LeanmacsCommit "$other_sha" "LEANMACS_COMMIT"
read_version "$clone/lean/app/version"
check_says "$cloned" "$version_read" "$other_id" "$other_sha"
step "another build ID and commit, $other_id and $other_sha, rebuilt the bundle, signed, naming both, and its editor --version said them"

# 14. A missing or malformed stamp fails the build, naming the variable,
# and leaves the old bundle.
before=$(clone_marks)
sha_upper=$(printf '%s' "$sha_a" | tr a-z A-Z)
sha_short=${sha_a%a}
stamp_cases=(
  "-u LEANMACS_BUILD_ID LEANMACS_COMMIT=$sha_a|LEANMACS_BUILD_ID must be the build ID"
  "LEANMACS_BUILD_ID=2026 LEANMACS_COMMIT=$sha_a|LEANMACS_BUILD_ID must be the build ID"
  "LEANMACS_BUILD_ID=2001020304050x LEANMACS_COMMIT=$sha_a|LEANMACS_BUILD_ID must be the build ID"
  "-u LEANMACS_COMMIT LEANMACS_BUILD_ID=20010203040506|LEANMACS_COMMIT must be the commit"
  "LEANMACS_BUILD_ID=20010203040506 LEANMACS_COMMIT=$sha_upper|LEANMACS_COMMIT must be the commit"
  "LEANMACS_BUILD_ID=20010203040506 LEANMACS_COMMIT=$sha_short|LEANMACS_COMMIT must be the commit"
)
for c in "${stamp_cases[@]}"; do
  read -r -a args <<<"${c%%|*}"
  if build_clone_env "${args[@]}" >"$dir/stamp.log" 2>&1; then
    cat "$dir/stamp.log"
    fail "building editorApp with ${c%%|*} succeeded"
  fi
  grep -qF "${c#*|}" "$dir/stamp.log" || {
    cat "$dir/stamp.log"
    fail "building editorApp with ${c%%|*} failed, but not naming the variable"
  }
  [ "$before" = "$(clone_marks)" ] || fail "a build with ${c%%|*} changed the bundle"
done
codesign --verify --strict --deep "$cloned" || fail "after a missing or malformed stamp, the bundle does not verify"
step "a missing or malformed build ID or commit failed the build, naming the variable, and left the old bundle"

echo "app-check: ok, $(du -sh "$built" | awk '{ print $1 }') bundle"
