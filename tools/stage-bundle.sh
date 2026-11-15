#!/usr/bin/env bash
# Lays out a directory as the app bundle will be, for the gate's
# `bundle-test` and for `mise run module-bench`
# (docs/dev-practices/headless-mode.md, "From an app bundle").
#
#   tools/stage-bundle.sh [--roots <root>,...] [--closure <file>] \
#     <bundle dir> <executable> <sysroot> <package olean dir> <kind>...
#
# It makes `<bundle dir>/Contents/MacOS/` and copies the executable there as
# `editor` (a copy, never a link), and copies module files, keeping their
# paths relative to the directory they are in:
#
# - from the toolchain's `<sysroot>/lib/lean` into
#   `Contents/Resources/lean/toolchain/lib/lean`, so that directory is a
#   sysroot;
# - from the package's `.olean` directory into
#   `Contents/Resources/lean/editor`.
#
# Only files of the given kinds are copied, each kind a file name's ending
# after the module's name (`olean`, `olean.server`, `olean.private`, `ir`,
# `ir.sig`); a kind a module has no file of is skipped.
#
# Which modules: by default whole top-level directories with their root
# files (`Init.olean` and `Init/**` for `Init`), of the toolchain's roots
# `--roots` names, `Init,Std` unless given, and the package's `Editor`. With
# `--closure <file>`, only the modules the file names, one module name a
# line (what `config-test bench-modules` prints), each taken from whichever
# of the two directories holds it; a module in neither is an error.
#
# It uses `find` and `tar` only, so it runs with BSD and GNU tools alike,
# and writes nothing outside `<bundle dir>`.
set -euo pipefail

usage() {
  echo "usage: tools/stage-bundle.sh [--roots <root>,...] [--closure <file>] <bundle dir> <executable> <sysroot> <package olean dir> <kind>..." >&2
  exit 2
}

roots=Init,Std
closure=
while [ $# -gt 0 ]; do
  case "$1" in
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
package=$4
shift 4
kinds=("$@")

macos="$bundle/Contents/MacOS"
staged_toolchain="$bundle/Contents/Resources/lean/toolchain/lib/lean"
staged_editor="$bundle/Contents/Resources/lean/editor"
mkdir -p "$macos" "$staged_toolchain" "$staged_editor"
cp "$executable" "$macos/editor"

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
  list_root "$package" Editor | copy_listed "$package" "$staged_editor"
else
  toolchain_list=$(mktemp "$bundle/.toolchain.XXXXXX")
  editor_list=$(mktemp "$bundle/.editor.XXXXXX")
  while IFS= read -r module || [ -n "$module" ]; do
    [ -n "$module" ] || continue
    path=$(printf '%s' "$module" | tr . /)
    if [ -e "$toolchain_lib/$path.olean" ]; then
      from=$toolchain_lib
      list=$toolchain_list
    elif [ -e "$package/$path.olean" ]; then
      from=$package
      list=$editor_list
    else
      echo "stage-bundle: no .olean file for $module in $toolchain_lib or $package" >&2
      exit 1
    fi
    for kind in "${kinds[@]}"; do
      if [ -e "$from/$path.$kind" ]; then echo "$path.$kind" >>"$list"; fi
    done
  done <"$closure"
  copy_listed "$toolchain_lib" "$staged_toolchain" <"$toolchain_list"
  copy_listed "$package" "$staged_editor" <"$editor_list"
  rm -f "$toolchain_list" "$editor_list"
fi
