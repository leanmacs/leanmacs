#!/usr/bin/env bash
# Writes the link stubs a relink of the editor needs where there is no macOS
# SDK (docs/design/lean-runtime.md, "A link on the user's machine,
# measured"): `tools/user-link-check.sh` stages them, and the app's build
# will.
#
#   tools/link-stubs.sh <linked executable> <out dir>
#
# For each dynamic library the executable loads (`otool -L`), other than
# `libSystem` and `libc++`, which the Lean toolchain ships a stub and a
# stand-in for, it writes one text stub (`.tbd`, version 4) holding
#
# - the library's install name and its current and compatibility versions,
#   as the executable records them, and
# - only the symbols the executable imports from it (`nm -m -u`, which
#   names the library each undefined symbol is bound to).
#
# A framework's stub is `<out dir>/<name>.framework/<name>.tbd`, found with
# `-F <out dir> -framework <name>`; a library's is `<out dir>/lib<name>.tbd`,
# found with `-L <out dir> -l<name>`. A library the executable loads and
# imports nothing from still gets its stub, with no symbols, so a link that
# names it finds it.
#
# It also writes `<out dir>/platform-version`, one line, `<minos> <sdk>`:
# the minimum macOS and the SDK version the executable records (`vtool
# -show-build`). A linker with no SDK records the minimum macOS as the SDK
# version too, and AppKit and other frameworks choose behaviour by the SDK
# version an executable was linked against, so a relink passes these two on
# (`-platform_version macos <minos> <sdk>`) and is the same build to them.
#
# So the stubs are made from the executable's own import table, by the
# build that linked it against the SDK, and no file of the SDK is copied. A
# relink that needs a symbol the executable never imported does not find
# it: the stubs serve relinking the same compiled code, not new calls into
# the system.
#
# It refuses, naming the symbol, an import bound to a library the
# executable does not load, and an Objective-C class, metaclass, instance
# variable or exception type symbol (`_OBJC_…_$_…`): a text stub lists those
# apart from plain symbols, the editor imports none, and so that form is
# not written here, untried.
#
# It runs on the machine that built the executable: `otool`, `nm`, `lipo`
# and `vtool` are the command line tools'. macOS only.
set -euo pipefail

if [ "$(uname -s)" != Darwin ]; then
  echo "link-stubs: macOS only (this is $(uname -s))" >&2
  exit 2
fi
if [ $# -ne 2 ]; then
  echo "usage: tools/link-stubs.sh <linked executable> <out dir>" >&2
  exit 2
fi

executable=$1
out=$2

fail() {
  echo "link-stubs: $*" >&2
  exit 1
}

[ -f "$executable" ] || fail "no executable at $executable"

archs=$(lipo -archs "$executable")
case "$archs" in
  *" "*) fail "$executable holds more than one architecture ($archs)" ;;
esac
target="$archs-macos"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The name `nm -m` gives a library: a framework's name, or a library's file
# name up to its first dot (`libobjc` for `/usr/lib/libobjc.A.dylib`).
short_name() {
  case "$1" in
    */*.framework/*) printf '%s\n' "$1" | sed 's|.*/\([^/]*\)\.framework/.*|\1|' ;;
    *) basename "$1" | sed 's/\..*//' ;;
  esac
}

# One line a library: its install name, its compatibility version and its
# current version.
otool -L "$executable" |
  sed -n 's/^[[:space:]]*\(.*\) (compatibility version \([0-9.]*\), current version \([0-9.]*\))$/\1 \2 \3/p' >"$work/libraries"
[ -s "$work/libraries" ] || fail "otool -L lists no library for $executable"

# One line an import: the library's name, then the symbol.
nm -m -u "$executable" | sed -n 's/^.* external \([^ ]*\) (from \(.*\))$/\2 \1/p' >"$work/imports"
unread=$(nm -m -u "$executable" | grep -c -v ' external [^ ]* (from .*)$' || true)
[ "$unread" -eq 0 ] ||
  fail "$unread undefined symbols of $executable are not of the form nm -m prints for an import bound to a library"

mkdir -p "$out"
: >"$work/names"
while read -r install compatibility current; do
  name=$(short_name "$install")
  printf '%s\n' "$name" >>"$work/names"
  case "$name" in
    libSystem | libc++) continue ;;
  esac
  case "$install" in
    */*.framework/*)
      mkdir -p "$out/$name.framework"
      stub="$out/$name.framework/$name.tbd"
      ;;
    *) stub="$out/$name.tbd" ;;
  esac
  awk -v name="$name" '$1 == name { print $2 }' "$work/imports" | sort -u >"$work/symbols"
  if grep -q '^_OBJC_[A-Z]*_\$_' "$work/symbols"; then
    fail "$(grep '^_OBJC_[A-Z]*_\$_' "$work/symbols" | head -n 1), imported from $name, is an Objective-C symbol, which a text stub lists apart; this script does not write that form"
  fi
  {
    echo "--- !tapi-tbd"
    echo "tbd-version:     4"
    echo "targets:         [ $target ]"
    echo "install-name:    '$install'"
    echo "current-version: $current"
    echo "compatibility-version: $compatibility"
    if [ -s "$work/symbols" ]; then
      echo "exports:"
      echo "  - targets:         [ $target ]"
      printf '    symbols:         [ '
      sed "s/.*/'&'/" "$work/symbols" | paste -s -d , - | sed 's/,/, /g' | tr -d '\n'
      echo " ]"
    fi
    echo "..."
  } >"$stub"
done <"$work/libraries"

# The minimum macOS and the SDK version the executable records.
minos=$(vtool -show-build "$executable" | awk '$1 == "minos" { print $2; exit }')
sdk=$(vtool -show-build "$executable" | awk '$1 == "sdk" { print $2; exit }')
[ -n "$minos" ] && [ -n "$sdk" ] || fail "$executable records no minimum macOS and SDK version"
echo "$minos $sdk" >"$out/platform-version"

# Every import is bound to a library the executable loads.
cut -d' ' -f1 "$work/imports" | sort -u | while read -r name; do
  grep -qxF "$name" "$work/names" ||
    fail "$(awk -v name="$name" '$1 == name { print $2; exit }' "$work/imports") is imported from $name, which otool -L does not list"
done
