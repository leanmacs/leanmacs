#!/usr/bin/env bash
# Milestone 1, measured headless: `mise run milestone-bench`
# (docs/dev-practices/on-demand-checks.md, "Milestone 1, measured").
#
# Runs five scripts of `editor headless --render` under `/usr/bin/time`,
# each in a temporary directory removed by a trap, and prints what each
# gives: start (a frame of 1280 by 800, no file), open (`:e` on a generated
# 10 MiB file), scroll (300 `C-f` on it, then `G`), type (200 `l` and `h`
# in a 640 by 480 view of a small file), each key paced by `idle 0`,
# and idle (`idle 30000` against `idle 0`). Then type-insert: 200
# characters typed in insert state at the end of the 10 MiB file and of the
# small file, each paced by `idle 0`, once with `--state` (the session
# journal written as they are typed, docs/design/concurrency.md, "The
# session journal") and once without, with the bytes the run left under the
# state directory's journals. It asserts nothing: its figures
# are handed back with the command and the machine line it prints. They are
# headless figures: the cell shaper, the CPU renderer, and no glyphs drawn.
#
# `$1` is the core's directory, `lean/`: the built editor is the default
# package set's, beside it (`packages/.lake/build/bin/editor`), and the
# `.olean` files are the core's.
set -euo pipefail

lean_dir=$(cd "$1" && pwd)
editor="$lean_dir/../packages/.lake/build/bin/editor"
sysroot=$(cd "$lean_dir" && lean --print-prefix)
oleans="$lean_dir/.lake/build/lib/lean"
config="$lean_dir/../tests/headless/config"
small="$lean_dir/../tests/bench/milestone/source.txt"

dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT

case "$(uname -s)" in
Darwin)
  machine="$(sysctl -n machdep.cpu.brand_string), $(sw_vers -productName) $(sw_vers -productVersion)"
  timed=(/usr/bin/time -l)
  ;;
*)
  machine="$(uname -srm)"
  timed=(/usr/bin/time -v)
  ;;
esac
echo "machine: $machine"
echo "label: headless: cell shaper, CPU renderer, no glyphs"

# The 10 MiB file: 201,650 lines of 52 bytes, 10,485,800 bytes.
awk 'BEGIN{for(i=0;i<201650;i++) printf "%07d the quick brown fox jumps over the lazy dog\n", i}' >"$dir/ten.txt"
cp "$small" "$dir/small.txt"

# The lines of a script that open `$1` with `:e` and wait for the load.
opens() {
  printf 'key : Semicolon shift\ncommit e %s\nkey <Enter> Enter -\njoin\nsettle\n' "$1"
}

{
  printf 'resize 1280 800\nsettle\n'
} >"$dir/start"
{
  printf 'resize 1280 800\n'
  opens "$dir/ten.txt"
} >"$dir/open"
{
  printf 'resize 1280 800\n'
  opens "$dir/ten.txt"
  printf 'journal\n'
  for _ in $(seq 300); do printf 'key f KeyF control\nidle 0\n'; done
  printf 'journal\nkey G KeyG shift\nidle 0\njournal\n'
} >"$dir/scroll"
{
  printf 'resize 640 480\n'
  opens "$dir/small.txt"
  printf 'journal\n'
  for _ in $(seq 100); do printf 'key l KeyL -\nidle 0\nkey h KeyH -\nidle 0\n'; done
  printf 'journal\n'
} >"$dir/type"
for period in 0 30000; do
  {
    printf 'resize 640 480\n'
    opens "$dir/small.txt"
    printf 'idle %s\n' "$period"
  } >"$dir/idle-$period"
done

# Runs the script `$1` and prints its figures: the lines `journal` and
# `idle` printed, the run's real, user and system time, its maximum resident
# set and, on macOS, its peak memory footprint.
measure() {
  local name=$1 out=$dir/$1.out times=$dir/$1.time
  "${timed[@]}" "$editor" headless --render "$sysroot" "$oleans" "$config" "$dir/$name" >"$out" 2>"$times"
  # A key is paced by `idle 0`, which waits until the render loop has drawn
  # it and is at rest, so that each key's frame is drawn and none replaces
  # another in the mailbox; those lines say nothing and are left out.
  grep -E '^(journal|idle)' "$out" | grep -v '^idle 0:' | sed "s|^|$name: |" || true
  if [ "$(uname -s)" = Darwin ]; then
    awk -v name="$name" '
      / real / { printf "%s: real %s s, user %s s, sys %s s\n", name, $1, $3, $5 }
      /maximum resident set size/ { printf "%s: maximum resident set %s bytes\n", name, $1 }
      /peak memory footprint/ { printf "%s: peak memory footprint %s bytes\n", name, $1 }' "$times"
  else
    grep -E 'Elapsed|User time|System time|Maximum resident' "$times" | sed "s|^[[:space:]]*|$name: |"
  fi
}

for name in start open scroll type idle-0 idle-30000; do
  measure "$name"
done

# type-insert: with a state directory a run restores first, and a change to
# the session index waits on the clock to be written, so each `join` there
# is preceded by `advance`, which fires the write.
for file in ten small; do
  for kept in state none; do
    {
      printf 'resize 1280 800\n'
      # The restore writes the first index: fired and waited for first, so
      # the open's write is the one fired next.
      if [ "$kept" = state ]; then printf 'advance 500\njoin\n'; fi
      printf 'key : Semicolon shift\ncommit e %s\nkey <Enter> Enter -\n' "$dir/$file.txt"
      if [ "$kept" = state ]; then printf 'advance 500\n'; fi
      printf 'join\nsettle\nkey G KeyG shift\nidle 0\nkey A KeyA shift\nidle 0\njournal\n'
      for _ in $(seq 200); do printf 'key x KeyX -\nidle 0\n'; done
      printf 'journal\n'
      if [ "$kept" = state ]; then printf 'journalled\n'; fi
    } >"$dir/type-insert-$file-$kept"
  done
done

# Runs the script `type-insert-$1-$2`, with a state directory of its own
# when `$2` is `state`, and prints its figures as `measure` does, then the
# bytes left under the state directory's journals.
measure_insert() {
  local name=type-insert-$1-$2 out=$dir/type-insert-$1-$2.out times=$dir/type-insert-$1-$2.time
  local state=()
  if [ "$2" = state ]; then state=(--state "$dir/state-$1"); fi
  if ! "${timed[@]}" "$editor" headless --render ${state[@]+"${state[@]}"} "$sysroot" "$oleans" "$config" "$dir/$name" >"$out" 2>"$times"; then
    echo "$name: the run failed: $(grep '^editor:' "$times" | head -n 1)"
  fi
  grep -E '^journal' "$out" | sed "s|^|$name: |" || true
  if [ "$(uname -s)" = Darwin ]; then
    awk -v name="$name" '/ real / { printf "%s: real %s s, user %s s, sys %s s\n", name, $1, $3, $5 }' "$times"
  else
    grep -E 'Elapsed|User time|System time' "$times" | sed "s|^[[:space:]]*|$name: |"
  fi
  if [ "$2" = state ]; then
    echo "$name: journals hold $(find "$dir/state-$1/session/journals" -type f -exec cat {} + | wc -c | tr -d ' ') bytes"
  fi
}

for file in ten small; do
  for kept in state none; do
    measure_insert "$file" "$kept"
  done
done
