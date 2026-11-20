#!/bin/sh
# Decides what the pre-commit hook's Rust step runs for a staged change
# (docs/dev-practices/the-gate.md, "The pre-commit hook"): nothing, the
# lint and tests of some crates, or of the whole workspace.
# `tools/rust-hook.sh` runs what it decides; the decision is all here.
#
#   tools/rust-targets.sh <path>...
#   tools/rust-targets.sh --lines <file> --root <dir> <path>...
#   tools/rust-targets.sh --print-graph
#
# Run it at the repository's root. The paths are the staged files, relative
# to the repository's root, as hk hands them to a step. The crate graph is
# Cargo's (`cargo metadata --no-deps`, read with yq), one line a crate of
# the workspace, its fields separated by tabs:
#
#   <name>	<absolute directory>	<crates of the workspace it depends on, space-separated, or ->
#
# in Cargo's order; the dependencies are direct and of every kind (normal,
# dev, build). With `--lines`, the lines are read from a file and the root
# the directories are under is given: the gate hands it a graph written by
# hand (tests/rust-targets/). `--print-graph` prints Cargo's graph as the
# decision reads it, and decides nothing.
#
# The rule, for each path, the reach of every path then unioned:
#
# - A path the Rust step does not read reaches nothing: one that is not a
#   Rust source, a `Cargo.toml`, `Cargo.lock`, a `clippy.toml`, `mise.toml`
#   or this hook's own tools and fixtures (`tools/rust-targets.sh`,
#   `tools/rust-hook.sh`, `tests/rust-targets/`). hk.pkl's `rust` step
#   lists the same patterns.
# - A path inside a crate's directory (the longest that holds it) reaches
#   that crate and every crate that depends on it, directly or through
#   another: a change to a crate can break the build or the tests of any
#   crate that uses it, and of no other.
# - Any other path reaches the whole workspace: `Cargo.lock`, the
#   workspace's `Cargo.toml`, `mise.toml` (the toolchain), a Rust file in
#   no crate, this hook's own tools and fixtures, whose checks are in
#   `mise run test`.
#
# It prints nothing when nothing is reached, the line `workspace` when the
# workspace is, and otherwise a line `crate <name>` for each crate reached,
# in the graph's order. It exits 2, so that it cannot pass by deciding over
# nothing, for a command line it does not take, for no path, when Cargo or
# yq fails, for a graph that holds no line, a line that is not three
# fields, or a dependency that is no line of the graph.
set -eu

usage() {
  echo "usage: tools/rust-targets.sh <path>..." >&2
  echo "       tools/rust-targets.sh --lines <file> --root <dir> <path>..." >&2
  echo "       tools/rust-targets.sh --print-graph" >&2
  exit 2
}

# Cargo's graph, in the lines above: for each crate, its name, its
# directory (its manifest's) and the names of the workspace's crates among
# its dependencies.
cargo_graph() {
  metadata=$(cargo metadata --format-version 1 --no-deps --locked) || {
    echo "rust-targets: cargo metadata failed" >&2
    exit 2
  }
  printf '%s\n' "$metadata" | yq -p json -o tsv '(.packages | map(.name)) as $ws | .packages[] | [.name, (.manifest_path | sub("/Cargo.toml$"; "")), ([.dependencies[].name | select(. as $d | $ws | any_c(. == $d))] | unique | join(" ") | sub("^$"; "-"))]' || {
    echo "rust-targets: yq could not read cargo metadata's output" >&2
    exit 2
  }
}

lines_file=
root=
case ${1-} in
  --lines)
    [ "$#" -ge 4 ] && [ "$3" = --root ] || usage
    lines_file=$2
    root=$4
    shift 4
    ;;
  --print-graph)
    [ "$#" -eq 1 ] || usage
    cargo_graph
    exit 0
    ;;
  -*) usage ;;
esac
if [ "$#" -eq 0 ]; then
  echo "rust-targets: no path given, so there is nothing to decide" >&2
  exit 2
fi

# The paths the Rust step reads, one a line.
relevant=
for path in "$@"; do
  case $path in
    *.rs | Cargo.toml | */Cargo.toml | Cargo.lock | clippy.toml | */clippy.toml | mise.toml | \
      tools/rust-targets.sh | tools/rust-hook.sh | tests/rust-targets/*)
      relevant="$relevant$path
"
      ;;
  esac
done
[ -n "$relevant" ] || exit 0

if [ -n "$lines_file" ]; then
  if [ ! -f "$lines_file" ]; then
    echo "rust-targets: no file $lines_file" >&2
    exit 2
  fi
  graph=$(cat "$lines_file")
  source=$lines_file
else
  root=$(git rev-parse --show-toplevel) || {
    echo "rust-targets: not in a git repository, so the paths have no root" >&2
    exit 2
  }
  graph=$(cargo_graph) || exit 2
  source="cargo metadata"
fi
if [ -z "$graph" ]; then
  echo "rust-targets: $source holds no crate line, so there is nothing to decide over" >&2
  exit 2
fi

tab=$(printf '\t')
# The paths reach awk through the environment, which, unlike `-v`, keeps
# a backslash as it is.
printf '%s\n' "$graph" | RUST_PATHS=$relevant awk -F "$tab" -v root="$root" '
  {
    if (NF != 3 || $1 == "" || $2 == "" || $3 == "") {
      print "rust-targets: not a line of three fields: " $0 > "/dev/stderr"
      bad = 1
      exit 2
    }
    n++
    name[n] = $1
    dir[$1] = $2
    deps[$1] = $3
  }

  # Marks `crate` reached, and every crate that depends on it.
  function reach(crate,    k, by, j) {
    if (crate in reached) return
    reached[crate] = 1
    k = split(dependents[crate], by, " ")
    for (j = 1; j <= k; j++) reach(by[j])
  }

  END {
    if (bad) exit 2
    for (i = 1; i <= n; i++) {
      if (deps[name[i]] == "-") continue
      k = split(deps[name[i]], dep, " ")
      for (j = 1; j <= k; j++) {
        if (!(dep[j] in dir)) {
          print "rust-targets: " name[i] " depends on " dep[j] ", which is no crate of the graph" > "/dev/stderr"
          exit 2
        }
        dependents[dep[j]] = dependents[dep[j]] " " name[i]
      }
    }
    # Each crate directory relative to the root, with a slash after it; a
    # crate outside the repository holds no staged path.
    prefix = root "/"
    for (i = 1; i <= n; i++) {
      d = dir[name[i]]
      if (substr(d, 1, length(prefix)) == prefix) rel[name[i]] = substr(d, length(prefix) + 1) "/"
    }
    m = split(ENVIRON["RUST_PATHS"], paths, "\n")
    for (p = 1; p <= m; p++) {
      if (paths[p] == "") continue
      best = ""
      for (i = 1; i <= n; i++) {
        if (!(name[i] in rel)) continue
        r = rel[name[i]]
        if (substr(paths[p], 1, length(r)) == r && (best == "" || length(r) > length(rel[best]))) best = name[i]
      }
      if (best == "") workspace = 1
      else reach(best)
    }
    if (workspace) {
      print "workspace"
      exit 0
    }
    for (i = 1; i <= n; i++) if (name[i] in reached) print "crate " name[i]
  }
'
