#!/bin/sh
# Checks that the host's modules import no feature module, on Lake's module
# graph (docs/design/lean-runtime.md, "Packages"): the executable's hosts
# are handed their packages as a value, by the executable's root, and name
# none of them.
#
#   tools/host-imports-check.sh [--set <set dir>]
#   tools/host-imports-check.sh <root module> [<list module>]
#
# Run it in `lean/`.
#
# With no argument, or with `--set`, it checks the root the package-set
# build generates for a package set (docs/design/packages.md, "The package
# set and its build"), the default set's (`../packages`) when none is
# named. The root's imports are asked of Lake (`lake -d <set dir> query
# :editorRootImports`, a facet the core defines; the root is a module no
# library declares, so `+<module>:imports` does not find it). The list
# modules are the root's imports named `….EditorPackage`, the entry modules
# of the set's Lake packages, and its other imports are the host's.
#
# With a root module, it checks that module of the core in the same way,
# with one list module, which defaults to `EditorCore.EditorPackage`, the
# core's entry module (`lean/EditorCore/EditorPackage.lean`, outside
# `Editor/`). The gate uses this form to see the check fail.
#
# - The host's modules are the modules the root imports, other than the
#   list modules, with everything they import inside the workspace.
# - A feature module is a list module, or a module one imports directly:
#   the modules that define the packages.
#
# It exits 0 when no host module is a feature module. Otherwise it prints
# each feature module the host reaches, one a line, and exits 1. It exits 2
# for a command line it does not take, when Lake fails a query, and when
# Lake answers nothing for the root, names no list module among its
# imports, or nothing for a list, each of which would make the check pass
# for no reason.
#
# It asks Lake (`lake query`) and reads no source text: `+<module>:imports`
# is a module's direct imports and `+<module>:transImports` its transitive
# ones, one module a line, from the build graph Lake resolves. Neither
# builds anything. So the check follows a module that is renamed or moved,
# and an import written in any form.
#
# What it does not claim: the core loop still imports feature code that
# defines no package, such as `Editor.Files` and `Editor.Ex`
# (`lean/Editor/Loop.lean`). This check is of the modules that define
# packages. That the core imports no module of a feature that moves out of
# it is `tools/core-imports-check.sh`'s, and what each feature still in the
# core would have to cross to move out is the module map of
# docs/design/packages.md.
set -eu

usage() {
  echo "usage: tools/host-imports-check.sh [--set <set dir>]" >&2
  echo "       tools/host-imports-check.sh <root module> [<list module>]" >&2
  exit 2
}

# The set form's directory, or nothing for the module form.
set_dir=../packages
root=
case ${1:-} in
  '') [ "$#" -eq 0 ] || usage ;;
  --set)
    [ "$#" -eq 2 ] || usage
    set_dir=$2
    ;;
  -*) usage ;;
  *)
    [ "$#" -le 2 ] || usage
    set_dir=
    root=$1
    list=${2:-EditorCore.EditorPackage}
    ;;
esac

# A query Lake fails is status 2, never 1: 1 says a feature module was
# found. In the set form the queries are of the set's workspace, which
# holds the modules of every package of the set.
asked() {
  if [ -n "$set_dir" ]; then
    lake -d "$set_dir" query "$@" || {
      echo "host-imports-check: lake -d $set_dir query $* failed" >&2
      exit 2
    }
  else
    lake query "$@" || {
      echo "host-imports-check: lake query $* failed" >&2
      exit 2
    }
  fi
}

# The root's direct imports, and the list modules among them.
if [ -n "$set_dir" ]; then
  shown="the root of the set in $set_dir"
  imported=$(asked :editorRootImports) || exit 2
  lists=$(printf '%s\n' "$imported" | grep -E '(^|\.)EditorPackage$' || true)
  if [ -z "$lists" ]; then
    echo "host-imports-check: $shown imports no module named EditorPackage, so there is nothing to forbid" >&2
    exit 2
  fi
else
  shown=$root
  imported=$(asked "+$root:imports") || exit 2
  lists=$list
fi
roots=$(printf '%s\n' "$imported" | grep -vxF "$lists" || true)
if [ -z "$roots" ]; then
  echo "host-imports-check: Lake names no import of $shown other than its list modules, so there is no host to check" >&2
  exit 2
fi

# The feature modules: each list module and what it imports directly. One
# query, with a target for each list module. A module name holds no white
# space, so the unquoted expansion splits one name a word.
set --
for module in $lists; do
  set -- "$@" "+$module:imports"
done
listed=$(asked "$@") || exit 2
if [ -z "$listed" ]; then
  echo "host-imports-check: Lake names no import of the list modules of $shown, so there is nothing to forbid" >&2
  exit 2
fi
forbidden=$(printf '%s\n%s\n' "$lists" "$listed" | sort -u)

# The host: the other imports and everything they import. One query again.
set --
for module in $roots; do
  set -- "$@" "+$module:transImports"
done
reached=$(asked "$@") || exit 2
host=$(printf '%s\n%s\n' "$roots" "$reached" | sort -u)

found=$(
  printf '%s\n' "$forbidden" | while IFS= read -r module; do
    if printf '%s\n' "$host" | grep -qxF "$module"; then
      printf '%s\n' "$module"
    fi
  done
)
if [ -n "$found" ]; then
  echo "host-imports-check: the modules $shown imports, other than its list modules, reach these feature modules:" >&2
  printf '%s\n' "$found"
  exit 1
fi
