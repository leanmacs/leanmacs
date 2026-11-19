#!/bin/sh
# Checks that config in the old form is refused, and that
# tools/config-migrate.sh converts it so that it loads
# (docs/dev-practices/the-gate.md, "The config directory").
#
#   tools/config-migrate-check.sh <editor> <sysroot> <olean dir>
#
# Run it anywhere; `mise run ffi-test` runs it in `lean/` with the default
# set's editor. `<editor>` is an editor executable, `<sysroot>` the Lean
# toolchain's directory and `<olean dir>` the core's `.olean` directory, as
# the headless mode takes them.
#
# The fixture is tests/config-migrate: `chunks/`, a config directory kept
# in the old form on purpose (two files with no header, and no
# `init.lean`), a script, and what the editor's headless mode must print
# for it.
#
# 1. On `chunks/` itself the editor must print exactly `refused-expected`:
#    the reload is rejected, with one diagnostic that names the two files
#    and `mise run config-migrate`. The headless mode writes nothing, so the
#    fixture is not written to.
# 2. A copy of `chunks/` in a temporary directory, converted by
#    tools/config-migrate.sh, must hold `init.lean` and `Config/Leader.lean`
#    and no other file, and on it the editor must print exactly
#    `migrated-expected`: the config loads and its command runs.
# 3. The script refuses, with status 1 and the directory left as it was, a
#    directory that already holds an `init.lean`, and one where two files
#    give one module name; and it converts nothing, with status 0, in a
#    directory with no `.lean` file.
#
# It exits 0 and prints one line when all of that holds, and otherwise says
# what does not and exits 1. Everything it writes is in a temporary
# directory of its own, which it removes.
set -eu

if [ "$#" -ne 3 ]; then
  echo "usage: tools/config-migrate-check.sh <editor> <sysroot> <olean dir>" >&2
  exit 2
fi

editor=$1
sysroot=$2
oleans=$3
root=$(cd "$(dirname "$0")/.." && pwd)
fixture=$root/tests/config-migrate
migrate=$root/tools/config-migrate.sh

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail() {
  echo "config-migrate-check: $1" >&2
  exit 1
}

# 1. The old form is refused.
out=$("$editor" headless "$sysroot" "$oleans" "$fixture/chunks" "$fixture/script")
printf '%s\n' "$out" | diff "$fixture/refused-expected" - ||
  fail "the editor did not refuse the old form as refused-expected says"

# 2. A converted copy loads.
cp -R "$fixture/chunks" "$work/config"
sh "$migrate" "$work/config" >"$work/moves"
held=$(cd "$work/config" && find . -type f | LC_ALL=C sort | tr '\n' ' ')
[ "$held" = "./Config/Leader.lean ./init.lean " ] ||
  fail "the converted directory holds $held, not init.lean and Config/Leader.lean"
out=$("$editor" headless "$sysroot" "$oleans" "$work/config" "$fixture/script")
printf '%s\n' "$out" | diff "$fixture/migrated-expected" - ||
  fail "the converted config did not load as migrated-expected says"

# 3. What the script refuses is left as it was.
refused() {
  before=$(cd "$1" && find . -type f -exec cksum {} + | LC_ALL=C sort)
  status=0
  sh "$migrate" "$1" >/dev/null 2>"$work/refusal" || status=$?
  [ "$status" -eq 1 ] || fail "$2: the script exited $status, not 1"
  after=$(cd "$1" && find . -type f -exec cksum {} + | LC_ALL=C sort)
  [ "$before" = "$after" ] || fail "$2: the script changed the directory it refused"
}

mkdir "$work/rooted"
printf 'def a : Nat := 1\n' >"$work/rooted/10-a.lean"
printf 'def setup : SetupM Unit := pure ()\n' >"$work/rooted/init.lean"
refused "$work/rooted" "a directory that holds an init.lean"

mkdir "$work/twice"
printf 'def a : Nat := 1\n' >"$work/twice/10-keys.lean"
printf 'def b : Nat := 2\n' >"$work/twice/20-keys.lean"
printf 'def setup : SetupM Unit := pure ()\n' >"$work/twice/90-setup.lean"
refused "$work/twice" "two files that give one module name"

mkdir "$work/empty"
printf 'notes\n' >"$work/empty/notes.txt"
sh "$migrate" "$work/empty" >/dev/null ||
  fail "a directory with no .lean file: the script did not exit 0"
[ "$(cd "$work/empty" && find . -type f)" = "./notes.txt" ] ||
  fail "a directory with no .lean file: the script changed it"

echo "config-migrate: the old form was refused, a converted copy loaded, and what the script refuses was left as it was"
