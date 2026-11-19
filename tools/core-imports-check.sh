#!/bin/sh
# Checks that the core imports no module of a feature that moves out of it,
# on Lake's module graph (docs/design/packages.md, "The core imports
# check"): a package may depend on the core, and the core on no package.
#
#   tools/core-imports-check.sh [--base <module>] [--elaborator <module>]
#                                [<root module> [<moving name>...]]
#
# Run it in `lean/`. The root module defaults to `Editor.Core`, the core's
# root. A moving name is a module that is not the core's, with every module
# under it; they default to the compile mode and the shipped palettes
# (`moving`, below). They are named, never derived: "what the root does not
# reach" would pass whatever the core imported. `--base` names the config
# base and `--elaborator` the elaborator adapter, in place of the editor's
# (`base` and `elaborator`, below): the gate uses them to see the third
# rule fail.
#
# It checks three things, in this order, and stops at the first that fails:
#
# 1. The root and the modules it imports, directly or through another, hold
#    no moving module. Otherwise it prints each one found, one a line, and
#    exits 1.
# 2. Every module named `Editor.…` that a root of the build reaches (`built`,
#    below) is the root or one of the modules it imports, unless it is a
#    moving module. Otherwise it prints each one outside, one a line, and
#    exits 3. This is what makes the first a statement about every core
#    module: a core module the root does not import would be checked by
#    nothing. No module is exempt by name: the list of the packages that
#    ship, which names the moving packages, is `PackageSet`, outside
#    `Editor/` and its namespace.
# 3. A root of the build that reaches the elaborator adapter (`elaborator`)
#    reaches the config base (`base`): an executable that can elaborate
#    config links every module config may import. Otherwise it prints each
#    root that does not, one a line, and exits 4.
#
# It exits 0 when all three hold. It exits 2, before it reports on any
# rule, for a command line it does not take, when Lake fails a query, when
# Lake answers nothing for a root, and when no root of the build reaches
# the elaborator adapter: each would make a rule hold of nothing, so the
# check would pass for no reason. The last is what a renamed adapter, or a
# list of roots that has fallen behind the build, would look like.
#
# It asks Lake (`lake query`) and reads no source text:
# `+<module>:transImports` is a module's transitive imports, one module a
# line, from the build graph Lake resolves. It builds nothing. So the check
# follows a module that is renamed or moved, and an import written in any
# form. It makes one query for the root and one for each root of the build.
set -eu

# The config base: the module user config is elaborated on.
base=Editor
# The module that links Lean's elaborator in and elaborates config on the
# base.
elaborator=Editor.Config.Elaborate
# The roots of the build: the executable's and the test executables'.
built="Main ModelTest ConfigTest FfiTest ContractTest"
# The moving names when none is given.
moving="Editor.Compile Editor.Themes.Solarized Editor.Themes.FairyFloss Editor.Themes.Shipped"

usage() {
  echo "usage: tools/core-imports-check.sh [--base <module>] [--elaborator <module>] [<root module> [<moving name>...]]" >&2
  exit 2
}

# The options, each with the module it names, before the root.
while [ "$#" -gt 0 ]; do
  case $1 in
    --base | --elaborator)
      [ "$#" -ge 2 ] || usage
      case $2 in
        '' | -* | *[!A-Za-z0-9_.]*) usage ;;
      esac
      if [ "$1" = --base ]; then base=$2; else elaborator=$2; fi
      shift 2
      ;;
    *) break ;;
  esac
done

# A module name is dot-separated identifiers: no option and no white space.
for argument in "$@"; do
  case $argument in
    '' | -* | *[!A-Za-z0-9_.]*) usage ;;
  esac
done

root=${1:-Editor.Core}
if [ "$#" -gt 1 ]; then
  shift
  moving=$*
fi

# A query Lake fails is status 2, never 1, 3 or 4, which each say a rule
# was broken.
asked() {
  lake query "$@" || {
    echo "core-imports-check: lake query $* failed" >&2
    exit 2
  }
}

# The module `$1` and its transitive imports, sorted, each once. Nothing for
# a module Lake names no import of.
closure() {
  imports=$(asked "+$1:transImports") || exit 2
  if [ -z "$imports" ]; then
    echo "core-imports-check: Lake names no import of $1, so there is nothing to check" >&2
    exit 2
  fi
  printf '%s\n%s\n' "$1" "$imports" | sort -u
}

# Whether the module `$1` is a moving name or under one.
is_moving() {
  for name in $moving; do
    case $1 in
      "$name" | "$name".*) return 0 ;;
    esac
  done
  return 1
}

core=$(closure "$root") || exit 2

# What each root of the build reaches: for the second rule, the `Editor.…`
# modules among them that are outside the root's closure and not moving;
# for the third, the roots that reach the elaborator adapter, and those of
# them that do not reach the config base.
outside=
elaborating=
unbased=
for target in $built; do
  reached=$(closure "$target") || exit 2
  missing=$(
    printf '%s\n' "$reached" | while IFS= read -r module; do
      # The patterns open with a parenthesis: inside `$( )` an older bash
      # takes a bare closing one for the substitution's end.
      case $module in
        (Editor.*) ;;
        (*) continue ;;
      esac
      if is_moving "$module"; then
        continue
      fi
      if ! printf '%s\n' "$core" | grep -qxF "$module"; then
        printf '%s\n' "$module"
      fi
    done
  )
  if [ -n "$missing" ]; then
    outside=$(printf '%s\n%s\n' "$outside" "$missing")
  fi
  if printf '%s\n' "$reached" | grep -qxF "$elaborator"; then
    elaborating=$(printf '%s\n%s\n' "$elaborating" "$target")
    if ! printf '%s\n' "$reached" | grep -qxF "$base"; then
      unbased=$(printf '%s\n%s\n' "$unbased" "$target")
    fi
  fi
done

# The third rule must be about some root, or it holds of nothing.
if [ -z "$elaborating" ]; then
  echo "core-imports-check: no root of the build ($built) reaches $elaborator, so no root is checked for the config base" >&2
  exit 2
fi

# 1. The root's closure holds no moving module.
found=$(
  printf '%s\n' "$core" | while IFS= read -r module; do
    if is_moving "$module"; then
      printf '%s\n' "$module"
    fi
  done
)
if [ -n "$found" ]; then
  echo "core-imports-check: $root reaches these modules, which are not the core's ($moving):" >&2
  printf '%s\n' "$found"
  exit 1
fi

# 2. Every `Editor.…` module the build reaches is in the root's closure.
if [ -n "$outside" ]; then
  echo "core-imports-check: the build reaches these modules, which $root does not import and which are not moving:" >&2
  printf '%s\n' "$outside" | sed '/^$/d' | sort -u
  exit 3
fi

# 3. An executable that links the elaborator links the config base.
if [ -n "$unbased" ]; then
  echo "core-imports-check: these roots reach $elaborator and not the config base, $base:" >&2
  printf '%s\n' "$unbased" | sed '/^$/d'
  exit 4
fi
