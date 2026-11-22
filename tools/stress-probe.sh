#!/bin/sh
# Proves that the stress loop, interrupted or terminated mid-round, leaves
# nothing running: neither the suite's run nor its limit guard, each of
# which the loop starts in a process group of its own, out of reach of the
# terminal's Ctrl-C:
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

[ -z "$failed" ] || exit 1
echo "stress-probe: the loop sent INT or TERM ended its suite's run and its guard, each with its group"
