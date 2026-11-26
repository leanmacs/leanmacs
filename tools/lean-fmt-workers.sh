#!/bin/sh
# Prints how many workers the Lean formatter may run at once on this
# machine (`lean-fmt --workers`, in `mise run lean-fmt` and `lean-format`
# and tools/package-set.sh's `fmt` and `format`): one per core, but no more
# than the machine's memory holds at 2 GiB a worker, and at least one.
#
#   tools/lean-fmt-workers.sh [--cores <n> --memory-kib <k>]
#
# lean-fmt runs one frontend child per file, a worker each, and a child
# for a module that imports `Lean` (the linters, `Lint/`, and their tests,
# `LintTest/`) holds about 2 GB of its own. At one worker a core, the
# Linux container's eight workers in its 7.75 GiB lost children to the
# kernel's OOM killer, each with 1.9 GB anonymous memory, and the gate
# failed with `exact frontend child failed` and no diagnostic
# (host-tests-on-fakes phase 7, F4). Cores are `nproc` (or `sysctl -n
# hw.ncpu`), memory MemTotal in /proc/meminfo (or `sysctl -n hw.memsize`);
# `--cores` and `--memory-kib` stand in for both, to try a size by hand.
set -eu

per_worker_kib=$((2 * 1024 * 1024))
if [ "$#" -eq 4 ] && [ "$1" = --cores ] && [ "$3" = --memory-kib ]; then
  cores=$2
  memory=$4
elif [ "$#" -eq 0 ]; then
  if [ -r /proc/meminfo ]; then
    cores=$(nproc)
    memory=$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)
  else
    cores=$(sysctl -n hw.ncpu)
    memory=$(($(sysctl -n hw.memsize) / 1024))
  fi
else
  echo "usage: tools/lean-fmt-workers.sh [--cores <n> --memory-kib <k>]" >&2
  exit 2
fi
case "$cores$memory" in '' | *[!0-9]*)
  echo "lean-fmt-workers: no count of cores or memory: $cores, $memory" >&2
  exit 2
  ;;
esac
workers=$((memory / per_worker_kib))
[ "$workers" -le "$cores" ] || workers=$cores
[ "$workers" -ge 1 ] || workers=1
echo "$workers"
