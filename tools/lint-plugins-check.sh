#!/bin/sh
# Checks that the build's linters, the wait linters (lean/Lint/Wait.lean)
# and the real-host linter (lean/Lint/RealHost.lean), are loaded as a Lean plugin into every library and executable they guard:
# each of the core's, and each of every package a set holds in its own
# directory (docs/dev-practices/the-gate.md, "The wait lints"). A
# library that loads no plugin is never linted, and nothing else would say
# so: the linters' fixtures show them refusing only in the libraries that
# hold one.
#
#   tools/lint-plugins-check.sh <set dir>
#
# Run it in `lean/`. The set's directory holds the set's lakefile. It asks
# Lake (`lake -d <set dir> query :editorLintPlugins`, a facet the core
# defines in `lean/lakefile.lean`, which decides) and reads no source text:
# one line for each library and executable of the core and of each package
# under the set's directory, its fields separated by tabs:
#
#   <package>	<lean_lib or lean_exe>	<target>	<loads, imports or none>
#
# `loads` for one that loads the plugin, its package's `plugins` among
# its own; `imports` for one with a module that is, or imports, a module of
# the core's `Lint`, which has the linters by import (the core's `Lint`,
# `LintTests` and `lint-test`); and `none` for one that does neither. A
# package the set reaches from outside its directory is not listed: one
# written as a user's is (docs/packages/word-count, which the fixture set
# reaches), and the linters hold this repository's tests to its practice,
# not a user's package.
#
# It prints nothing and exits 0 when every line is `loads` or `imports`.
# Otherwise it prints each library and executable that is `none`, one a
# line, and exits 1. It exits 2, so that it cannot pass by checking
# nothing, for a command line it does not take, when Lake fails the query,
# for a line that is not four fields or has a verdict it does not know, and
# when no line is of the core: every set requires the core, so such input
# means the core's targets were not read.
set -eu

if [ "$#" -ne 1 ] || [ -z "$1" ] || [ "${1#-}" != "$1" ]; then
  echo "usage: tools/lint-plugins-check.sh <set dir>" >&2
  exit 2
fi
if [ ! -d "$1" ]; then
  echo "lint-plugins-check: no directory $1" >&2
  exit 2
fi
lines=$(lake -d "$1" query :editorLintPlugins) || {
  echo "lint-plugins-check: lake -d $1 query :editorLintPlugins failed" >&2
  exit 2
}

tab=$(printf '\t')
printf '%s\n' "$lines" | awk -F "$tab" -v set="$1" '
  $0 == "" { next }
  {
    if (NF != 4 || ($2 != "lean_lib" && $2 != "lean_exe") ||
        ($4 != "loads" && $4 != "imports" && $4 != "none")) {
      print "lint-plugins-check: not a line of a package, a target kind, a target and a verdict: " $0 > "/dev/stderr"
      bad = 1
      exit 2
    }
    if ($1 == "editor-core") core = 1
    if ($4 == "none") {
      print "lint-plugins-check: " $1 ": the " $2 " " $3 " loads no lint plugin, so the wait linters never run on it: name `@editor-core/lintShared` in its `plugins`, or its package'"'"'s (`lintPlugin` in lean/lakefile.lean)"
      refused = 1
    }
  }
  END {
    if (bad) exit 2
    if (!core) {
      print "lint-plugins-check: no line of " set " is of the core, so the core is not checked" > "/dev/stderr"
      exit 2
    }
    exit refused
  }
'
