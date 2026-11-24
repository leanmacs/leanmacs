#!/bin/sh
# The wiring set's ledger: what ran of the wiring set, as the runs said it,
# held against what the code lists (docs/dev-practices/real-thread-checks.md,
# "How stress runs the set"). The gate checks with it that `mise run ci`
# ran each module, entry and scenario of the wiring set exactly once, and
# the stress loop that each round ran each exactly once.
#
#   tools/wiring-ledger.sh note <ledger> <command> [<argument>...]
#   tools/wiring-ledger.sh expected
#   tools/wiring-ledger.sh list <listing>
#   tools/wiring-ledger.sh check <ledger> <expected>
#
# A run of the wiring set says what it ran in a line of its own on stdout:
#
#   wiring-set: ran <root> <module> <n> checks   a root's module of the
#                                                wiring set (config-test,
#                                                ffi-test, a linked test;
#                                                Editor.CheckGroup.ranLines)
#   wiring-set: ran contract-test ContractTest   contract-test, whole
#   wiring-set: ran <script or scenario> at <site>
#                                                a real-thread entry's CLI run
#                                                or a window scenario
#                                                (tools/wiring-runs.sh,
#                                                tools/bundle-test.sh)
#
# A line's key is what follows `wiring-set: ran `, its count of checks
# dropped: `<root> <module>`, or `<script> at <site>`.
#
# - `note` runs the command with its stdout passed through as it comes,
#   appends the command's `wiring-set: ran` lines to the ledger, and exits
#   with the command's status: how a gate step that runs an executable of
#   the wiring set writes the ledger.
# - `expected` prints the keys the gate must find, one a line, sorted and
#   each once, from code and from nothing else: `config-test
#   wiring-modules`, `ffi-test wiring-modules`, contract-test's root,
#   `tools/package-set.sh wiring-modules` over the fixture set and the
#   default set, `fixture-test real-thread --site ffi-test` and `ffi-test
#   wiring-scenarios`. Run it in `lean/` after the gate's builds. It exits
#   2, naming the command, when a listing fails: each listing's command
#   writes a file of its own and its status is checked before its lines
#   are read, so none is lost in a pipeline whose status is its last
#   command's.
# - `list <listing>` prints the keys of one listing, as `expected` reads
#   it, and exits 2 in the same way: `config-test` (`config-test
#   wiring-modules`), `ffi-test` (`ffi-test wiring-modules`),
#   `contract-test`, `linked` (`tools/package-set.sh wiring-modules` over
#   the fixture set and the default set), `scenarios` (`ffi-test
#   wiring-scenarios`) and `real-thread-<site>` (`fixture-test real-thread
#   --site <site>`). The stress loop's prepare stage reads each suite's
#   items with it (tools/stress.sh).
# - `check` exits 1, saying why, when a key of the ledger occurs twice, when
#   a key of `expected` has no line, or when a line's key is not expected;
#   and 0, saying how many it found once each, otherwise.
#
# tests/wiring-ledger/ holds its check's fixtures, which ffi-test checks it
# against, and tools/wiring-ledger-probe.sh runs `expected` and `list` over
# stand-in listings, one failing at a time.
set -eu

usage() {
  echo "usage: tools/wiring-ledger.sh note <ledger> <command> [<argument>...]" >&2
  echo "       tools/wiring-ledger.sh expected" >&2
  echo "       tools/wiring-ledger.sh list config-test|ffi-test|contract-test|linked|scenarios|real-thread-<site>" >&2
  echo "       tools/wiring-ledger.sh check <ledger> <expected>" >&2
  exit 2
}

# The keys of the `wiring-set: ran` lines on stdin, one a line, in order.
keys() {
  sed -n 's/^wiring-set: ran //p' | sed 's/ [0-9][0-9]* checks$//'
}

# Runs the listing command after $1, its output into the file $1; exits 2,
# naming the command, when it fails. A command of its own, so its status is
# its own and not a pipeline's last command's.
listing_into() {
  file=$1
  shift
  "$@" >"$file" || {
    echo "wiring-ledger: a listing of the wiring set failed: $*" >&2
    exit 2
  }
}

# Prints the keys of the listing $1 (`list`), its raw output in the file $2.
listing() {
  raw=$2
  case $1 in
    config-test)
      listing_into "$raw" .lake/build/bin/config-test wiring-modules
      sed 's/^/config-test /' "$raw"
      ;;
    ffi-test)
      listing_into "$raw" .lake/build/bin/ffi-test wiring-modules
      sed 's/^/ffi-test /' "$raw"
      ;;
    contract-test)
      echo 'contract-test ContractTest'
      ;;
    linked)
      for set in ../tests/packages ../packages; do
        listing_into "$raw" sh ../tools/package-set.sh wiring-modules "$set"
        tr '\t' ' ' <"$raw"
      done
      ;;
    scenarios)
      listing_into "$raw" .lake/build/bin/ffi-test wiring-scenarios
      sed 's/$/ at ffi-test/' "$raw"
      ;;
    real-thread-?*)
      site=${1#real-thread-}
      listing_into "$raw" ../packages/.lake/build/bin/fixture-test real-thread --site "$site"
      cut -f1 "$raw" | sed "s/\$/ at $site/"
      ;;
    *) usage ;;
  esac
}

[ "$#" -ge 1 ] || usage
command=$1
shift
case $command in
  note)
    [ "$#" -ge 2 ] || usage
    ledger=$1
    shift
    status_file=$(mktemp)
    out_file=$(mktemp)
    trap 'rm -f "$status_file" "$out_file"' EXIT
    { "$@" || echo "$?" >"$status_file"; } | tee "$out_file"
    grep '^wiring-set: ran ' "$out_file" >>"$ledger" || true
    if [ -s "$status_file" ]; then
      exit "$(cat "$status_file")"
    fi
    ;;
  expected)
    [ "$#" -eq 0 ] || usage
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT
    : >"$work/listed"
    # Each listing a command of its own, appending to the file: one that
    # fails ends the script with status 2 (`listing_into`).
    for name in config-test ffi-test contract-test linked real-thread-ffi-test scenarios; do
      listing "$name" "$work/raw" >>"$work/listed"
    done
    sort -u "$work/listed"
    ;;
  list)
    [ "$#" -eq 1 ] || usage
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT
    listing "$1" "$work/raw"
    ;;
  check)
    [ "$#" -eq 2 ] || usage
    ledger=$1
    expected=$2
    [ -f "$ledger" ] || {
      echo "wiring-ledger: no ledger $ledger" >&2
      exit 2
    }
    [ -f "$expected" ] || {
      echo "wiring-ledger: no list of expected items $expected" >&2
      exit 2
    }
    failed=
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT
    keys <"$ledger" | grep . >"$work/found" || true
    grep . "$expected" | sort -u >"$work/expected" || true
    sort -u "$work/found" >"$work/ran"
    twice=$(sort "$work/found" | uniq -d)
    if [ -n "$twice" ]; then
      printf '%s\n' "$twice" | sed 's/^/wiring-ledger: ran twice: /' >&2
      failed=1
    fi
    missing=$(comm -13 "$work/ran" "$work/expected")
    if [ -n "$missing" ]; then
      printf '%s\n' "$missing" | sed 's/^/wiring-ledger: did not run: /' >&2
      failed=1
    fi
    extra=$(comm -23 "$work/ran" "$work/expected")
    if [ -n "$extra" ]; then
      printf '%s\n' "$extra" | sed 's/^/wiring-ledger: ran and not expected: /' >&2
      failed=1
    fi
    [ -z "$failed" ] || exit 1
    echo "wiring-ledger: each of the $(grep -c . "$work/expected") items of the wiring set ran once"
    ;;
  *) usage ;;
esac
