#!/bin/sh
# The Lean checks of some packages alone: what the pre-commit hook runs for
# a staged change that reaches only those packages (`mise run
# lean-packages`, which hands it LEAN_HOOK_PACKAGES; tools/lean-hook.sh;
# docs/dev-practices/the-gate.md, "The pre-commit hook").
#
#   tools/lean-packages.sh [--dry-run] <package>...
#
# Run it in `lean/`. In order: the toolchain check; then, over the named
# packages of the fixture set (tools/package-set.sh --only): the `test`
# step, with the `cargo` that fails first on the PATH; the `build` step,
# under the system's C compiler, which builds the set's editor and its
# fixture harness first; the
# `fmt` step; the layer and package imports checks over the set, kept
# because the targeting is sound only while no package imports an
# implementation package; and the `run` step, with `--allow-empty-run` so
# an interface package, which holds no linked test and no fixture, passes.
# Last, for the named packages that are also packages of the default set
# (packages/), as Lake names them, that set's editor and fixture harness
# and the same `run` over it.
#
# With `--dry-run` it prints each command instead of running it, one a
# line, `lean-packages: <command>`, with `no-cargo` or `system-cc` before a
# command that runs with that environment and `<sysroot>` for the
# toolchain's directory; it still asks Lake for the default set's
# packages. It exits 2 when it is given no package, and otherwise with the
# status of the first command that fails.
set -eu

dry=
if [ "${1-}" = --dry-run ]; then
  dry=1
  shift
fi
if [ "$#" -eq 0 ]; then
  echo "lean-packages: the command line names no package, so there is nothing to check" >&2
  exit 2
fi

# Runs a command, or prints it with `--dry-run`. Leading words `no-cargo`
# and `system-cc` set its environment: the `cargo` that fails first on the
# PATH, and the system's C compiler for Lake's links.
run() {
  envs=
  while :; do
    case $1 in
      no-cargo | system-cc)
        envs="$envs$1 "
        shift
        ;;
      *) break ;;
    esac
  done
  if [ -n "$dry" ]; then
    echo "lean-packages: $envs$*"
    return 0
  fi
  (
    case $envs in *no-cargo*) PATH="$PWD/no-cargo:$PATH" && export PATH ;; esac
    case $envs in *system-cc*) LEAN_CC=/usr/bin/cc && export LEAN_CC ;; esac
    "$@"
  )
}

if [ -n "$dry" ]; then
  sysroot='<sysroot>'
else
  sysroot=$(lean --print-prefix)
fi

# `--only <name>` for each name, as positional words after the step's.
only=
for name in "$@"; do
  only="$only --only $name"
done

# shellcheck disable=SC2086 # $only is words by design: names hold no blank.
{
  run sh ../tools/toolchain-check.sh
  run no-cargo sh ../tools/package-set.sh $only test ../tests/packages
  run system-cc sh ../tools/package-set.sh $only build ../tests/packages
  run sh ../tools/package-set.sh $only fmt ../tests/packages
  run sh ../tools/layer-imports-check.sh ../tests/packages
  run sh ../tools/package-imports-check.sh ../tests/packages
  run sh ../tools/package-set.sh $only --allow-empty-run run ../tests/packages "$sysroot" .lake/build/lib/lean
}

defaults=$(lake -d ../packages query :editorPackages | cut -f1) || {
  echo "lean-packages: lake -d ../packages query :editorPackages failed" >&2
  exit 2
}
default_only=
for name in "$@"; do
  if printf '%s\n' "$defaults" | grep -qxF -- "$name"; then
    default_only="$default_only --only $name"
  fi
done
if [ -n "$default_only" ]; then
  run system-cc lake -d ../packages build --wfail :editor :editorFixtures
  # shellcheck disable=SC2086
  run sh ../tools/package-set.sh $default_only --allow-empty-run run ../packages "$sysroot" .lake/build/lib/lean
fi
