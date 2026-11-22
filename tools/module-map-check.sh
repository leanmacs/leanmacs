#!/bin/sh
# Checks the module map of docs/design/packages.md against the tree and
# against Lake (the section "The module map" there says what it lists).
#
#   tools/module-map-check.sh
#   tools/module-map-check.sh --points <packages dir> <map>
#
# Run it in `lean/`. It prints nothing and exits 0 when all three hold, and
# otherwise prints what differs, each part under a line that names it, and
# exits 1:
#
# 1. The core's modules: every module under `lean/Editor/` is named in
#    full, in backticks, in the subsection "The core's modules", and that
#    subsection names no module that is not there (in it a backticked name
#    that starts `Editor.` is a module's and nothing else's).
# 2. The packages: every package of the default set (`lake -d ../packages
#    query :editorPackageGraph`) has a row that starts with its name and
#    its layer as its lakefile declares it.
# 3. The extension points: every (package, registers or reads, point) the
#    library modules of the packages under `packages/` hold is in that
#    package's row, in its fourth column for a registration and its fifth
#    for a read, and no row names one the sources lack. A registration is
#    an `Extension.add` of a value of the point's type, or a call of
#    `compileContribution` or `projectCommands`; a read is an
#    `Extension.values`, `.named`, `.configValues` or `.workJob` over the
#    point, or a call of one of the readers the interfaces declare
#    (`FilesApi.runOpened`, `.runSaved`, `.files?`, `BuffersApi.runClosing`,
#    `.buffers?`, `ProjectApi.workspaces?`, `VcApi.connect?`, `Compile.hook`,
#    `Workspace.markerSettings`, `Compile.refreshListings`,
#    `Compile.listWork`). A point of the namespace an interface package
#    declares is not counted in that package: what uses it there is the
#    body of one of those functions. Text in backticks and declarations'
#    first lines are skipped, so prose and the readers' own definitions
#    are not counted.
#
# With `--points <packages dir> <map>` it checks the third part alone, and
# asks Lake nothing: the library modules of the packages under `<packages
# dir>` against the rows of the section "The packages" of the document
# `<map>`. It exits 2 for a command line it does not take.
#
# The gate runs it over the tree (`mise run ffi-test`), and holds the third
# part's reading by two runs with `--points` over sources and maps written
# by hand (tests/module-map/, in `mise run lean-test`;
# docs/dev-practices/the-gate.md, "The module map check"). It reads source
# text, which no test of the code does (AGENTS.md, "Test behaviour, never
# text"): it is no test of the code, and holds a document to the sources it
# describes. The first two parts ask the tree and Lake; the third is a
# reading of the sources by the rules above, which the map states too, so a
# new way to register or read is added in both, and to the fixture.
set -eu

usage() {
  echo "usage: tools/module-map-check.sh" >&2
  echo "       tools/module-map-check.sh --points <packages dir> <map>" >&2
  exit 2
}

points=
packages=../packages
doc=../docs/design/packages.md
case ${1:-} in
  --points)
    [ "$#" -eq 3 ] || usage
    points=1
    packages=$2
    doc=$3
    ;;
  *) [ "$#" -eq 0 ] || usage ;;
esac
if [ ! -d "$packages" ]; then
  echo "module-map-check: no directory $packages" >&2
  exit 2
fi
if [ ! -f "$doc" ]; then
  echo "module-map-check: no file $doc" >&2
  exit 2
fi
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failed=0

# The first two parts, which the run over the tree alone makes.
if [ -z "$points" ]; then
  # 1. The core's modules.
  find Editor -name '*.lean' | sed 's#/#.#g; s#\.lean$##' | sort >"$work/modules"
  awk '/^### The core.s modules$/{on=1;next} on&&/^##+ /{on=0} on' "$doc" |
    grep -oE '`Editor(\.[A-Za-z0-9]+)+`' | tr -d '`' | sort -u >"$work/listed"
  if ! diff "$work/modules" "$work/listed" >"$work/diff"; then
    echo "module-map-check: the core's modules (< the tree, > the map):"
    cat "$work/diff"
    failed=1
  fi

  # 2. The packages, each with its layer.
  graph=$(lake -d ../packages query :editorPackageGraph) || {
    echo "module-map-check: lake -d ../packages query :editorPackageGraph failed" >&2
    exit 2
  }
  tab=$(printf '\t')
  printf '%s\n' "$graph" | cut -f1,2 | while IFS=$tab read -r package layer; do
    grep -qE "^\| \`$package\` \| $layer \|" "$doc" || echo "$package $layer"
  done >"$work/missing"
  if [ -s "$work/missing" ]; then
    echo "module-map-check: packages of the default set with no row of their layer:"
    cat "$work/missing"
    failed=1
  fi
fi

# 3. The extension points each package registers at and reads. A package's
# files are found from its own directory, so that what is skipped (its
# build, its fixtures and its test libraries) is decided by the path
# within the package, wherever the packages are. Both sides are sorted by
# byte, so what a difference prints is the same in every locale.
for dir in "$packages"/*/; do
  package=$(basename "$dir")
  (cd "$dir" && find . -name '*.lean' -not -path '*/.lake/*' -not -path '*/tests/*' -not -path '*Test/*' -not -name '*Test.lean') | sort | while IFS= read -r file; do
    awk -v package="$package" '
      BEGIN {
        own["buffers-api"] = "BuffersApi"; own["project-api"] = "ProjectApi"
        own["compile-api"] = "Compile"; own["vc-api"] = "VcApi"
        reads["FilesApi\\.runOpened"] = "FilesApi.Opened"; reads["FilesApi\\.runSaved"] = "FilesApi.Saved"
        reads["FilesApi\\.files\\?"] = "FilesApi.Files"; reads["BuffersApi\\.runClosing"] = "BuffersApi.Closing"
        reads["BuffersApi\\.buffers\\?"] = "BuffersApi.Buffers"
        reads["ProjectApi\\.workspaces\\?"] = "ProjectApi.Workspaces"; reads["VcApi\\.connect\\?"] = "VcApi.Backend"
        both["Compile\\.hook"]; both["(^|[^A-Za-z.])markerSettings"]; both["(^|[^A-Za-z.])refreshListings"]
        both["Compile\\.listWork"]
      }
      # A point of its own namespace is one the package declares: what uses it there is a wrapper.
      function say(kind, point) {
        if (point !~ /\./ && (package in own)) point = own[package] "." point
        if ((package in own) && own[package] != "" && index(point, own[package] ".") == 1) return
        print package "\t" kind "\t" point
      }
      {
        line = $0
        gsub(/`[^`]*`/, "", line)
        if (line ~ /^(def|abbrev|theorem|structure) /) next
        if (line ~ /Extension\.add/) { pending = 12; colon = 0 }
        if (pending > 0) {
          pending--
          if (match(line, /: [A-Z][A-Za-z]*\.[A-Z][A-Za-z]*\)/)) { say("registers", substr(line, RSTART + 2, RLENGTH - 3)); pending = 0 }
          else if (colon && match(line, /^ +[A-Z][A-Za-z]*\.[A-Z][A-Za-z]*\)/)) { found = substr(line, RSTART, RLENGTH - 1); gsub(/ /, "", found); say("registers", found); pending = 0 }
          colon = (line ~ /:[ \t]*$/)
        }
        if (line ~ /(^|[^A-Za-z.])compileContribution($|[^A-Za-z])/) say("registers", "Compile.Contribution")
        if (line ~ /(^|[^A-Za-z.])projectCommands($|[^A-Za-z])/) say("registers", "Compile.ProjectCommands")
        rest = line
        while (match(rest, /Extension\.(values|named|configValues|workJob) [A-Za-z.]+/)) {
          found = substr(rest, RSTART, RLENGTH); sub(/^[^ ]* /, "", found); say("reads", found)
          rest = substr(rest, RSTART + RLENGTH)
        }
        for (name in reads) if (line ~ name) say("reads", reads[name])
        for (name in both) if (line ~ name) { say("reads", "Compile.Contribution"); say("reads", "Compile.ProjectCommands") }
      }' "$dir$file"
  done
done | LC_ALL=C sort -u >"$work/sources"
awk -F'|' '/^### The packages$/{on=1;next} on&&/^##+ /{on=0}
  on && /^\| `[a-z-]+` \| (interface|implementation) \|/ {
    package = $2; gsub(/[ `]/, "", package)
    for (column = 5; column <= 6; column++) {
      kind = column == 5 ? "registers" : "reads"
      rest = $column
      while (match(rest, /`[A-Z][A-Za-z]*\.[A-Z][A-Za-z]*`/)) {
        print package "\t" kind "\t" substr(rest, RSTART + 1, RLENGTH - 2)
        rest = substr(rest, RSTART + RLENGTH)
      }
    }
  }' "$doc" | LC_ALL=C sort -u >"$work/rows"
if ! diff "$work/sources" "$work/rows" >"$work/diff"; then
  echo "module-map-check: extension points (< the sources, > the map's rows):"
  cat "$work/diff"
  failed=1
fi
exit "$failed"
