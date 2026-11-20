#!/usr/bin/env bash
# Lays out a directory as the app bundle will be, for the `editorApp` facet
# (`mise run app`), the gate's `bundle-test` and `mise run module-bench`
# (docs/design/lean-runtime.md, "Build"; docs/dev-practices/headless-mode.md,
# "From an app bundle").
#
#   tools/stage-bundle.sh [--launcher <file>] <bundle dir> <executable> <sysroot> <shipped list>
#   tools/stage-bundle.sh (--roots <root>,... | --closure <file>) [--launcher <file>] \
#     <bundle dir> <executable> <sysroot> <package olean dirs> <kind>...
#
# Either way it makes `<bundle dir>/Contents/MacOS/` and copies the
# executable there as `editor` (a copy, never a link), with the record of
# the core's identity in `Contents/Resources/editor.core` when the build
# wrote one, and with `--launcher` the app's launcher there as `leanmacs`
# (`crates/editor-launch-std`; the bundle's `CFBundleExecutable`, which
# starts `editor`). It only copies, and decides nothing: what to copy is
# what it is given.
#
# **The bundle as shipped** (the first form): everything a user's
# package-set build needs, so one builds from the app alone
# (docs/design/packages.md, "User package sets"), under
# `Contents/Resources`:
#
# - `lean/toolchain/`: the Lean toolchain `<sysroot>`, whole, but its
#   `exposed/` (mise's links): `lean`, `lake`, `clang`, `ld64.lld`, `Init`,
#   `Std`, `Lean` and `Lake`, the headers and the static libraries;
# - each file the shipped list names, at its place under `lean/`: the list
#   is what `lake -d <set dir> query :editorShipped` prints
#   (lean/lakefile.lean): one line `file<TAB><source><TAB><place>` a file,
#   the core's and each default package's sources and build output, the
#   set's and the packages' lakefiles, the core's glue and the Rust archive;
#   and one line `oleans<TAB><place>` for each `.olean` directory, in the
#   order the editor searches them;
# - `editor.oleans`: those directories, one a line, relative to
#   `Contents/Resources` (lean/Editor/ModuleLookup.lean, "The bundle's
#   record");
# - `editor.build`: the executable's `<executable>.build` without its
#   `LEAN_CC` line, so a build the app runs compiles and links with the
#   bundled toolchain's own `clang` (lean/Editor/PackageSet/Running.lean);
# - on macOS, `lean/link-stubs/`: the link stubs tools/link-stubs.sh
#   writes from the executable, which a link with the toolchain's own
#   linker needs for the system's frameworks (`linkAsEditor` in
#   lean/lakefile.lean).
#
# Every copy clones where the file system can (`cp -c` on macOS, `cp
# --reflink=auto` elsewhere), so on APFS the toolchain costs no disk.
#
# **Module files alone** (the second form, `mise run module-bench`'s
# experiments on what config may import; docs/design/lean-runtime.md,
# "What config may import, measured"): it copies module files, keeping
# their paths relative to the directory they are in:
#
# - from the toolchain's `<sysroot>/lib/lean` into
#   `Contents/Resources/lean/toolchain/lib/lean`, so that directory is a
#   sysroot;
# - from the packages' `.olean` directories into
#   `Contents/Resources/lean/editor`, one directory for them, which it
#   names in `Contents/Resources/editor.oleans`, so the bundle's editor
#   finds its modules there.
#
# `<package olean dirs>` is one directory, or several joined with `:`, as
# the editor reads its own `.olean` directory argument: the core's, then
# that of each package whose modules the config base holds
# (docs/design/packages.md, "The package set and its build"). A module is
# copied from the first of them that holds it.
#
# Only files of the given kinds are copied, each kind a file name's ending
# after the module's name (`olean`, `olean.server`, `olean.private`, `ir`,
# `ir.sig`); a kind a module has no file of is skipped.
#
# Which modules: with `--roots`, whole top-level directories with their
# root files (`Init.olean` and `Init/**` for `Init`), of the toolchain's
# roots it names, and `Editor` from each package directory that holds it.
# With `--closure <file>`, only the modules the file names, one module name
# a line (what `config-test bench-modules` prints), each taken from the
# toolchain's directory or the first package directory that holds it; a
# module in none of them is an error.
#
# It uses `find`, `tar` and `cp` only, so it runs with BSD and GNU tools
# alike, and writes nothing outside `<bundle dir>`.
set -euo pipefail

usage() {
  echo "usage: tools/stage-bundle.sh [--launcher <file>] <bundle dir> <executable> <sysroot> <shipped list>" >&2
  echo "       tools/stage-bundle.sh (--roots <root>,... | --closure <file>) [--launcher <file>] <bundle dir> <executable> <sysroot> <package olean dirs> <kind>..." >&2
  exit 2
}

roots=
closure=
launcher=
while [ $# -gt 0 ]; do
  case "$1" in
  --launcher)
    [ $# -ge 2 ] || usage
    launcher=$2
    shift 2
    ;;
  --roots)
    [ $# -ge 2 ] || usage
    roots=$2
    shift 2
    ;;
  --closure)
    [ $# -ge 2 ] || usage
    closure=$2
    shift 2
    ;;
  --*) usage ;;
  *) break ;;
  esac
done
[ $# -ge 4 ] || usage

bundle=$1
executable=$2
sysroot=$3

macos="$bundle/Contents/MacOS"
resources="$bundle/Contents/Resources"
mkdir -p "$macos" "$resources"
cp "$executable" "$macos/editor"
# The core's identity of the shipped default, in the bundle's resources,
# where the launcher reads it to choose a per-user editor
# (docs/design/packages.md, "User package sets"): `codesign` refuses a file
# in Contents/MacOS that is not code. An executable the package-set build
# did not link has none.
if [ -e "$executable.core" ]; then
  cp "$executable.core" "$resources/editor.core"
fi
if [ -n "$launcher" ]; then
  cp "$launcher" "$macos/leanmacs"
fi

# Copies files or trees, the last argument the directory they go into,
# cloning them where the file system can.
if [ "$(uname -s)" = Darwin ]; then
  clone_into() { cp -c -R "$@"; }
else
  clone_into() { cp --reflink=auto -R "$@"; }
fi

if [ -z "$roots" ] && [ -z "$closure" ]; then
  [ $# -eq 4 ] || usage
  shipped=$4
  lean="$resources/lean"
  mkdir -p "$lean/toolchain"
  # The toolchain, whole, but mise's links to its executables.
  for entry in "$sysroot"/*; do
    [ "$(basename "$entry")" = exposed ] && continue
    clone_into "$entry" "$lean/toolchain/"
  done
  tab=$(printf '\t')
  while IFS=$tab read -r kind first second || [ -n "$kind" ]; do
    case "$kind" in
    file | oleans | "") ;;
    *)
      echo "stage-bundle: $shipped holds a line of kind $kind, which is neither file nor oleans" >&2
      exit 1
      ;;
    esac
  done <"$shipped"
  awk -F'\t' '$1 == "oleans" { print $2 }' "$shipped" >"$resources/editor.oleans"
  # The files, one `cp` for each directory they go into: each keeps its
  # name, so its place's directory is all a copy needs. A line that would
  # rename its file is refused.
  awk -F'\t' '$1 == "file" {
      n = split($2, s, "/"); m = split($3, p, "/")
      if (s[n] != p[m]) { print "stage-bundle: " $2 " would be renamed to " $3 > "/dev/stderr"; exit 1 }
      d = (m > 1) ? substr($3, 1, length($3) - length(p[m]) - 1) : "."
      print d "\t" $2
    }' "$shipped" | sort >"$bundle/.shipped"
  copy_batch() {
    [ "${#sources[@]}" -gt 0 ] || return 0
    mkdir -p "$lean/$batch"
    clone_into "${sources[@]}" "$lean/$batch/"
  }
  batch=
  sources=()
  while IFS=$tab read -r directory source; do
    if [ "$directory" != "$batch" ]; then
      copy_batch
      batch=$directory
      sources=()
    fi
    sources+=("$source")
  done <"$bundle/.shipped"
  copy_batch
  rm "$bundle/.shipped"
  [ -s "$resources/editor.oleans" ] || {
    echo "stage-bundle: $shipped names no .olean directory" >&2
    exit 1
  }
  if [ -e "$executable.build" ]; then
    grep -v '^LEAN_CC=' "$executable.build" >"$resources/editor.build" || true
  fi
  if [ "$(uname -s)" = Darwin ]; then
    "$(dirname "$0")/link-stubs.sh" "$executable" "$lean/link-stubs"
  fi
  exit 0
fi

[ $# -ge 5 ] || usage
toolchain_lib="$sysroot/lib/lean"
# The package directories, in the order they are searched; an empty part
# of the argument names none.
IFS=: read -r -a given_packages <<<"$4"
packages=()
for directory in "${given_packages[@]}"; do
  [ -n "$directory" ] && packages+=("$directory")
done
[ "${#packages[@]}" -gt 0 ] || usage
shift 4
kinds=("$@")

staged_toolchain="$resources/lean/toolchain/lib/lean"
staged_editor="$resources/lean/editor"
mkdir -p "$staged_toolchain" "$staged_editor"
# The bundle's record of its one `.olean` directory, which its editor
# searches (lean/Editor/ModuleLookup.lean, "The bundle's record").
echo lean/editor >"$resources/editor.oleans"

# Copies the files listed on stdin, relative to `$1`, into `$2`, keeping
# their relative paths.
copy_listed() {
  (cd "$1" && tar -cf - -T -) | (cd "$2" && tar -xf -)
}

# Lists, relative to `$1`, the files of every kind of the top-level module
# `$2`: its root file and everything under its directory.
list_root() {
  (
    cd "$1"
    for kind in "${kinds[@]}"; do
      if [ -e "$2.$kind" ]; then echo "$2.$kind"; fi
      if [ -d "$2" ]; then find "$2" -type f -name "*.$kind"; fi
    done
  )
}

if [ -z "$closure" ]; then
  IFS=, read -r -a toolchain_roots <<<"$roots"
  for root in "${toolchain_roots[@]}"; do
    list_root "$toolchain_lib" "$root" | copy_listed "$toolchain_lib" "$staged_toolchain"
  done
  for package in "${packages[@]}"; do
    list_root "$package" Editor | copy_listed "$package" "$staged_editor"
  done
else
  toolchain_list=$(mktemp "$bundle/.toolchain.XXXXXX")
  # One list a package directory, named by its place in `packages`.
  editor_lists=$(mktemp -d "$bundle/.editor.XXXXXX")
  for index in "${!packages[@]}"; do
    : >"$editor_lists/$index"
  done
  while IFS= read -r module || [ -n "$module" ]; do
    [ -n "$module" ] || continue
    path=$(printf '%s' "$module" | tr . /)
    from=
    if [ -e "$toolchain_lib/$path.olean" ]; then
      from=$toolchain_lib
      list=$toolchain_list
    else
      for index in "${!packages[@]}"; do
        if [ -e "${packages[$index]}/$path.olean" ]; then
          from=${packages[$index]}
          list=$editor_lists/$index
          break
        fi
      done
    fi
    if [ -z "$from" ]; then
      echo "stage-bundle: no .olean file for $module in $toolchain_lib or ${packages[*]}" >&2
      exit 1
    fi
    for kind in "${kinds[@]}"; do
      if [ -e "$from/$path.$kind" ]; then echo "$path.$kind" >>"$list"; fi
    done
  done <"$closure"
  copy_listed "$toolchain_lib" "$staged_toolchain" <"$toolchain_list"
  for index in "${!packages[@]}"; do
    # A directory the closure takes nothing from has an empty list.
    if [ -s "$editor_lists/$index" ]; then
      copy_listed "${packages[$index]}" "$staged_editor" <"$editor_lists/$index"
    fi
  done
  rm -rf "$toolchain_list" "$editor_lists"
fi
