#!/bin/sh
# The pre-commit hook's Rust step (hk.pkl, `rust`;
# docs/dev-practices/the-gate.md, "The pre-commit hook"): runs what
# tools/rust-targets.sh decides for the staged files it is given, and
# decides nothing itself.
#
#   tools/rust-hook.sh [--dry-run] [--lines <file> --root <dir>] <staged path>...
#
# Run it at the repository's root, as hk does. For:
#
# - `workspace`: `mise run lint && mise run test`, clippy and the tests over
#   every crate, as before the hook was targeted;
# - crates: clippy over those crates and their targets, warnings as
#   errors, then their tests (`cargo clippy -p ... --all-targets` and
#   `cargo test -p ...`), with the same flags as `lint` and `test`;
# - nothing: nothing.
#
# It prints the decision first, `rust-hook: workspace`, `rust-hook: crates
# <names>` or `rust-hook: nothing`, and exits with the status of what it
# ran, or of the decision when that fails.
#
# With `--dry-run` it prints each command, `run: <command>`, instead of
# running it, and with `--lines` and `--root` it hands the decision a graph
# from a file instead of asking Cargo (tools/rust-targets.sh), so the gate
# can see what a commit would run without running it (`mise run test`,
# over tests/rust-targets/).
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

targets=$(mise exec -- sh tools/rust-targets.sh "$@")

case $targets in
  '')
    echo "rust-hook: nothing"
    ;;
  workspace)
    echo "rust-hook: workspace"
    run mise run lint
    run mise run test
    ;;
  *)
    names=$(printf '%s\n' "$targets" | sed -n 's/^crate //p' | tr '\n' ' ')
    names=${names% }
    echo "rust-hook: crates $names"
    set --
    for name in $names; do
      set -- "$@" -p "$name"
    done
    [ "$#" -gt 0 ] || {
      echo "rust-hook: tools/rust-targets.sh decided on no crate: $targets" >&2
      exit 2
    }
    run mise exec -- cargo clippy "$@" --all-targets --locked -- -D warnings
    run mise exec -- cargo test "$@" --locked
    ;;
esac
