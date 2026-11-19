#!/bin/sh
# Runs one soak of the config benchmark at 100 and at 500 reloads and says
# what the resident memory of the second is of the first:
# `mise run config-bench` (docs/dev-practices/on-demand-checks.md,
# "The config benchmark, on demand"; docs/design/lean-runtime.md, "Config
# and reload").
#
#   tools/soak-ratio.sh <config-test> <sysroot> <olean dir> <soak>
#
# `<config-test>` is the built executable, `<sysroot>` the Lean toolchain's
# directory, `<olean dir>` the core's `.olean` directory, and `<soak>` the
# subcommand: `bench-soak`, a config that is its root alone, or
# `bench-soak-modules`, a root and a config file that changes each round
# (lean/ConfigTest/Bench.lean).
#
# Each run is a fresh process under `/usr/bin/time -l`, with
# LEAN_STACK_SIZE_KB removed from its environment, so its threads have the
# stack the editor gives them. It prints the subcommand's own line for each
# run, then one line with the two maximum resident set sizes and the
# second as a change from the first, in percent. A config whose replaced
# versions are freed stays within a few percent; one that keeps them grows
# with the count.
#
# It measures and asserts nothing: memory is reported, never gating. It is
# macOS only, as `/usr/bin/time -l` is. Its one temporary file is removed
# by a trap.
set -eu

if [ "$#" -ne 4 ]; then
  echo "usage: tools/soak-ratio.sh <config-test> <sysroot> <olean dir> <soak>" >&2
  exit 2
fi

config_test=$1
sysroot=$2
oleans=$3
soak=$4

timing=$(mktemp)
trap 'rm -f "$timing"' EXIT

# Runs the soak with `$1` reloads and prints its maximum resident set size,
# in bytes; the soak's own line goes to stderr, so it is still seen.
resident() {
  /usr/bin/time -l env -u LEAN_STACK_SIZE_KB "$config_test" "$soak" "$sysroot" "$oleans" "$1" >&2 2>"$timing"
  awk '/maximum resident set size/ { print $1 }' "$timing"
}

short=$(resident 100)
long=$(resident 500)

awk -v soak="$soak" -v short="$short" -v long="$long" 'BEGIN {
  printf "%s: resident after 100 reloads %.1f MB, after 500 reloads %.1f MB: %+.1f%%\n",
    soak, short / 1000000, long / 1000000, (long - short) * 100 / short
}'
