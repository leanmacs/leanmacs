#!/bin/sh
# Which nodes of a graph a set of staged paths reaches: the decision both
# pre-commit hooks share (docs/dev-practices/the-gate.md, "The pre-commit
# hook"). Its adapters, tools/hook-targets.sh (Lean packages, from Lake's
# graph) and tools/rust-targets.sh (crates, from Cargo's), each choose the
# paths their step reads and turn their tool's graph into the lines below.
#
#   tools/graph-targets.sh --lines <file> --root <dir> --fallback <word> --label <word> <path>...
#
# The graph is one line a node, `-` for <file> reading it from standard
# input, its fields separated by tabs:
#
#   <name>	<absolute directory>	<propagates: yes or no>	<names it requires, space-separated, or ->
#
# The paths are relative to <dir>, the root the directories are under. The
# rule, for each path, the reach of every path then unioned:
#
# - A path inside a node's directory (the longest that holds it, so a node
#   nested in another's directory is found) reaches that node; if the node
#   propagates, also every node that requires it, directly or through any
#   other node, whether that one propagates or not.
# - Any other path reaches the fallback. A node outside the root holds no
#   path.
#
# It prints the line <fallback> when the fallback is reached, and otherwise
# a line `<label> <name>` for each node reached, in the graph's order. It
# reads nothing but the graph. It exits 2, so that it cannot pass by
# deciding over nothing, for a command line it does not take, for no path,
# for a graph that holds no line, a line that is not four fields, a
# propagates field that is neither `yes` nor `no`, or a required name that
# is no line of the graph.
set -eu

usage() {
  echo "usage: tools/graph-targets.sh --lines <file> --root <dir> --fallback <word> --label <word> <path>..." >&2
  exit 2
}

[ "$#" -ge 8 ] && [ "$1" = --lines ] && [ "$3" = --root ] && [ "$5" = --fallback ] && [ "$7" = --label ] || usage
lines_file=$2
root=$4
fallback=$6
label=$8
shift 8
if [ "$#" -eq 0 ]; then
  echo "graph-targets: no path given, so there is nothing to decide" >&2
  exit 2
fi

if [ "$lines_file" = - ]; then
  graph=$(cat)
elif [ -f "$lines_file" ]; then
  graph=$(cat "$lines_file")
else
  echo "graph-targets: no file $lines_file" >&2
  exit 2
fi
if [ -z "$graph" ]; then
  echo "graph-targets: the graph holds no $label line, so there is nothing to decide over" >&2
  exit 2
fi

paths=
for path in "$@"; do
  paths="$paths$path
"
done

tab=$(printf '\t')
# The paths reach awk through the environment, which, unlike `-v`, keeps
# a backslash as it is.
printf '%s\n' "$graph" | GRAPH_PATHS=$paths awk -F "$tab" -v root="$root" -v fallback="$fallback" -v label="$label" '
  {
    if (NF != 4 || $1 == "" || $2 == "" || $4 == "") {
      print "graph-targets: not a line of four fields: " $0 > "/dev/stderr"
      bad = 1
      exit 2
    }
    if ($3 != "yes" && $3 != "no") {
      print "graph-targets: the " label " " $1 " propagates `" $3 "`; it is yes or no" > "/dev/stderr"
      bad = 1
      exit 2
    }
    n++
    name[n] = $1
    dir[$1] = $2
    propagates[$1] = $3
    requires[$1] = $4
  }

  # Marks `node` reached and every node that requires it, directly or
  # through another.
  function reachRequirers(node,    k, by, j) {
    if (node in reached) return
    reached[node] = 1
    k = split(requirers[node], by, " ")
    for (j = 1; j <= k; j++) reachRequirers(by[j])
  }

  END {
    if (bad) exit 2
    for (i = 1; i <= n; i++) {
      if (requires[name[i]] == "-") continue
      k = split(requires[name[i]], req, " ")
      for (j = 1; j <= k; j++) {
        if (!(req[j] in dir)) {
          print "graph-targets: " name[i] " requires " req[j] ", which is no " label " of the graph" > "/dev/stderr"
          exit 2
        }
        requirers[req[j]] = requirers[req[j]] " " name[i]
      }
    }
    # Each node directory relative to the root, with a slash after it.
    prefix = root "/"
    for (i = 1; i <= n; i++) {
      d = dir[name[i]]
      if (substr(d, 1, length(prefix)) == prefix) rel[name[i]] = substr(d, length(prefix) + 1) "/"
    }
    m = split(ENVIRON["GRAPH_PATHS"], paths, "\n")
    for (p = 1; p <= m; p++) {
      if (paths[p] == "") continue
      best = ""
      for (i = 1; i <= n; i++) {
        if (!(name[i] in rel)) continue
        r = rel[name[i]]
        if (substr(paths[p], 1, length(r)) == r && (best == "" || length(r) > length(rel[best]))) best = name[i]
      }
      if (best == "") reachedFallback = 1
      else if (propagates[best] == "yes") reachRequirers(best)
      else reached[best] = 1
    }
    if (reachedFallback) {
      print fallback
      exit 0
    }
    for (i = 1; i <= n; i++) if (name[i] in reached) print label " " name[i]
  }
'
