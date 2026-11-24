#!/bin/sh
# Proves what tools/package-set.sh's `run --wiring` runs, the stress loop's
# `linked-wiring` suite, on stand-ins, so the gate holds that branch though
# it never runs a wiring mode of a real root:
#
#   sh tools/package-set-probe.sh    # run by `mise run ffi-test`
#
# It runs the script in the `lean/` of a stand-in tree made in a temporary
# directory, with a stand-in `lake` first on its PATH, which names two
# packages for the set: `wired`, whose linked test answers `wiring-modules`
# with one module, and `plain`, whose linked test answers with none. Each
# package has a headless fixture, and the set's fixture harness is a
# stand-in too. Each stand-in writes each call it gets, with its
# arguments, to a file. Then:
#
# - `--wiring run` must run `wired`'s linked test once, handed `--wiring`
#   after its two directories, and pass its `wiring-set: ran` line
#   through; skip `plain`'s, saying it holds no module of the wiring set;
#   run no headless fixture and not the harness; and say it ran one linked
#   test and no fixture over two packages;
# - `run`, the gate's, must run both linked tests with their two
#   directories alone and the harness over each package's fixtures;
# - `--wiring run` must exit 2, naming it, when a linked test answers
#   `wiring-modules` with a failing status, as one that takes no
#   `wiring-modules` answers usage; and `--wiring` with a step other than
#   `run` is a usage error.
#
# It builds nothing and needs no build, touches only its temporary
# directory, runs no real linked test, and is for macOS's sh and Linux's
# dash alike.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
work=$(cd "$work" && pwd -P)
failed=

fail() {
  printf 'package-set-probe: FAIL: %s\n' "$1" >&2
  failed=1
}

tree=$work/tree
mkdir -p "$tree/lean" "$tree/set/.lake/build/bin" "$tree/bin" "$tree/sysroot" "$tree/oleans"

# Writes the executable stand-in $1 with the shell code $2.
standin() {
  printf '#!/bin/sh\n%s\n' "$2" >"$1"
  chmod +x "$1"
}

standin "$tree/bin/lake" "[ \"\$*\" = '-d ../set query :editorPackages' ] || exit 2
printf '%s\\t%s\\t%s\\t%s\\n' wired '$tree/wired' WiredTest.Linked '$tree/wired/WiredTest-Linked' \\
  plain '$tree/plain' PlainTest.Linked '$tree/plain/PlainTest-Linked'"
standin "$tree/set/.lake/build/bin/fixture-test" "echo \"harness \$*\" >>'$work/calls'
echo 'fixture-test: ran 1 fixtures stepped under the stand-in, 0 left to the CLI'"
for package in wired plain; do
  mkdir -p "$tree/$package/tests/headless/one/config"
  : >"$tree/$package/tests/headless/one/script"
  : >"$tree/$package/tests/headless/one/expected"
done
standin "$tree/wired/WiredTest-Linked" "echo \"wired \$*\" >>'$work/calls'
case \$# in
  1) [ \"\$1\" = wiring-modules ] || exit 2; echo WiredTest.Wired ;;
  2) echo 'wired linked test: 2 checks passed'; echo 'wiring-set: ran wired WiredTest.Wired 1 checks' ;;
  3) [ \"\$3\" = --wiring ] || exit 2; echo 'wired linked test: 1 wiring-set checks passed'; echo 'wiring-set: ran wired WiredTest.Wired 1 checks' ;;
  *) exit 2 ;;
esac"
standin "$tree/plain/PlainTest-Linked" "echo \"plain \$*\" >>'$work/calls'
case \$# in
  1) [ \"\$1\" = wiring-modules ] && [ ! -e '$work/usage' ] || exit 2 ;;
  2) echo 'plain linked test: 1 checks passed' ;;
  *) exit 2 ;;
esac"

# Runs the script with the arguments given in the stand-in tree's `lean/`,
# the stand-in lake first on the PATH: its stdout into $work/out, its
# stderr into $work/err, its status into `status`, and the stand-ins' calls
# into $work/calls.
package_set() {
  : >"$work/calls"
  status=0
  (cd "$tree/lean" && PATH="$tree/bin:$PATH" sh "$root/tools/package-set.sh" "$@") \
    >"$work/out" 2>"$work/err" || status=$?
}

# Fails, saying $1 and showing the run, unless $work/$2 is exactly the
# lines after it.
exactly() {
  what=$1
  file=$2
  shift 2
  if [ "$(cat "$work/$file")" != "$(printf '%s\n' "$@")" ]; then
    fail "$what:"
    sed 's/^/  /' "$work/out" "$work/err" "$work/calls" >&2
  fi
}

package_set --wiring run ../set "$tree/sysroot" ../oleans
[ "$status" -eq 0 ] || fail "--wiring run exited $status"
exactly "--wiring run did not run the wired linked test alone, with --wiring, and no fixture" out \
  'package-set: run wired ('"$tree"'/wired)' \
  'package-set: linked test WiredTest.Linked of wired, its wiring set' \
  'wired linked test: 1 wiring-set checks passed' \
  'wiring-set: ran wired WiredTest.Wired 1 checks' \
  'package-set: run plain ('"$tree"'/plain)' \
  'package-set: linked test PlainTest.Linked of plain holds no module of the wiring set' \
  'package-set: ran 1 linked test and 0 headless fixtures over 2 packages'
exactly "--wiring run did not hand the wired linked test --wiring, or ran more" calls \
  'wired wiring-modules' \
  "wired $tree/sysroot $tree/oleans --wiring" \
  'plain wiring-modules'

package_set run ../set "$tree/sysroot" ../oleans
[ "$status" -eq 0 ] || fail "run exited $status"
exactly "run did not run both linked tests with their two directories, and the harness over each package" calls \
  "wired $tree/sysroot $tree/oleans" \
  "harness $tree/sysroot $tree/oleans --repo $tree run $tree/wired/tests/headless" \
  "plain $tree/sysroot $tree/oleans" \
  "harness $tree/sysroot $tree/oleans --repo $tree run $tree/plain/tests/headless"

touch "$work/usage"
package_set --wiring run ../set "$tree/sysroot" ../oleans
if [ "$status" -ne 2 ] || ! grep -qxF "package-set: $tree/plain/PlainTest-Linked did not answer wiring-modules" "$work/err"; then
  fail "--wiring run, a linked test answering wiring-modules with usage, exited $status, not 2 naming it"
  sed 's/^/  /' "$work/out" "$work/err" >&2
fi
rm "$work/usage"

package_set --wiring test ../set
[ "$status" -eq 2 ] || fail "--wiring test exited $status, not 2"

[ -z "$failed" ] || exit 1
echo "package-set-probe: --wiring run ran the linked test that holds a module of the wiring set alone, handed --wiring, skipped the one that holds none and ran no fixture; run ran both and the fixtures; and a linked test that did not answer wiring-modules failed the step"
