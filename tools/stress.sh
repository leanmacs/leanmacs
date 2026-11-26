#!/bin/sh
# The stress loop, run by `mise run stress` (and in the Linux container by
# `mise run linux-stress`): the wiring set, the checks and runs that wire a
# real thread or service, run over and over under a CPU load twice the
# machine's cores, at lowered priority, so a check whose result hangs on
# scheduling or on the machine's speed shows itself. Opt-in, never part of
# `ci` or hk (docs/dev-practices/on-demand-checks.md, "The stress loop, on
# demand"; docs/dev-practices/real-thread-checks.md, "How the set
# runs").
#
#   sh tools/stress.sh <rounds> [suite ...]
#
# Run it from the checkout after `mise run ci` has built everything; it
# builds nothing. The suites, each run once a round, in this order:
#
#   config-wiring  config-test --wiring: its check set's wiring groups
#   ffi-wiring     ffi-test wiring, then the window scenarios
#                  (tools/wiring-runs.sh run <prepared> scenarios)
#   contract       contract-test, as the gate runs it
#   linked-wiring  each linked test's wiring groups, over the fixture set,
#                  which names every default package too, so each linked
#                  test runs once (tools/package-set.sh --wiring run)
#   cli-wiring     the real-thread entries at ffi-test, through the CLI
#                  (tools/wiring-runs.sh run <prepared> fixtures)
#   bundle-wiring  the entries at bundle-test, over a staged bundle
#                  (tools/bundle-test.sh headless <prepared>/bundle)
#   rust           cargo test --workspace --locked (opt-in)
#   gate-ffi       mise run ffi-test, whole (opt-in, slow)
#   probe          the shell command in STRESS_PROBE: a stand-in suite, for
#                  tools/stress-probe.sh alone (opt-in)
#
# With no suite named it runs the six wiring suites: the wiring set, read
# from code (the roots' check sets, which linter.wiringSet holds complete,
# FfiTest.windowScenarios and the real-thread set's entries), with no list
# here. Before the hogs start, a prepare stage stages what the chosen
# suites build before their runs, once (tools/wiring-runs.sh prepare,
# tools/bundle-test.sh stage, and for `probe` the command in
# STRESS_PROBE_STAGE, a stand-in for what is staged, if it is set), into a
# temporary directory of its own, never under the logs, which the loop
# removes when it ends, however it ends.
#
# The load is `2 x cores` processes of `yes >/dev/null` (cores from
# `sysctl -n hw.ncpu` on macOS, `nproc` elsewhere; STRESS_HOGS overrides),
# started before the first round and killed by a trap on EXIT, INT and TERM,
# which first ends the round's suite run and its limit guard, each with its
# whole process group (tools/stress-probe.sh proves it).
# Each suite runs in the foreground under `taskpolicy -c utility` on macOS
# and `nice -n 5` elsewhere, so the hogs win the CPU. The Linux niceness is
# measured, not the lowest there is: at `nice -n 19` against hogs at 0 the
# suite's threads weigh 15 against 1024 each, config-test ran 200 to 400
# times slower and could not end inside STRESS_LIMIT, so the loop proved
# nothing; at 5 it runs about 7 times slower, near the 11 times of macOS's
# utility class, which the hang guards are sized on
# (docs/dev-practices/on-demand-checks.md, "The stress loop, on demand").
# Each run's output goes
# to `$STRESS_OUT/<suite>-<round>.log` (a fresh temporary directory when
# STRESS_OUT is unset), and config-test's wall time for each check to
# `config-wiring-<round>.timings` beside it (`config-test --timings`), which
# the hang guards are sized from. A run that has not ended within STRESS_LIMIT seconds
# (30 minutes) is killed with its whole process group and counts as failed,
# its log ending `stress: a hang: ...`, so a hang shows as a failure (the
# probe proves that too). Each run passes or fails by its exit status
# alone; nothing reads its log to decide. At the end it prints `<suite>:
# <passed>/<rounds>` for each suite, then each failing run with the names
# of the checks and tests that failed and its hang lines, for people, and
# exits 1 on any failure. Nothing is left running.
#
# A failure is a bug in a check or in the code. It is fixed and the loop is
# run again from round 1, never retried away.
set -eu

usage() {
  echo "usage: tools/stress.sh <rounds> [config-wiring|ffi-wiring|contract|linked-wiring|cli-wiring|bundle-wiring|rust|gate-ffi ...]" >&2
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
suites=${*:-config-wiring ffi-wiring contract linked-wiring cli-wiring bundle-wiring}
for suite in $suites; do
  case "$suite" in
    config-wiring | ffi-wiring | contract | linked-wiring | cli-wiring | bundle-wiring | rust | gate-ffi | probe) ;;
    *) usage ;;
  esac
done

root=$(git rev-parse --show-toplevel)
if [ -z "$single" ]; then
  out=${STRESS_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/stress.XXXXXXXX")}
  mkdir -p "$out"
  # Absolute: config-test is handed a file beside its log from `lean/`.
  out=$(cd "$out" && pwd)
fi
prepared=${STRESS_PREPARED:-}

# Whether the suite $1 is among those chosen.
chosen() {
  case " $suites " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

if [ "$(uname -s)" = Darwin ]; then
  cores=$(sysctl -n hw.ncpu)
  low() { taskpolicy -c utility "$@"; }
else
  cores=$(nproc)
  low() { nice -n 5 "$@"; }
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
# for; then the hogs; and last removes what the prepare stage staged, once
# nothing that reads it is left running.
stop() {
  for group in $run $guard; do end_group "$group"; done
  for group in $run $guard; do wait "$group" 2>/dev/null || true; done
  run=
  guard=
  for pid in $pids; do kill "$pid" 2>/dev/null || true; done
  for pid in $pids; do wait "$pid" 2>/dev/null || true; done
  pids=
  if [ -z "$single" ] && [ -n "$prepared" ]; then
    rm -rf "$prepared"
    prepared=
  fi
}
trap stop EXIT
trap 'stop; exit 130' INT
trap 'stop; exit 143' TERM

# What the prepare stage stages (about 4 GB: the bundle and the greeting's
# install), which a bounded run (`--run`) reads: a fresh temporary
# directory of its own, never under $out, the logs stress.yml uploads, and
# removed by `stop` when the loop ends, however it ends
# (tools/stress-probe.sh).
if [ -z "$single" ]; then
  prepared=$(mktemp -d "${TMPDIR:-/tmp}/stress-prepared.XXXXXXXX")
  STRESS_PREPARED=$prepared
  export STRESS_PREPARED
fi

prefix=
for suite in config-wiring linked-wiring; do
  if chosen "$suite"; then
    prefix=$(cd "$root/lean" && lean --print-prefix)
  fi
done

# Runs one suite once, in the foreground, its output to the file $1.
run_suite() {
  log=$1
  case "$2" in
  config-wiring)
    (cd "$root/lean" && low .lake/build/bin/config-test "$prefix" .lake/build/lib/lean ../tests/syntax ../config/default ../packages . ../tests/config-package/lsp ../tests/config-migrate/migrated --wiring --timings "${log%.log}.timings") >"$log" 2>&1 ;;
  ffi-wiring)
    (cd "$root/lean" && low sh -c 'status=0
      .lake/build/bin/ffi-test wiring || status=$?
      sh ../tools/wiring-runs.sh run "$1" scenarios || status=$?
      exit "$status"' ffi-wiring "$prepared/runs") >"$log" 2>&1 ;;
  contract)
    (cd "$root/lean" && low .lake/build/bin/contract-test ../tests/process-environment ../tests/syntax ../tests/completion ../tests/launch) >"$log" 2>&1 ;;
  linked-wiring)
    (cd "$root/lean" && low sh ../tools/package-set.sh --wiring run ../tests/packages "$prefix" .lake/build/lib/lean) >"$log" 2>&1 ;;
  cli-wiring)
    (cd "$root/lean" && low sh ../tools/wiring-runs.sh run "$prepared/runs" fixtures) >"$log" 2>&1 ;;
  bundle-wiring)
    (cd "$root/lean" && low sh ../tools/bundle-test.sh headless "$prepared/bundle") >"$log" 2>&1 ;;
  rust)
    (cd "$root" && low cargo test --workspace --locked) >"$log" 2>&1 ;;
  gate-ffi)
    (cd "$root" && low mise run ffi-test) >"$log" 2>&1 ;;
  probe)
    sh -c "${STRESS_PROBE:?the probe suite runs STRESS_PROBE}" >"$log" 2>&1 ;;
  esac
}

# The prepare stage (the header): what the chosen suites build before their
# runs, staged once into $prepared. It runs before the hogs start, at the
# machine's own priority, and builds nothing the gate did not. A step that
# fails ends the loop before a hog or a round starts (tools/stress-probe.sh).
prepare() {
  if chosen ffi-wiring || chosen cli-wiring; then
    (cd "$root/lean" && sh ../tools/wiring-runs.sh prepare "$prepared/runs")
  fi
  if chosen bundle-wiring; then
    (cd "$root/lean" && sh ../tools/bundle-test.sh stage "$prepared/bundle")
  fi
  if chosen probe && [ -n "${STRESS_PROBE_STAGE:-}" ]; then
    sh -c "$STRESS_PROBE_STAGE"
  fi
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
echo "stress: prepare: staging the chosen suites' builds in $prepared"
prepare
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
  # For people: the checks' and tests' own failure lines and its hang
  # lines, or the end of the log. The run already failed by its status.
  names=$(grep -E '^FAILED: |^test .* FAILED$|^---- .* ----$|panicked at|a hang:' "$log" | head -20 || true)
  if [ -n "$names" ]; then
    printf '%s\n' "$names" | sed 's/^/  /'
  else
    tail -n 15 "$log" | sed 's/^/  /'
  fi
done
exit "$status"
