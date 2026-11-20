#!/usr/bin/env bash
# Lays out a directory as the app bundle will be, for the gate's
# `bundle-test` and for `mise run module-bench`
# (docs/dev-practices/headless-mode.md, "From an app bundle").
#
#   tools/stage-bundle.sh [--roots <root>,...] [--closure <file>] [--launcher <file>] \
#     <bundle dir> <executable> <sysroot> <package olean dirs> <kind>...
#
# It makes `<bundle dir>/Contents/MacOS/` and copies the executable there as
# `editor` (a copy, never a link), and with `--launcher` the app's launcher
# there as `leanmacs` (`crates/editor-launch-std`; the bundle's
# `CFBundleExecutable`, which starts `editor`), and copies module files,
# keeping their paths relative to the directory they are in:
#
# - from the toolchain's `<sysroot>/lib/lean` into
#   `Contents/Resources/lean/toolchain/lib/lean`, so that directory is a
#   sysroot;
# - from the packages' `.olean` directories into
#   `Contents/Resources/lean/editor`, the bundle's one directory for them.
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
# Which modules: by default whole top-level directories with their root
# files (`Init.olean` and `Init/**` for `Init`), of the toolchain's roots
# `--roots` names, `Init,Std` unless given, and `Editor` from each package
# directory that holds it. With `--closure <file>`, only the modules the
# file names, one module name a line (what `config-test bench-modules`
# prints), each taken from the toolchain's directory or the first package
# directory that holds it; a module in none of them is an error.
#
# It uses `find` and `tar` only, so it runs with BSD and GNU tools alike,
# and writes nothing outside `<bundle dir>`.
set -euo pipefail

usage() {
  echo "usage: tools/stage-bundle.sh [--roots <root>,...] [--closure <file>] [--launcher <file>] <bundle dir> <executable> <sysroot> <package olean dirs> <kind>..." >&2
  exit 2
}

roots=Init,Std
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
[ $# -ge 5 ] || usage

bundle=$1
executable=$2
toolchain_lib="$3/lib/lean"
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

macos="$bundle/Contents/MacOS"
staged_toolchain="$bundle/Contents/Resources/lean/toolchain/lib/lean"
staged_editor="$bundle/Contents/Resources/lean/editor"
mkdir -p "$macos" "$staged_toolchain" "$staged_editor"
cp "$executable" "$macos/editor"
if [ -n "$launcher" ]; then
  cp "$launcher" "$macos/leanmacs"
fi

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
