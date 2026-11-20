#!/usr/bin/env bash
# The app's identity across a restart, on this desktop: `mise run
# restart-check` (docs/dev-practices/on-demand-checks.md, "The restart on a
# desktop"; docs/design/lean-runtime.md, "The app's identity across an
# exec"). macOS only, opt-in, never part of the gate. It opens windows and
# needs no person.
#
# `mise run app` builds `packages/.lake/build/Leanmacs.app` first. In a
# temporary directory removed by a trap (with the copy unregistered from
# LaunchServices and any instance of it ended), this script:
#
# - copies the bundle there, sets the copy's `CFBundleIdentifier` to
#   `org.leanmacs.restart-check`, signs it again ad hoc and verifies it, so
#   the owner's `Leanmacs.app` and a running editor are never touched;
# - copies the copy's `Contents/MacOS/editor` to `elsewhere/editor`, an
#   editor outside the bundle; writes `bad`, which prints `probe: ok` for
#   `--probe` and otherwise exits 3; and writes the config
#   `tests/restart-check/config/init.lean` with `@ELSEWHERE@` and `@BAD@`
#   replaced, which restarts into the first on opening a `*.restart-elsewhere`
#   file and into the second on a `*.restart-bad` one, each for a buffer this
#   run opened;
# - A. launches the copy cold, `open -n -a <copy> --args --state S --config
#   C --sysroot … --oleans …`, the two module directories the copy's, given
#   so a restarted editor outside the bundle loads config too; waits for
#   LaunchServices to list an instance of the identifier, and records its
#   pid, P;
# - B. sends the copy an open-file event for `x.restart-elsewhere`
#   (`open -a <copy> <file>`): P's mode restarts into `elsewhere/editor`.
#   It waits for the hand-over record to appear and then go (the
#   hand-shake), and asserts exactly one instance of the identifier, with
#   pid P, `bundlepath` the copy and name `Leanmacs`, and that P's
#   executable is now `elsewhere/editor`: the exec after AppKit had checked
#   in kept the app's identity;
# - C. sends an open-file event for `after.txt`: within 10 s the newest
#   index lists it, so the event reached the executable outside the bundle;
# - D. sends one for `y.restart-bad`: P restarts into `bad`, which fails;
#   the launcher's watcher, a detached process LaunchServices did not
#   launch, starts the previous executable, `elsewhere/editor`, as a new
#   pid Q. It asserts the hand-shake, one instance of the identifier, with
#   pid Q and `bundlepath` the copy, and that an open-file event for
#   `after2.txt` reaches Q;
# - ends Q, and prints `restart-check: ok` with the pids and paths. A failure
#   names the step and what `lsappinfo` said, and exits 1.
#
# `$1` is the default package set's directory, `packages/`, whose build
# directory holds the bundle.
set -euo pipefail

if [ "$(uname -s)" != Darwin ]; then
  echo "restart-check: the app's identity is macOS only (this is $(uname -s))" >&2
  exit 2
fi

set_dir=$(cd "$1" && pwd)
config_template=$(cd "$set_dir/../tests/restart-check/config" && pwd)/init.lean
built="$set_dir/.lake/build/Leanmacs.app"
identifier=org.leanmacs.restart-check
[ -d "$built" ] || {
  echo "restart-check: no $built: run \`mise run app\`" >&2
  exit 1
}

dir=$(mktemp -d)
dir=$(cd "$dir" && pwd -P)
copy="$dir/Leanmacs.app"

# The application serial numbers of the instances of the identifier
# LaunchServices lists, one a line.
asns() {
  lsappinfo find "bundleid=$identifier" 2>/dev/null | grep -o 'ASN:0x[0-9a-f]*-0x[0-9a-f]*' || true
}

# What `lsappinfo info -only $2` says of the instance $1: its pid, its bundle
# path or its name.
info_of() {
  case "$2" in
  pid) lsappinfo info -only pid "$1" | sed -n 's/.*pid = \([0-9]*\).*/\1/p' ;;
  bundlepath) lsappinfo info -only bundlepath "$1" | sed -n 's/.*bundle path="\(.*\)".*/\1/p' ;;
  name) lsappinfo info -only name "$1" | sed -n 's/^"\(.*\)" ASN.*/\1/p' | head -n 1 ;;
  esac
}

# The pids of the instances of the identifier LaunchServices lists.
instances() {
  for asn in $(asns); do
    info_of "$asn" pid
  done
}

cleanup() {
  for pid in $(instances); do
    kill -9 "$pid" 2>/dev/null || true
  done
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$copy" 2>/dev/null || true
  rm -rf "$dir"
}
trap cleanup EXIT

fail() {
  echo "restart-check: $*" >&2
  echo "restart-check: lsappinfo says:" >&2
  lsappinfo find "bundleid=$identifier" >&2 || true
  for asn in $(asns); do
    lsappinfo info "$asn" >&2 || true
  done
  exit 1
}

# Waits up to $1 seconds for the command after it to succeed.
within() {
  local seconds=$1
  shift
  local tries=$((seconds * 20))
  while [ "$tries" -gt 0 ]; do
    if "$@"; then return 0; fi
    sleep 0.05
    tries=$((tries - 1))
  done
  return 1
}

# The one instance's pid, or a failure naming the step.
only_instance() {
  local pids
  pids=$(instances)
  [ "$(printf '%s\n' "$pids" | grep -c .)" -eq 1 ] || fail "$1: $(printf '%s' "$pids" | grep -c .) instances of $identifier, not one"
  printf '%s\n' "$pids"
}

# Whether the one instance of the identifier is pid $1, its bundle path the
# copy and its name Leanmacs.
is_the_copy() {
  local asn
  asn=$(asns | head -n 1)
  [ "$(info_of "$asn" pid)" = "$1" ] && [ "$(info_of "$asn" bundlepath)" = "$copy" ] &&
    [ "$(info_of "$asn" name)" = Leanmacs ]
}

# The newest index under the state directory.
newest_index() {
  ls "$state/session" 2>/dev/null | sed -n 's/^session-\([0-9]*\)\.json$/\1/p' | sort -n | tail -n 1 |
    sed 's/.*/session-&.json/'
}
index_lists() {
  local newest
  newest=$(newest_index)
  [ -n "$newest" ] && grep -qF "$1" "$state/session/$newest"
}
record="$dir/state/session/handover"
record_there() { [ -e "$record" ]; }
record_gone() { [ ! -e "$record" ]; }

# Set-up.
ditto "$built" "$copy"
plutil -replace CFBundleIdentifier -string "$identifier" "$copy/Contents/Info.plist"
/usr/bin/xattr -cr "$copy"
codesign --force --sign - "$copy"
codesign --verify --strict --deep "$copy" || fail "the copy does not verify"
mkdir "$dir/elsewhere" "$dir/files" "$dir/config"
cp "$copy/Contents/MacOS/editor" "$dir/elsewhere/editor"
elsewhere="$dir/elsewhere/editor"
bad="$dir/bad"
printf '#!/bin/sh\n[ "$1" = --probe ] && { echo "probe: ok"; exit 0; }\nexit 3\n' >"$bad"
chmod +x "$bad"
sed "s|@ELSEWHERE@|$elsewhere|; s|@BAD@|$bad|" "$config_template" >"$dir/config/init.lean"
state="$dir/state"
for name in x.restart-elsewhere y.restart-bad after.txt after2.txt; do
  printf '%s\n' "$name" >"$dir/files/$name"
done

# A. A cold launch.
# The bundle's .olean directories are the lines of its record, each under
# Contents/Resources (lean/Editor/ModuleLookup.lean, "The bundle's record").
oleans=$(sed "s|^|$copy/Contents/Resources/|" "$copy/Contents/Resources/editor.oleans" | paste -s -d : -)
open -n -a "$copy" --args --state "$state" --config "$dir/config" \
  --sysroot "$copy/Contents/Resources/lean/toolchain" --oleans "$oleans"
within 30 test -n "$(instances)" || fail "A: no instance of $identifier was listed"
P=$(only_instance A)
within 30 index_lists '"run":1' || fail "A: the first run wrote no index"
echo "restart-check: A. launched cold as pid $P"

# B. A restart into an executable outside the bundle, after AppKit checked in.
open -a "$copy" "$dir/files/x.restart-elsewhere"
within 20 record_there || fail "B: no hand-over record appeared"
within 30 record_gone || fail "B: the hand-over record was not removed: no hand-shake"
[ "$(only_instance B)" = "$P" ] || fail "B: the instance is not pid $P"
is_the_copy "$P" || fail "B: pid $P is not the copy, Leanmacs, to LaunchServices"
command=$(ps -o comm= -p "$P")
[ "$command" = "$elsewhere" ] || fail "B: pid $P runs $command, not $elsewhere"
echo "restart-check: B. pid $P restarted into $elsewhere, one instance, bundlepath $copy"

# C. An open-file event after the restart.
open -a "$copy" "$dir/files/after.txt"
within 10 index_lists after.txt || fail "C: the newest index does not list after.txt"
echo "restart-check: C. after.txt reached pid $P"

# D. The fallback, outside the bundle.
open -a "$copy" "$dir/files/y.restart-bad"
within 20 record_there || fail "D: no hand-over record appeared"
within 90 record_gone || fail "D: the hand-over record was not removed: no hand-shake"
within 20 test -n "$(instances)" || fail "D: no instance after the fallback"
Q=$(only_instance D)
[ "$Q" != "$P" ] || fail "D: the instance is still pid $P"
is_the_copy "$Q" || fail "D: pid $Q is not the copy, Leanmacs, to LaunchServices"
command=$(ps -o comm= -p "$Q")
[ "$command" = "$elsewhere" ] || fail "D: pid $Q runs $command, not $elsewhere"
open -a "$copy" "$dir/files/after2.txt"
within 10 index_lists after2.txt || fail "D: the newest index does not list after2.txt"
echo "restart-check: D. $bad failed, the watcher started $elsewhere as pid $Q, one instance, bundlepath $copy, and after2.txt reached it"

kill "$Q" 2>/dev/null || true
echo "restart-check: ok (P $P, Q $Q, $copy, $elsewhere)"
