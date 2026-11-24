#!/bin/sh
# Proves that the stress loop, interrupted or terminated mid-round, leaves
# nothing running: neither the suite's run nor its limit guard, each of
# which the loop starts in a process group of its own, out of reach of the
# terminal's Ctrl-C; and that a run past the loop's limit is killed with its
# whole group and fails as a hang:
#
#   sh tools/stress-probe.sh    # run first by `mise run stress`
#
# For INT and then TERM it runs `tools/stress.sh 1 probe` with one hog. The
# stand-in suite (`probe`, the command in STRESS_PROBE) starts a child, waits
# until the guard has started, and sends the loop the signal. The guard's
# `sleep` is a stand-in too, put first on the PATH the loop is given: it says
# it has started and waits. The stand-ins wait for the release, the end of
# a pipe this probe holds open until the loop has exited. A stand-in that
# gets it has outlived the loop, and says so on a second pipe, which every
# process the loop started holds open. The probe reads that pipe to its end,
# which comes once each of them has exited, and fails on any line read from
# it, or when the loop did not exit 130 on INT or 143 on TERM. Run against
# a loop whose trap killed only its hogs, it failed on both signals with
# all three stand-ins still running.
#
# Then the limit, on a suite that hangs and a guard's sleep that returns
# once the suite has started (below). Run against a guard that killed only
# the run's leader, it failed with the suite's run and its child still
# running; against one that killed nothing, on every count, once its hang
# guard had run out.
#
# The loop sends TERM to each group before it exits, so a process of it
# never runs again and never reads the release. Nothing here waits for a
# time but the release's hang guard. It needs no build, leaves nothing
# running and nothing behind (docs/dev-practices/on-demand-checks.md, "The
# stress loop, on demand"). It is for macOS's sh and Linux's dash alike.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failed=

fail() {
  printf 'stress-probe: FAIL: %s\n' "$1" >&2
  failed=1
}

# The guard's sleep: it says it has started, on the fifo STRESS_PROBE_GUARD,
# and waits for the release on fd 3; then, if it is still running, it says
# so on fd 4.
mkdir "$work/bin"
cat >"$work/bin/sleep" <<'EOF'
#!/bin/sh
echo started >"$STRESS_PROBE_GUARD"
read -r _ <&3 || true
echo "the guard's sleep outlived the loop" >&4
EOF
chmod +x "$work/bin/sleep"

# The suite: a child that waits for the release as the suite does, the
# guard's start waited for, and the loop sent the signal; then, as the guard's
# sleep does, the wait for the release, and what outlived the loop said.
suite='
{ read -r _ <&3 || true; echo "a child of the suite run outlived the loop" >&4; } &
read -r _ <"$STRESS_PROBE_GUARD"
kill -s "$STRESS_PROBE_SIGNAL" "$(cat "$STRESS_PROBE_LOOP")"
read -r _ <&3 || true
echo "the suite run outlived the loop" >&4
wait'

for signal in INT TERM; do
  case $signal in INT) expected=130 ;; TERM) expected=143 ;; esac
  dir="$work/$signal"
  mkdir "$dir"
  mkfifo "$dir/guard"
  # The release is the pipe out of the holder, which says its pid on it and
  # then sleeps; the loop runs with it as fd 3 and the pipe into `cat` as
  # fd 4, and the holder is killed once the loop has exited. The pipes are
  # anonymous: a fifo's end of file reaches only one of the readers blocked
  # on it on macOS. The pipeline ends once `cat` has read to the end of fd
  # 4, so once every process the loop started has exited.
  # hang guard: the holder's sleep. Only a loop that does not end on the
  # signal reaches it: its stand-ins are released, its round ends, and the
  # loop's exit status then fails the probe.
  # The holder's death by TERM, which dash reports, is no news.
  { sh -c 'echo "$$" && exec sleep 60'; } 2>/dev/null |
    {
      read -r holder
      exec 3<&0 </dev/null 4>&1 >"$dir/output" 2>&1
      status=0
      STRESS_PROBE=$suite STRESS_PROBE_SIGNAL=$signal STRESS_PROBE_LOOP=$dir/loop \
        STRESS_PROBE_GUARD=$dir/guard STRESS_HOGS=1 STRESS_OUT=$dir/out PATH="$work/bin:$PATH" \
        sh -c 'echo "$$" >"$1" && shift && exec sh "$@"' loop "$dir/loop" \
        "$root/tools/stress.sh" 1 probe || status=$?
      echo "$status" >"$dir/status"
      kill "$holder" 2>/dev/null || true
    } |
    cat >"$dir/said"
  status=$(cat "$dir/status")
  if [ "$status" -ne "$expected" ]; then
    fail "the loop sent $signal exited $status, not $expected"
    sed 's/^/  /' "$dir/output" >&2
  fi
  if [ -s "$dir/said" ]; then
    fail "the loop sent $signal left processes running:"
    sed 's/^/  /' "$dir/said" >&2
  fi
done

# The limit: `STRESS_LIMIT=1 tools/stress.sh 1 probe` on a suite that hangs,
# a child of it hanging too: both wait for the release, which comes only
# once the loop has exited. The guard's sleep is a stand-in that returns once
# the suite has said it has started, so its group is there to be killed.
# The loop must count the run as failed, as a hang: exit 1, the guard's line
# in the run's log, `probe: 0/1`, and nothing of the run left to say it
# outlived the loop. Read and judged as the INT and TERM cases are.
mkdir "$work/limit-bin"
cat >"$work/limit-bin/sleep" <<'EOF'
#!/bin/sh
read -r _ <"$STRESS_PROBE_GUARD"
EOF
chmod +x "$work/limit-bin/sleep"
hung='
{ read -r _ <&3 || true; echo "a child of the hung run outlived the loop" >&4; } &
echo started >"$STRESS_PROBE_GUARD"
read -r _ <&3 || true
echo "the hung run outlived the loop" >&4
wait'
dir="$work/limit"
mkdir "$dir"
mkfifo "$dir/guard"
# hang guard: the holder's sleep, as above. Only a guard that does not kill
# the run's group reaches it: the run is then released and passes.
{ sh -c 'echo "$$" && exec sleep 60'; } 2>/dev/null |
  {
    read -r holder
    exec 3<&0 </dev/null 4>&1 >"$dir/output" 2>&1
    status=0
    STRESS_PROBE=$hung STRESS_PROBE_GUARD=$dir/guard STRESS_LIMIT=1 STRESS_HOGS=1 \
      STRESS_OUT=$dir/out PATH="$work/limit-bin:$PATH" \
      sh "$root/tools/stress.sh" 1 probe || status=$?
    echo "$status" >"$dir/status"
    kill "$holder" 2>/dev/null || true
  } |
  cat >"$dir/said"
status=$(cat "$dir/status")
if [ "$status" -ne 1 ]; then
  fail "the loop whose run hung past its limit exited $status, not 1"
  sed 's/^/  /' "$dir/output" >&2
fi
if ! grep -qx 'stress: a hang: probe had not ended within 1 s and was killed' "$dir/out/probe-1.log" 2>/dev/null; then
  fail "the hung run's log does not say it was killed as a hang:"
  sed 's/^/  /' "$dir/out/probe-1.log" >&2 2>/dev/null || true
fi
if ! grep -qx 'probe: 0/1' "$dir/output"; then
  fail "the loop whose run hung past its limit did not count it failed:"
  sed 's/^/  /' "$dir/output" >&2
fi
if [ -s "$dir/said" ]; then
  fail "the loop whose run hung past its limit left processes running:"
  sed 's/^/  /' "$dir/said" >&2
fi

# A hang line fails a run that exits 0: a probe suite that says `a hang:`
# and exits 0 must give `probe: 0/1`, its hang line listed, and the loop
# exit 1. Run against a loop that judged a run by its exit status alone, it
# gave `probe: 1/1`.
dir="$work/hang-line"
mkdir "$dir"
status=0
STRESS_PROBE='echo "editor: a hang: a stand-in guard ran out"; exit 0' STRESS_HOGS=1 \
  STRESS_OUT=$dir/out sh "$root/tools/stress.sh" 1 probe >"$dir/output" 2>&1 || status=$?
if [ "$status" -ne 1 ] || ! grep -qx 'probe: 0/1' "$dir/output" ||
  ! grep -qx '  editor: a hang: a stand-in guard ran out' "$dir/output"; then
  fail "the loop did not fail a run that exited 0 with a hang line in its log (exit $status):"
  sed 's/^/  /' "$dir/output" >&2
fi

# Coverage: a probe suite that runs and prints nothing of the wiring set,
# against an expected item it does not print (STRESS_PROBE_EXPECTED), must
# give `probe: 1/1` and `coverage: 0/1`, the item listed as not run, and
# the loop exit 1. Run against a loop with no coverage check, it passed.
# The same suite saying the item once must pass both.
dir="$work/coverage"
mkdir "$dir"
echo 'probe-root Probe.Module' >"$dir/expected"
status=0
STRESS_PROBE='echo "the probe ran nothing of the wiring set"' STRESS_PROBE_EXPECTED=$dir/expected \
  STRESS_HOGS=1 STRESS_OUT=$dir/out sh "$root/tools/stress.sh" 1 probe >"$dir/output" 2>&1 || status=$?
if [ "$status" -ne 1 ] || ! grep -qx 'probe: 1/1' "$dir/output" || ! grep -qx 'coverage: 0/1' "$dir/output" ||
  ! grep -qx '  wiring-ledger: did not run: probe-root Probe.Module' "$dir/output"; then
  fail "the loop did not fail the coverage of a round that missed an expected item (exit $status):"
  sed 's/^/  /' "$dir/output" >&2
fi
dir="$work/covered"
mkdir "$dir"
echo 'probe-root Probe.Module' >"$dir/expected"
status=0
STRESS_PROBE='echo "wiring-set: ran probe-root Probe.Module 1 checks"' STRESS_PROBE_EXPECTED=$dir/expected \
  STRESS_HOGS=1 STRESS_OUT=$dir/out sh "$root/tools/stress.sh" 1 probe >"$dir/output" 2>&1 || status=$?
if [ "$status" -ne 0 ] || ! grep -qx 'coverage: 1/1' "$dir/output"; then
  fail "the loop did not pass the coverage of a round that ran its expected item once (exit $status):"
  sed 's/^/  /' "$dir/output" >&2
fi

# A listing that fails ends the loop in its prepare stage: a probe suite
# whose expected items cannot be read (STRESS_PROBE_EXPECTED names no file)
# must make the loop exit 2, naming the listing, before any round, so the
# suite never runs. Run against a prepare stage that piped each listing
# into its keys, the loop ran the round and passed its coverage over no
# item at all.
dir="$work/listing"
mkdir "$dir"
status=0
STRESS_PROBE="echo ran >'$dir/ran'" STRESS_PROBE_EXPECTED=$dir/missing \
  STRESS_HOGS=1 STRESS_OUT=$dir/out sh "$root/tools/stress.sh" 1 probe >"$dir/output" 2>&1 || status=$?
if [ "$status" -ne 2 ] || [ -e "$dir/ran" ] ||
  ! grep -qxF "stress: prepare: a listing of the wiring set failed: sed /^\$/d $dir/missing" "$dir/output"; then
  fail "the loop did not end in its prepare stage, with status 2, when a listing failed (exit $status):"
  sed 's/^/  /' "$dir/output" >&2
fi

[ -z "$failed" ] || exit 1
echo "stress-probe: the loop sent INT or TERM ended its suite's run and its guard, each with its group; a run past its limit was killed with its group and failed as a hang; a run with a hang line failed though it exited 0; a round that missed an item of the wiring set failed its coverage; and a listing that failed ended the loop before its first round"
