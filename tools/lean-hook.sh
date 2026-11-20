#!/bin/sh
# The pre-commit hook's Lean step (hk.pkl, `lean`; docs/dev-practices/the-gate.md,
# "The pre-commit hook"): runs what tools/hook-targets.sh decides for the
# staged files it is given, and decides nothing itself.
#
#   tools/lean-hook.sh [--dry-run] [--lines <file> --root <dir>] <staged path>...
#
# Run it at the repository's root, as hk does. It asks the decision of the
# fixture set (`tests/packages`), the set every package step runs over, and
# then, for:
#
# - `core`: `mise run lean-fmt && mise run ffi-test`, the core's whole chain
#   and every package's checks, as before the hook was targeted;
# - packages: `mise run lean-packages` with their names in
#   LEAN_HOOK_PACKAGES, the checks of those packages alone;
# - nothing: nothing.
#
# It prints the decision first, `lean-hook: core`, `lean-hook: packages
# <names>` or `lean-hook: nothing`, and exits with the status of what it
# ran, or of the decision when that fails.
#
# With `--dry-run` it prints each command, `run: <command>`, instead of
# running it, and with `--lines` and `--root` it hands the decision a graph
# from a file instead of asking Lake (tools/hook-targets.sh), so the gate
# can see what a commit would run without running it (`lean-test`, over
# tests/hook-targets/).
set -eu

dry=
if [ "${1-}" = --dry-run ]; then
  dry=1
  shift
fi

# Runs a command, or prints it with `--dry-run`.
run() {
  if [ -n "$dry" ]; then
    echo "run: $*"
  else
    "$@"
  fi
}

if [ "${1-}" = --lines ]; then
  [ "$#" -ge 4 ] && [ "$3" = --root ] || {
    echo "usage: tools/lean-hook.sh [--dry-run] [--lines <file> --root <dir>] <staged path>..." >&2
    exit 2
  }
  targets=$(sh tools/hook-targets.sh "$@")
else
  targets=$(cd lean && mise exec -- sh ../tools/hook-targets.sh ../tests/packages "$@")
fi

case $targets in
  '')
    echo "lean-hook: nothing"
    ;;
  core)
    echo "lean-hook: core"
    run mise run lean-fmt
    run mise run ffi-test
    ;;
  *)
    names=$(printf '%s\n' "$targets" | sed -n 's/^package //p' | tr '\n' ' ')
    names=${names% }
    echo "lean-hook: packages $names"
    run env LEAN_HOOK_PACKAGES="$names" mise run lean-packages
    ;;
esac
