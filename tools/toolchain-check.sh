#!/bin/sh
# Checks that every copy of the Lean pin equals the pin
# (docs/design/packages.md, "The package set and its build"; AGENTS.md,
# "Toolchains"): `lean/lean-toolchain` is the one pin every task reads, and
# each Lake package outside `lean/` holds a copy of it, which `lean-fmt`
# requires of a package it is run over and elan reads when Lake is run in
# that package's directory. A bump changes every copy in one commit.
#
#   tools/toolchain-check.sh [<reference file>]
#
# Run it anywhere inside the repository. The reference file defaults to
# `lean/lean-toolchain`; a relative one is read from the working directory.
# The gate hands it another file to see the check fail.
#
# The copies are the tracked files named `lean-toolchain`, at any depth
# (`git ls-files`), so Lake's fetched packages and build output are never
# looked at. A new copy is checked once it is `git add`ed.
#
# It exits 0 when every copy holds exactly the reference's bytes. Otherwise
# it prints each copy that differs, one a line, as a path from the
# repository's root, and exits 1. It exits 2 for a command line it does not
# take, when the reference cannot be read, when git fails, and when git
# lists no copy other than the pin itself, which would make the check pass
# for no reason.
set -eu

if [ "$#" -gt 1 ]; then
  echo "usage: tools/toolchain-check.sh [<reference file>]" >&2
  exit 2
fi

root=$(cd "$(dirname "$0")/.." && pwd)
pin=lean/lean-toolchain
reference=${1:-$root/$pin}
if [ ! -r "$reference" ] || [ -d "$reference" ]; then
  echo "toolchain-check: cannot read the reference file $reference" >&2
  exit 2
fi

copies=$(git -C "$root" ls-files -- lean-toolchain '*/lean-toolchain') || {
  echo "toolchain-check: git ls-files failed" >&2
  exit 2
}
if [ -z "$(printf '%s\n' "$copies" | grep -vxF "$pin" || true)" ]; then
  echo "toolchain-check: git lists no lean-toolchain other than $pin, so there is no copy to check" >&2
  exit 2
fi

differing=$(
  printf '%s\n' "$copies" | while IFS= read -r copy; do
    if ! cmp -s "$reference" "$root/$copy"; then
      printf '%s\n' "$copy"
    fi
  done
)
if [ -n "$differing" ]; then
  echo "toolchain-check: these files differ from $reference:" >&2
  printf '%s\n' "$differing"
  exit 1
fi
