#!/bin/sh
# Checks the three-layer import rule on Lake's module graph
# (docs/design/extension-points.md, "Three layers"): the core imports no
# package, and no package imports a module of an implementation package.
# What one feature needs of another goes through an interface package, so
# any implementation package can be left out of a set or replaced.
#
#   tools/layer-imports-check.sh <set dir>
#   tools/layer-imports-check.sh --lines <file>
#
# Run it in `lean/`. The set's directory holds the set's lakefile. It asks
# Lake (`lake -d <set dir> query :editorLayerImports`, a facet the core
# defines in `lean/lakefile.lean`) and reads no source text: for the core
# and each package of the set, one line for each direct import, by a module
# of one of its libraries, of a module of a package of the workspace, its
# own package included, its fields separated by tabs:
#
#   <package>	<layer>	<module>	<imported package>	<imported layer>	<imported module>
#
# The layer is `core` (the core's Lake package), `interface` (a package
# whose lakefile declares `keywords = ["editor-interface"]`) or
# `implementation` (every other package: a misspelt keyword makes a package
# more refused, never less). Lake resolves the imports from the modules'
# headers and builds nothing. With `--lines`, the lines are read from a
# file instead: the gate hands the rule lines written by hand, one for each
# of its branches, to see each hold or bite (tests/layer-imports/).
#
# The rule, for every module of a package, its test modules and its linked
# test included (a test that imports another feature's implementation would
# stop building when that feature is left out; it uses the interface
# package's fake instead):
#
# - an import within one package is allowed;
# - the core imports nothing of any package;
# - no package, interface or implementation, imports a module of an
#   implementation package;
# - everything else is allowed: a package imports the core (what of the
#   core is the package imports check's business,
#   tools/package-imports-check.sh) and interface packages.
#
# Like the package imports check, the rule is about `import` lines, direct
# imports alone.
#
# It prints nothing and exits 0 when every import is allowed. Otherwise it
# prints each refused import, one a line, with the importing package and
# its layer, both modules, the imported package and its layer, and why, and
# exits 1. It exits 2, so that it cannot pass by checking nothing, for a
# command line it does not take, when Lake fails the query, for a line that
# is not six fields, for a layer it does not know, when there is no line,
# and when no line has a module of the core as the importer: every set
# requires the core, so such input means the core's modules were not
# walked, and the core's half of the rule would hold of nothing.
set -eu

usage() {
  echo "usage: tools/layer-imports-check.sh <set dir>" >&2
  echo "       tools/layer-imports-check.sh --lines <file>" >&2
  exit 2
}

case $# in
  1)
    case $1 in
      '' | -*) usage ;;
    esac
    if [ ! -d "$1" ]; then
      echo "layer-imports-check: no directory $1" >&2
      exit 2
    fi
    lines=$(lake -d "$1" query :editorLayerImports) || {
      echo "layer-imports-check: lake -d $1 query :editorLayerImports failed" >&2
      exit 2
    }
    source=$1
    ;;
  2)
    [ "$1" = --lines ] || usage
    if [ ! -f "$2" ]; then
      echo "layer-imports-check: no file $2" >&2
      exit 2
    fi
    lines=$(cat "$2")
    source=$2
    ;;
  *) usage ;;
esac

if [ -z "$lines" ]; then
  echo "layer-imports-check: $source holds no line, so there is nothing to check" >&2
  exit 2
fi

tab=$(printf '\t')

# One pass of awk first: it refuses a line that is not six fields or has a
# layer it does not know (exit 2, naming the line), counts the lines whose
# importer is a module of the core, and drops every import within one
# package, which the rule allows. The core's own imports are most of the
# graph, so the shell loop below reads only the imports across packages.
across=$(printf '%s\n' "$lines" | awk -F "$tab" '
  function known(layer) {
    return layer == "core" || layer == "interface" || layer == "implementation"
  }
  {
    if (NF != 6 || $1 == "" || $3 == "" || $4 == "" || $6 == "") {
      print "layer-imports-check: not a line of six fields: " $0 > "/dev/stderr"
      bad = 1
      exit 2
    }
    if (!known($2) || !known($5)) {
      print "layer-imports-check: " $3 " of " $1 " is in the layer `" $2 "` and imports " $6 " of " $4 " in the layer `" $5 "`; a layer is core, interface or implementation" > "/dev/stderr"
      bad = 1
      exit 2
    }
    if ($2 == "core") core++
    if ($1 != $4) print
  }
  END {
    if (bad) exit 2
    if (!core) exit 3
  }
') || {
  status=$?
  if [ "$status" -eq 3 ]; then
    echo "layer-imports-check: no module of the core is an importer in $source, so the core is not checked" >&2
  fi
  exit 2
}

refused=0
# The lines are read on a descriptor of their own, as the package steps
# read theirs (tools/package-set.sh).
while IFS=$tab read -r package layer module imported_package imported_layer imported <&3; do
  [ -n "$package" ] || continue
  reason=
  if [ "$layer" = core ]; then
    reason="the core imports no package"
  elif [ "$imported_layer" = implementation ]; then
    reason="a module of an implementation package, which no package imports"
  fi
  if [ -n "$reason" ]; then
    echo "layer-imports-check: $package ($layer): $module imports $imported of $imported_package ($imported_layer): $reason"
    refused=1
  fi
done 3<<LINES
$across
LINES

exit "$refused"
