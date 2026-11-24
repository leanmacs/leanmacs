#!/bin/sh
# Proves that tools/wiring-ledger.sh's `expected` and `list` fail, with
# status 2 and the failing command named, when a listing of the wiring set
# fails, and lose none of a listing's keys when none does:
#
#   sh tools/wiring-ledger-probe.sh    # run by `mise run ffi-test`
#
# It runs the script in the `lean/` of a stand-in tree made in a temporary
# directory, whose executables are shell stand-ins for the listings the
# script runs there: config-test's and ffi-test's `wiring-modules`,
# ffi-test's `wiring-scenarios`, tools/package-set.sh's `wiring-modules`
# over each set and fixture-test's `real-thread --site <site>`. Each prints
# a canned key, or exits 3 when the file `fail-<name>` is beside the tree.
# With none failing, `expected` must print exactly the keys the stand-ins
# list, and `list` each listing's; then each stand-in is made to fail in
# turn, and `expected` and the `list` that reads it must each exit 2,
# naming it. Run against a script that piped each listing into its
# transform, `expected` passed with each failing listing's keys missing.
# It builds nothing and needs no build, writes only its temporary
# directory, and is for macOS's sh and Linux's dash alike.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failed=

fail() {
  printf 'wiring-ledger-probe: FAIL: %s\n' "$1" >&2
  failed=1
}

tree=$work/tree
mkdir -p "$tree/lean/.lake/build/bin" "$tree/packages/.lake/build/bin" "$tree/tools" \
  "$tree/tests/packages"

# Writes the stand-in $1, which, unless `fail-$2` is in the work directory,
# runs the shell code $3.
standin() {
  cat >"$1" <<STANDIN
#!/bin/sh
[ ! -e "$work/fail-$2" ] || exit 3
$3
STANDIN
  chmod +x "$1"
}

standin "$tree/lean/.lake/build/bin/config-test" config-test \
  '[ "$*" = wiring-modules ] || exit 2; echo ConfigTest.Wired'
standin "$tree/lean/.lake/build/bin/ffi-test" ffi-test \
  'case $* in wiring-modules) echo FfiTest.Wired ;; wiring-scenarios) [ ! -e "'"$work"'/fail-scenarios" ] || exit 3; echo window-wired ;; *) exit 2 ;; esac'
standin "$tree/tools/package-set.sh" package-set \
  'case $* in "wiring-modules ../tests/packages") set=fixture ;; "wiring-modules ../packages") set=default ;; *) exit 2 ;; esac; [ ! -e "'"$work"'/fail-package-set-$set" ] || exit 3; printf "%s\t%s\n" "$set-package" PackageTest.Wired'
standin "$tree/packages/.lake/build/bin/fixture-test" fixture-test \
  '[ "$1 $2" = "real-thread --site" ] || exit 2; printf "%s\t%s\n" "tests/headless/$3/script" "$3"'

# The keys `expected` must give, sorted.
: >"$work/want-expected"
for line in 'config-test ConfigTest.Wired' 'contract-test ContractTest' 'ffi-test FfiTest.Wired' \
  'fixture-package PackageTest.Wired' 'default-package PackageTest.Wired' \
  'tests/headless/ffi-test/script at ffi-test' 'window-wired at ffi-test'; do
  printf '%s\n' "$line" >>"$work/want-expected"
done
sort "$work/want-expected" -o "$work/want-expected"

# Runs the script with the arguments given, in the stand-in tree's `lean/`,
# its stdout into $work/out, its stderr into $work/err; its status into
# `status`.
ledger() {
  status=0
  (cd "$tree/lean" && sh "$root/tools/wiring-ledger.sh" "$@") >"$work/out" 2>"$work/err" ||
    status=$?
}

ledger expected
if [ "$status" -ne 0 ] || ! sort "$work/out" | cmp -s - "$work/want-expected"; then
  fail "expected, with no listing failing, exited $status and printed:"
  sed 's/^/  /' "$work/out" "$work/err" >&2
fi
for case in 'config-test:config-test ConfigTest.Wired' 'ffi-test:ffi-test FfiTest.Wired' \
  'contract-test:contract-test ContractTest' 'scenarios:window-wired at ffi-test' \
  'real-thread-bundle-test:tests/headless/bundle-test/script at bundle-test'; do
  name=${case%%:*}
  ledger list "$name"
  if [ "$status" -ne 0 ] || ! sort -u "$work/out" | grep -qxF "${case#*:}" ||
    [ "$(sort -u "$work/out" | grep -c .)" -ne 1 ]; then
    fail "list $name, with no listing failing, exited $status and printed:"
    sed 's/^/  /' "$work/out" "$work/err" >&2
  fi
done
ledger list linked
if [ "$status" -ne 0 ] || [ "$(cat "$work/out")" != "fixture-package PackageTest.Wired
default-package PackageTest.Wired" ]; then
  fail "list linked, with no listing failing, exited $status and printed:"
  sed 's/^/  /' "$work/out" "$work/err" >&2
fi

# Each listing failing in turn: its fail file, the listing `list` reads it
# as, and the command `expected` must name.
for case in \
  'config-test:config-test:.lake/build/bin/config-test wiring-modules' \
  'ffi-test:ffi-test:.lake/build/bin/ffi-test wiring-modules' \
  'scenarios:scenarios:.lake/build/bin/ffi-test wiring-scenarios' \
  'package-set-fixture:linked:sh ../tools/package-set.sh wiring-modules ../tests/packages' \
  'package-set-default:linked:sh ../tools/package-set.sh wiring-modules ../packages' \
  'fixture-test:real-thread-ffi-test:../packages/.lake/build/bin/fixture-test real-thread --site ffi-test'; do
  file=${case%%:*}
  rest=${case#*:}
  name=${rest%%:*}
  said="wiring-ledger: a listing of the wiring set failed: ${rest#*:}"
  touch "$work/fail-$file"
  for run in expected "list $name"; do
    # shellcheck disable=SC2086 # `list <name>` is two words
    ledger $run
    if [ "$status" -ne 2 ] || ! grep -qxF "$said" "$work/err"; then
      fail "$run, with $file failing, exited $status, not 2 naming it:"
      sed 's/^/  /' "$work/out" "$work/err" >&2
    fi
  done
  rm "$work/fail-$file"
done

[ -z "$failed" ] || exit 1
echo "wiring-ledger-probe: expected and list printed every key of the stand-in listings, and each failed with status 2, naming it, when a listing failed"
