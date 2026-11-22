#!/bin/sh
# Builds a package set without each of its implementation packages, one at
# a time (docs/design/packages.md, "The package set and its build";
# docs/dev-practices/the-gate.md, "The leave-out check"): for each
# implementation package of the set, an editor built from the set without
# that package builds, and holds every other package of the set and not
# that one.
#
#   tools/leave-out-check.sh <set dir>
#   tools/leave-out-check.sh --dry-run <package> [--root <dir>] <set dir>
#
# Run it in `lean/`. The set's directory holds the set's lakefile, a
# `lakefile.toml` whose `[[require]]`s are the set.
#
# For each implementation package of the set, in the set's order (`lake -d
# <set dir> query :editorPackageGraph`, a facet the core defines in
# `lean/lakefile.lean`: a package's name, its layer, its directory and what
# it requires, separated by tabs), it:
#
# 1. writes, in a fresh temporary directory, the set's lakefile without
#    that package's `[[require]]` and with every relative `path` made
#    absolute (the dry run's text, below), beside a copy of the set's
#    `lean-toolchain`;
# 2. runs `lake update --keep-toolchain` and `lake build --wfail :editor`
#    there: the set's root is generated, built and linked, and the
#    packages themselves are built where they are;
# 3. requires the generated root's imports (`:editorRootImports`) to be the
#    set's own without that package's entry module, and no other: every
#    other entry module, in the set's order, and not that one. A package
#    that another package of the set requires is still in the set once its
#    own `[[require]]` is gone, and fails here;
# 4. runs the editor it built with `--probe`, and prints one line,
#    `leave-out: <package>: built, <the probe's first line>`: `probe: ok`,
#    or why the editor refuses to start, as an editor with no input scheme
#    does. A refusal is no failure: the criterion is that the editor
#    builds.
#
# It exits 0 when every such editor built and held what it should. It
# exits 1, after `leave-out: <package>: …` on stderr with why, at the
# first package whose set does not update or build, or whose root is not
# the set's without it. It exits 2 for a command line it does not take,
# when Lake fails a query, when the set holds no implementation package,
# so that it cannot pass by building nothing, and when the set's lakefile
# has no `[[require]]` of a package it is to leave out: a package the set
# reaches only through another set cannot be left out by an edit of this
# lakefile.
#
# With `--dry-run <package>` it builds nothing and asks Lake nothing: it
# prints the set's lakefile without that package's `[[require]]`, with
# every relative `path` made absolute against `--root <dir>`, the set's
# own directory when none is given. The edit is of the text alone:
#
# - a `[[require]]` is the line `[[require]]` and the `key = value` lines
#   after it, up to the first line that is blank, a comment or another
#   table; the comment lines directly above it, with no blank line
#   between, are its own and go with it, and so does one blank line after
#   it, or, at the end of the file, one before it;
# - a `path = "<relative>"` line anywhere in what is left is rewritten
#   with the path resolved against the root, `.` and `..` folded.
#
# The gate holds the edit by dry runs over a lakefile written by hand
# (tests/leave-out/, in `mise run lean-test`). The builds are opt-in
# (`mise run leave-out`): one linked editor a package.
set -eu

usage() {
  echo "usage: tools/leave-out-check.sh <set dir>" >&2
  echo "       tools/leave-out-check.sh --dry-run <package> [--root <dir>] <set dir>" >&2
  exit 2
}

dry=
root=
case ${1:-} in
  --dry-run)
    [ "$#" -ge 3 ] || usage
    dry=$2
    shift 2
    if [ "$1" = --root ]; then
      [ "$#" -eq 3 ] || usage
      root=$2
      shift 2
    fi
    ;;
esac
[ "$#" -eq 1 ] || usage
case $1 in
  '' | -*) usage ;;
esac
set_dir=$1
if [ ! -f "$set_dir/lakefile.toml" ]; then
  echo "leave-out-check: no lakefile.toml in $set_dir" >&2
  exit 2
fi

# The lakefile `$1` without the `[[require]]` of the package `$2`, its
# relative paths made absolute against `$3`. Status 2, and nothing printed,
# when the lakefile has no such `[[require]]`.
without() {
  awk -v package="$2" -v root="$3" '
    # `path`, resolved against the root when it is relative, with `.` and
    # `..` folded.
    function resolved(path,    full, count, parts, depth, kept, index_, out) {
      full = (path ~ /^\//) ? path : root "/" path
      count = split(full, parts, "/")
      depth = 0
      for (index_ = 1; index_ <= count; index_++) {
        if (parts[index_] == "" || parts[index_] == ".") continue
        if (parts[index_] == "..") { if (depth > 0) depth--; continue }
        kept[++depth] = parts[index_]
      }
      out = ""
      for (index_ = 1; index_ <= depth; index_++) out = out "/" kept[index_]
      return out == "" ? "/" : out
    }
    { lines[NR] = $0 }
    END {
      first = 0
      for (at = 1; at <= NR; at++) {
        if (lines[at] != "[[require]]") continue
        last = at
        named = ""
        while (last < NR && lines[last + 1] ~ /^[A-Za-z_][A-Za-z0-9_-]*[ \t]*=/) {
          last++
          if (lines[last] ~ /^name[ \t]*=[ \t]*"[^"]*"[ \t]*$/) {
            named = lines[last]
            sub(/^name[ \t]*=[ \t]*"/, "", named)
            sub(/"[ \t]*$/, "", named)
          }
        }
        if (named == package) {
          first = at
          while (first > 1 && lines[first - 1] ~ /^#/) first--
          if (last < NR && lines[last + 1] == "") last++
          else if (last == NR && first > 1 && lines[first - 1] == "") first--
          break
        }
      }
      if (first == 0) exit 2
      for (at = 1; at <= NR; at++) {
        if (at >= first && at <= last) continue
        line = lines[at]
        if (line ~ /^path[ \t]*=[ \t]*"[^"]*"[ \t]*$/) {
          value = line
          sub(/^path[ \t]*=[ \t]*"/, "", value)
          sub(/"[ \t]*$/, "", value)
          line = "path = \"" resolved(value) "\""
        }
        print line
      }
    }' "$1"
}

if [ -n "$dry" ]; then
  [ -n "$root" ] || root=$(cd "$set_dir" && pwd -P)
  status=0
  without "$set_dir/lakefile.toml" "$dry" "$root" || status=$?
  if [ "$status" -ne 0 ]; then
    echo "leave-out-check: the lakefile of $set_dir has no [[require]] of $dry" >&2
    exit 2
  fi
  exit 0
fi

# A query Lake fails is status 2, never 1: 1 says a set without a package
# did not build, or held what it should not.
asked() {
  lake -d "$1" query "$2" || {
    echo "leave-out-check: lake -d $1 query $2 failed" >&2
    exit 2
  }
}

# As `asked`, of the set built in `$1`, with what Lake says on stderr
# shown only when the query fails: after a build Lake replays the build's
# log there.
asked_quietly() {
  lake -d "$1" query "$2" 2>"$work/query.err" || {
    cat "$work/query.err" >&2
    echo "leave-out-check: lake -d $1 query $2 failed" >&2
    exit 2
  }
}

# The entry module of the package named `$1`: its name in upper camel
# case, then `EditorPackage`, as the build names it (`entryModuleName`,
# `lean/lakefile.lean`).
entry_of() {
  printf '%s\n' "$1" | awk -F- '{
    out = ""
    for (part = 1; part <= NF; part++) out = out toupper(substr($part, 1, 1)) substr($part, 2)
    print out ".EditorPackage"
  }'
}

tab=$(printf '\t')
root=$(cd "$set_dir" && pwd -P)
graph=$(asked "$set_dir" :editorPackageGraph) || exit 2
packages=$(printf '%s\n' "$graph" | awk -F"$tab" '$2 == "implementation" { print $1 }')
if [ -z "$packages" ]; then
  echo "leave-out-check: the set in $set_dir holds no implementation package, so there is nothing to leave out" >&2
  exit 2
fi
whole=$(asked "$set_dir" :editorRootImports) || exit 2

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

for package in $packages; do
  dir=$work/$package
  mkdir "$dir"
  status=0
  without "$set_dir/lakefile.toml" "$package" "$root" >"$dir/lakefile.toml" || status=$?
  if [ "$status" -ne 0 ]; then
    echo "leave-out-check: the lakefile of $set_dir has no [[require]] of $package, a package of the set: it reaches the set through another package, so it cannot be left out by an edit of this lakefile" >&2
    exit 2
  fi
  cp "$set_dir/lean-toolchain" "$dir/lean-toolchain"
  if ! out=$(lake -d "$dir" update --keep-toolchain 2>&1); then
    printf '%s\n' "$out" >&2
    echo "leave-out: $package: the set without it does not resolve" >&2
    exit 1
  fi
  if ! out=$(lake -d "$dir" build --wfail :editor 2>&1); then
    printf '%s\n' "$out" >&2
    echo "leave-out: $package: the set without it does not build" >&2
    exit 1
  fi
  entry=$(entry_of "$package")
  expected=$(printf '%s\n' "$whole" | grep -vxF "$entry" || true)
  imported=$(asked_quietly "$dir" :editorRootImports) || exit 2
  if [ "$imported" != "$expected" ]; then
    echo "leave-out: $package: the root of the set without it does not import the set's other entry modules and no other; it imports:" >&2
    printf '%s\n' "$imported" >&2
    exit 1
  fi
  editor=$(asked_quietly "$dir" :editor) || exit 2
  probe=$("$editor" --probe 2>&1 | head -n 1) || true
  echo "leave-out: $package: built, $probe"
  rm -rf "$dir"
done
