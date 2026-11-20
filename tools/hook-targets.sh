#!/bin/sh
# Decides what the pre-commit hook's Lean step runs for a staged change
# (docs/dev-practices/the-gate.md, "The pre-commit hook"): nothing, the
# checks of some packages, or the core's whole chain. `tools/lean-hook.sh`
# runs what it decides; the decision is all here.
#
#   tools/hook-targets.sh <set dir> <path>...
#   tools/hook-targets.sh --lines <file> --root <dir> <path>...
#
# Run it in `lean/`. The paths are the staged files, relative to the
# repository's root, as hk hands them to a step. The package graph is the
# set's (`lake -d <set dir> query :editorPackageGraph`, a facet the core
# defines in `lean/lakefile.lean`), one line a package of the set, the core
# not among them, its fields separated by tabs:
#
#   <name>	<layer>	<absolute directory>	<required packages, space-separated, or ->
#
# in the set's order, each after the packages it requires. The layer is
# `interface` or `implementation` (docs/design/extension-points.md, "Three
# layers"), and the required packages are those of the set the package
# requires directly. The root the directories are under is the
# repository's (`git rev-parse --show-toplevel`). With `--lines`, the lines
# are read from a file and the root is given instead: the gate hands it a
# graph written by hand (tests/hook-targets/).
#
# The rule, for each path, the reach of every path then unioned; this
# script chooses the paths and turns Lake's graph into the lines the
# decision shared with the Rust hook reads, and that decision is
# tools/graph-targets.sh's:
#
# - A path no Lean step reads reaches nothing: one outside `lean/`,
#   `packages/`, `tests/`, `config/`, a directory under `docs/packages/`
#   (where the example package of the guide to writing a package lives,
#   `docs/packages/word-count/`, which the fixture set requires),
#   `mise.toml`, a `Cargo.toml`, `Cargo.lock`, Rust and C sources, and this
#   hook's own tools (`tools/hook-targets.sh`, `tools/graph-targets.sh`,
#   `tools/lean-hook.sh`, `tools/package-set.sh`). The guides themselves,
#   files directly in `docs/packages/`, are docs.
#   hk.pkl's `lean` step lists the same patterns, so a commit of docs or
#   plans alone does not run the step at all.
# - A path inside a package's directory (the longest that holds it, so a
#   package nested in another's directory is found) reaches that package;
#   if it is an interface package, also every package that requires it,
#   directly or through any other package: Lake puts every package a
#   package requires, directly or not, in its workspace, so a package can
#   import an interface package it reaches only through an implementation
#   package's `require`, and the layer imports check allows that import. A
#   change to an implementation package reaches that package alone: no
#   package imports one (the layer imports check), so a change to one
#   cannot break another's build.
# - Any other path reaches the core, and so everything: the core's sources,
#   a set's own lakefile and manifest, the core's fixtures under `tests/`,
#   `config/`, Rust and C outside a package, and this hook's own tools.
#
# It prints nothing when nothing is reached, the line `core` when the core
# is, and otherwise a line `package <name>` for each package reached, in
# the graph's order (tools/graph-targets.sh's output, with the fallback
# `core` and the label `package`). It reads no lakefile and no source text, and asks Lake
# nothing when no path is one a Lean step reads. It exits 2, so that it
# cannot pass by deciding over nothing, for a command line it does not
# take, for no path, when Lake fails the query, for a graph that holds no
# line, a line that is not four fields, a layer it does not know, or a
# required package that is no line of the graph.
set -eu

usage() {
  echo "usage: tools/hook-targets.sh <set dir> <path>..." >&2
  echo "       tools/hook-targets.sh --lines <file> --root <dir> <path>..." >&2
  exit 2
}

lines_file=
set_dir=
root=
case ${1-} in
  --lines)
    [ "$#" -ge 4 ] && [ "$3" = --root ] || usage
    lines_file=$2
    root=$4
    shift 4
    ;;
  '' | -*) usage ;;
  *)
    set_dir=$1
    shift
    ;;
esac
if [ "$#" -eq 0 ]; then
  echo "hook-targets: no path given, so there is nothing to decide" >&2
  exit 2
fi

# The paths a Lean step reads, one a line.
relevant=
for path in "$@"; do
  case $path in
    lean/* | packages/* | tests/* | config/* | docs/packages/*/* | mise.toml | Cargo.lock | Cargo.toml | \
      */Cargo.toml | \
      *.rs | *.c | *.h | *.cc | *.cpp | *.hpp | \
      tools/hook-targets.sh | tools/graph-targets.sh | tools/lean-hook.sh | tools/package-set.sh)
      relevant="$relevant$path
"
      ;;
  esac
done
[ -n "$relevant" ] || exit 0

if [ -n "$lines_file" ]; then
  if [ ! -f "$lines_file" ]; then
    echo "hook-targets: no file $lines_file" >&2
    exit 2
  fi
  graph=$(cat "$lines_file")
  source=$lines_file
else
  if [ ! -d "$set_dir" ]; then
    echo "hook-targets: no directory $set_dir" >&2
    exit 2
  fi
  root=$(git rev-parse --show-toplevel) || {
    echo "hook-targets: not in a git repository, so the paths have no root" >&2
    exit 2
  }
  graph=$(lake -d "$set_dir" query :editorPackageGraph) || {
    echo "hook-targets: lake -d $set_dir query :editorPackageGraph failed" >&2
    exit 2
  }
  source=$set_dir
fi
if [ -z "$graph" ]; then
  echo "hook-targets: $source holds no package line, so there is nothing to decide over" >&2
  exit 2
fi

tab=$(printf '\t')
# The graph as the shared decision reads it (tools/graph-targets.sh): an
# interface package propagates, an implementation package does not. A
# line that is not four fields or has a layer this does not know is
# refused here, where the layers are known.
normalized=$(printf '%s\n' "$graph" | awk -F "$tab" '
  {
    if (NF != 4 || $1 == "" || $3 == "" || $4 == "") {
      print "hook-targets: not a line of four fields: " $0 > "/dev/stderr"
      exit 2
    }
    if ($2 != "interface" && $2 != "implementation") {
      print "hook-targets: the package " $1 " is in the layer `" $2 "`; a package is interface or implementation" > "/dev/stderr"
      exit 2
    }
    print $1 "\t" $3 "\t" ($2 == "interface" ? "yes" : "no") "\t" $4
  }
') || exit 2

# The relevant paths, one a line, become the decision's arguments.
set --
while IFS= read -r path; do
  [ -n "$path" ] && set -- "$@" "$path"
done <<PATHS
$relevant
PATHS
printf '%s\n' "$normalized" | sh "$(dirname "$0")/graph-targets.sh" --lines - --root "$root" --fallback core --label package "$@"
