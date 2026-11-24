#!/bin/sh
# Runs each fixture of the real-thread set whose subject is the script runner
# itself both ways, and compares them (docs/dev-practices/headless-mode.md,
# "How the gate runs a fixture"; row A3 of
# docs/dev-practices/real-thread-checks.md): the CLI over a real loop thread,
# and the fixture harness's stepped run.
#
#   tools/fixture-compare.sh <editor> <fixture-test> <sysroot> <olean dirs> <repository>
#
# Run it in `lean/`, as the gate runs the CLI. The list is the harness's
# (`<fixture-test> … compared`): the runner entries of
# `Editor.Test.Fixture.RealThread`, one a line, `<script>\t<config>\t<expected>`,
# each a path from the repository's root, so no fixture is compared that the
# module does not name. For each, it runs `<editor> headless <sysroot>
# <olean dirs> <config> <script>`, which must exit 0, writes what it printed
# to a temporary file it removes when it ends, and hands that file to the
# harness (`<fixture-test> … compare <script> <file>`), which runs the
# fixture stepped and requires the CLI's output to be the stepped output,
# saying the lines each side alone has when it is not, and to be the
# expected file. The harness prints
# `fixture-compare: <script>: the CLI over a real loop thread and the stepped run printed the same, and it is expected`;
# at the end this prints `fixture-compare: compared <n> fixtures both ways`.
#
# It exits 0 when every fixture held, 1 at the first that did not, and 2 for
# a command line it does not take or a list that names no fixture.
set -eu

usage() {
  echo "usage: tools/fixture-compare.sh <editor> <fixture-test> <sysroot> <olean dirs> <repository>" >&2
  exit 2
}

[ "$#" -eq 5 ] || usage
editor=$1
harness=$2
sysroot=$3
oleans=$4
repo=$5

list=$("$harness" "$sysroot" "$oleans" --repo "$repo" compared) || {
  printf '%s\n' "$list"
  echo "fixture-compare: the harness could not list the fixtures to compare" >&2
  exit 1
}
if [ -z "$list" ]; then
  echo "fixture-compare: the real-thread set names no runner entry, so nothing is compared" >&2
  exit 2
fi

out=$(mktemp)
trap 'rm -f "$out"' EXIT

tab=$(printf '\t')
count=0
# The list is read on a descriptor of its own, so that neither run can take
# it for its input.
while IFS=$tab read -r script config expected <&3; do
  [ -n "$expected" ] || usage
  status=0
  "$editor" headless "$sysroot" "$oleans" "$repo/$config" "$repo/$script" >"$out" || status=$?
  if [ "$status" -ne 0 ]; then
    cat "$out"
    echo "fixture-compare: the CLI exited $status on $script" >&2
    exit 1
  fi
  "$harness" "$sysroot" "$oleans" --repo "$repo" compare "$script" "$out"
  count=$((count + 1))
done 3<<LIST
$list
LIST

echo "fixture-compare: compared $count fixtures both ways"
