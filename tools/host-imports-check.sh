#!/bin/sh
# Checks that the host's modules import no feature module, on Lake's module
# graph (docs/design/lean-runtime.md, "Packages"): the executable's hosts
# are handed their packages as a value, by the one module that lists them,
# and name none of them.
#
#   tools/host-imports-check.sh [<root module> [<list module>]]
#
# Run it in `lean/`. The root module defaults to `Main`, the executable's,
# and the list module to `PackageSet`, the module that lists the packages
# (`lean/PackageSet.lean`, outside `Editor/`).
#
# - The host's modules are the modules the root imports, other than the
#   list module, with everything they import inside the package.
# - A feature module is the list module, or a module it imports directly:
#   the modules that define the packages.
#
# It exits 0 when no host module is a feature module. Otherwise it prints
# each feature module the host reaches, one a line, and exits 1. It exits 2
# for a command line it does not take, when Lake fails a query, and when
# Lake answers nothing for the root or for the list, which would make the
# check pass for no reason.
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

if [ "$#" -gt 2 ]; then
  echo "usage: tools/host-imports-check.sh [<root module> [<list module>]]" >&2
  exit 2
fi
root=${1:-Main}
list=${2:-PackageSet}

# A query Lake fails is status 2, never 1: 1 says a feature module was found.
asked() {
  lake query "$@" || {
    echo "host-imports-check: lake query $* failed" >&2
    exit 2
  }
}

listed=$(asked "+$list:imports") || exit 2
if [ -z "$listed" ]; then
  echo "host-imports-check: Lake names no import of $list, so there is nothing to forbid" >&2
  exit 2
fi
forbidden=$(printf '%s\n%s\n' "$list" "$listed" | sort -u)

imported=$(asked "+$root:imports") || exit 2
roots=$(printf '%s\n' "$imported" | grep -vxF "$list" || true)
if [ -z "$roots" ]; then
  echo "host-imports-check: Lake names no import of $root other than $list, so there is no host to check" >&2
  exit 2
fi

# One query, with a target for each root. A module name holds no white
# space, so the unquoted expansion splits one name a word.
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
  echo "host-imports-check: the modules $root imports, other than $list, reach these modules of $list:" >&2
  printf '%s\n' "$found"
  exit 1
fi
