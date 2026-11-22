#!/bin/sh
# The stress loop, run by `mise run stress` (and in the Linux container by
# `mise run linux-stress`): the gate's thread-heavy suites run over and over
# under a CPU load twice the machine's cores, at lowered priority, so a check
# whose result hangs on scheduling or on the machine's speed shows itself.
# Opt-in, never part of `ci` or hk (docs/dev-practices/on-demand-checks.md,
# "The stress loop, on demand").
#
#   sh tools/stress.sh <rounds> [suite ...]
#
# Run it from the checkout after `mise run ci` has built everything; it
# builds nothing. The suites, each run once a round, in this order:
#
#   config     config-test, as the gate runs it (from lean/)
#   contract   contract-test, as the gate runs it
#   rust       cargo test --workspace --locked
#   open-file  the open-file headless fixture, exactly as ffi-test runs it
#   ffi        mise run ffi-test, every headless fixture (slow)
#   probe      the shell command in STRESS_PROBE: a stand-in suite, for
#              tools/stress-probe.sh alone
#
# With no suite named it runs config, contract, rust and open-file.
#
# The load is `2 x cores` processes of `yes >/dev/null` (cores from
# `sysctl -n hw.ncpu` on macOS, `nproc` elsewhere; STRESS_HOGS overrides),
# started before the first round and killed by a trap on EXIT, INT and TERM,
# which first ends the round's suite run and its limit guard, each with its
# whole process group (tools/stress-probe.sh proves it).
# Each suite runs in the foreground under `taskpolicy -c utility` on macOS
# and `nice -n 19` elsewhere, so the hogs win the CPU. Each run's output goes
# to `$STRESS_OUT/<suite>-<round>.log` (a fresh temporary directory when
# STRESS_OUT is unset). A run that has not ended within STRESS_LIMIT seconds
# (30 minutes) is killed with its whole process group and counts as failed,
# its log ending `stress: a hang: ...`, so a hang shows as a failure (the
# probe proves that too). At the end it prints `<suite>: <passed>/<rounds>`
# for each suite, then each failing run with the names of the checks and tests
# that failed, and exits 1 on any failure. Nothing is left running.
#
# A failure is a bug in a check or in the code. It is fixed and the loop is
# run again from round 1, never retried away.
set -eu

usage() {
  echo "usage: tools/stress.sh <rounds> [config|contract|rust|open-file|ffi ...]" >&2
  exit 2
}

# `--run <log> <suite>` runs one suite once, as a round does: what a bounded
# run starts in a session of its own (`bounded`, below).
single=
if [ "${1:-}" = --run ]; then
  [ $# -eq 3 ] || usage
  single=$2
  set -- 1 "$3"
fi

[ $# -ge 1 ] || usage
rounds=$1
shift
case "$rounds" in '' | *[!0-9]*) usage ;; esac
[ "$rounds" -ge 1 ] || usage
suites=${*:-config contract rust open-file}
for suite in $suites; do
  case "$suite" in config | contract | rust | open-file | ffi | probe) ;; *) usage ;; esac
done

root=$(git rev-parse --show-toplevel)
if [ -z "$single" ]; then
  out=${STRESS_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/stress.XXXXXXXX")}
  mkdir -p "$out"
fi

if [ "$(uname -s)" = Darwin ]; then
  cores=$(sysctl -n hw.ncpu)
  low() { taskpolicy -c utility "$@"; }
else
  cores=$(nproc)
  low() { nice -n 19 "$@"; }
fi
hogs=${STRESS_HOGS:-$((2 * cores))}

# The round's suite run and its guard, each the leader of a process group
# of its own (`bounded`), while they run; and the hogs.
run=
guard=
pids=

# Sends TERM to the group the child $1 leads: to the child first, so one
# started but not yet in a group of its own (setsid has not run in it) ends
# too, then to the group.
end_group() {
  kill -TERM "$1" 2>/dev/null || true
  kill -TERM "-$1" 2>/dev/null || true
}

# Ends everything this script started: the round's run and its guard, each
# with its whole group, out of reach of a terminal's Ctrl-C, and waited
# for; then the hogs.
stop() {
  for group in $run $guard; do end_group "$group"; done
  for group in $run $guard; do wait "$group" 2>/dev/null || true; done
  run=
  guard=
  for pid in $pids; do kill "$pid" 2>/dev/null || true; done
  for pid in $pids; do wait "$pid" 2>/dev/null || true; done
  pids=
}
trap stop EXIT
trap 'stop; exit 130' INT
trap 'stop; exit 143' TERM

prefix=
case " $suites " in
*" config "* | *" open-file "*) prefix=$(cd "$root/lean" && lean --print-prefix) ;;
esac

# Runs one suite once, in the foreground, its output to the file $1.
run_suite() {
  log=$1
  case "$2" in
  config)
    (cd "$root/lean" && low .lake/build/bin/config-test "$prefix" .lake/build/lib/lean ../tests/syntax ../config/default) >"$log" 2>&1 ;;
  contract)
    (cd "$root/lean" && low .lake/build/bin/contract-test ../tests/process-environment ../tests/workspaces ../tests/shell ../tests/syntax ../tests/completion) >"$log" 2>&1 ;;
  rust)
    (cd "$root" && low cargo test --workspace --locked) >"$log" 2>&1 ;;
  open-file)
    (cd "$root/lean" && low sh -c '
      dir=$(mktemp -d /tmp/open-file.XXXXXXXX) && trap "rm -rf \"$dir\"" EXIT &&
      cp -R ../tests/headless/open-file/tree "$dir/tree" &&
      sed "s|@DIR@|$dir|g" ../tests/headless/open-file/script > "$dir/script" &&
      out=$(../packages/.lake/build/bin/editor headless "$1" .lake/build/lib/lean ../tests/headless/config "$dir/script") &&
      printf "%s\n" "$out" | sed "s|$dir|@DIR@|g" | diff ../tests/headless/open-file/expected -' open-file "$prefix") >"$log" 2>&1 ;;
  ffi)
    (cd "$root" && low mise run ffi-test) >"$log" 2>&1 ;;
  probe)
    sh -c "${STRESS_PROBE:?the probe suite runs STRESS_PROBE}" >"$log" 2>&1 ;;
  esac
}

# hang guard: each suite's run ending; only a hang reaches the limit, and
# that run then fails as a hang. A suite's run takes minutes under the load;
# STRESS_LIMIT (seconds) overrides the 30 minutes.
limit=${STRESS_LIMIT:-1800}

if [ -n "$single" ]; then
  trap - EXIT INT TERM
  run_suite "$single" "$suites"
  exit $?
fi

# Starts `$@` in a process group of its own; `started` is the group's id:
# `setsid` where there is one (Linux, where a script's shell has no job
# control), else the shell's job control (macOS).
grouped() {
  if command -v setsid >/dev/null 2>&1; then
    setsid "$@" &
  else
    set -m
    "$@" &
    set +m
  fi
  started=$!
}

# Runs one suite as run_suite does (this script's `--run`), in a process
# group of its own, and kills that group if it has not ended within $limit
# seconds, saying so in its log. The guard is killed with its own group once
# the run ends, so no sleep is left behind; once its sleep has returned it
# ignores TERM, so the run it kills ending first does not cut its line from
# the log (tools/stress-probe.sh's limit case, which a guard slowed between
# its kill and its line failed). Both are in `run` and `guard` while they
# run, for `stop`: an INT or TERM that comes while they start is held until
# both are there, then acted on.
bounded() {
  signalled=
  trap 'signalled=130' INT
  trap 'signalled=143' TERM
  grouped sh "$0" --run "$1" "$2"
  run=$started
  grouped sh -c 'sleep "$1" && trap "" TERM && kill -TERM "-$2" 2>/dev/null &&
    echo "stress: a hang: $3 had not ended within $1 s and was killed" >>"$4"' guard "$limit" "$run" "$2" "$1"
  guard=$started
  trap 'stop; exit 130' INT
  trap 'stop; exit 143' TERM
  if [ -n "$signalled" ]; then
    stop
    exit "$signalled"
  fi
  status=0
  wait "$run" || status=$?
  run=
  end_group "$guard"
  wait "$guard" 2>/dev/null || true
  guard=
  return "$status"
}

echo "stress: $rounds rounds of $suites, $hogs hogs on $cores cores, a limit of $limit s a run, logs in $out"
i=0
while [ "$i" -lt "$hogs" ]; do
  yes >/dev/null &
  pids="$pids $!"
  i=$((i + 1))
done

failures=
round=1
while [ "$round" -le "$rounds" ]; do
  for suite in $suites; do
    log="$out/$suite-$round.log"
    if bounded "$log" "$suite"; then
      echo "stress: round $round: $suite passed"
    else
      echo "stress: round $round: $suite FAILED ($log)"
      failures="$failures $suite-$round"
    fi
  done
  round=$((round + 1))
done
stop

status=0
for suite in $suites; do
  passed=0
  round=1
  while [ "$round" -le "$rounds" ]; do
    case " $failures " in *" $suite-$round "*) ;; *) passed=$((passed + 1)) ;; esac
    round=$((round + 1))
  done
  echo "$suite: $passed/$rounds"
done
for failure in $failures; do
  status=1
  log="$out/$failure.log"
  echo "failed: $failure ($log)"
  # The checks' and tests' own failure lines, or the end of the log.
  names=$(grep -E '^FAILED: |^test .* FAILED$|^---- .* ----$|panicked at' "$log" | head -20 || true)
  if [ -n "$names" ]; then
    printf '%s\n' "$names" | sed 's/^/  /'
  else
    tail -n 15 "$log" | sed 's/^/  /'
  fi
done
exit "$status"
