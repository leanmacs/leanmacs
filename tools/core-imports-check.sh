#!/bin/sh
# Checks that the core imports no module of a feature that moves out of it,
# on Lake's module graph (docs/design/packages.md, "The core imports
# check"): a package may depend on the core, and the core on no package.
#
#   tools/core-imports-check.sh [<root module> [<moving name>...]]
#
# Run it in `lean/`. The root module defaults to `Editor.Core`, the core's
# root. A moving name is a module that is not the core's, with every module
# under it; they default to the compile mode and the shipped palettes
# (`moving`, below). They are named, never derived: "what the root does not
# reach" would pass whatever the core imported.
#
# It checks three things, in this order, and stops at the first that fails:
#
# 1. The root and the modules it imports, directly or through another, hold
#    no moving module. Otherwise it prints each one found, one a line, and
#    exits 1.
# 2. Every module named `Editor.…` that a root of the build reaches (`built`,
#    below) is the root or one of the modules it imports, unless it is a
#    moving module or the module that lists the packages (`list`). Otherwise
#    it prints each one outside, one a line, and exits 3. This is what makes
#    the first a statement about every core module: a core module the root
#    does not import would be checked by nothing.
# 3. A root of the build that reaches the elaborator adapter (`elaborator`)
#    reaches the config base (`base`): an executable that can elaborate
#    config links every module config may import. Otherwise it prints each
#    root that does not, one a line, and exits 4.
#
# It exits 0 when all three hold. It exits 2 for a command line it does not
# take, when Lake fails a query, and when Lake answers nothing for a root,
# which would make the check pass for no reason.
#
# It asks Lake (`lake query`) and reads no source text:
# `+<module>:transImports` is a module's transitive imports, one module a
# line, from the build graph Lake resolves. It builds nothing. So the check
# follows a module that is renamed or moved, and an import written in any
# form. It makes one query for the root and one for each root of the build.
set -eu

# The module that lists the packages that ship. It is neither the core's nor
# a feature's: it names the packages, the moving ones among them.
list=Editor.PackageSet
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
  echo "usage: tools/core-imports-check.sh [<root module> [<moving name>...]]" >&2
  exit 2
}

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

# 2 and 3 read what each root of the build reaches.
outside=
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
      if [ "$module" = "$list" ] || is_moving "$module"; then
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
  if printf '%s\n' "$reached" | grep -qxF "$elaborator" &&
    ! printf '%s\n' "$reached" | grep -qxF "$base"; then
    unbased=$(printf '%s\n%s\n' "$unbased" "$target")
  fi
done

# 2. Every `Editor.…` module the build reaches is in the root's closure.
if [ -n "$outside" ]; then
  echo "core-imports-check: the build reaches these modules, which $root does not import and which are neither moving nor $list:" >&2
  printf '%s\n' "$outside" | sed '/^$/d' | sort -u
  exit 3
fi

# 3. An executable that links the elaborator links the config base.
if [ -n "$unbased" ]; then
  echo "core-imports-check: these roots reach $elaborator and not the config base, $base:" >&2
  printf '%s\n' "$unbased" | sed '/^$/d'
  exit 4
fi
