#!/bin/sh
# The pre-commit hook's Rust step (hk.pkl, `rust`;
# docs/dev-practices/the-gate.md, "The pre-commit hook"): runs what
# tools/rust-targets.sh decides for the staged files it is given, and
# decides nothing itself.
#
#   tools/rust-hook.sh <staged path>...
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
set -eu

targets=$(mise exec -- sh tools/rust-targets.sh "$@")

case $targets in
  '')
    echo "rust-hook: nothing"
    ;;
  workspace)
    echo "rust-hook: workspace"
    mise run lint
    mise run test
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
    mise exec -- cargo clippy "$@" --all-targets --locked -- -D warnings
    mise exec -- cargo test "$@" --locked
    ;;
esac
