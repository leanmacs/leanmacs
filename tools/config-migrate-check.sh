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
# 3. More shapes of the old form, each written in the temporary directory,
#    converted, and loaded by the editor, which must install it and run a
#    command of it:
#    - three files, the second with a name of two parts and the last using
#      a declaration of the first: `Config/Greet.lean`,
#      `Config/EvilKeys.lean` and `init.lean`, each file seeing every file
#      before it through the one import it is given;
#    - one file: `init.lean` alone.
#    - a `setup` defined in the second of three files, and in the first of
#      two, as the old form allowed: the file that defines it and the files
#      after it become `init.lean`, in order, so the root itself defines
#      the `setup` the editor runs, and a command it registers runs;
#    - a `private` declaration that a later file uses: the two files become
#      `init.lean`, since a private name is visible in its own module alone;
#    - a `setup` that no line is seen to declare (a doc comment before its
#      `def` on the line): every file becomes `init.lean`, each but the
#      last in a section of its own, and the script says so.
# 4. The script refuses, with status 1 and the directory left as it was: a
#    directory that already holds an `init.lean`; one where two files give
#    one module name; a file whose name gives no module name, having no
#    letter after its digits; a `Config/<Name>.lean` that is already
#    there; a file that would go in `init.lean` before another and leaves a
#    namespace open, or closes one it did not open, which it must name. It
#    converts nothing, with status 0, in a directory with no `.lean` file.
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

# 3. More shapes, each converted and loaded.
# Writes the file `$1` from stdin, making its directory.
write() {
  mkdir -p "$(dirname "$1")"
  cat >"$1"
}
# Converts the directory `$1`, which must then hold exactly the files `$2`
# (as `find` prints them, in byte order, each followed by a space), and
# has the editor load it and run the command `$3`: it must print the
# report line `$4` and then `run $3: ok`. `$5` says which shape it is.
converted() {
  sh "$migrate" "$1" >"$work/moves" || fail "$5: the script refused it"
  held=$(cd "$1" && find . -type f | LC_ALL=C sort | tr '\n' ' ')
  [ "$held" = "$2" ] || fail "$5: the converted directory holds $held, not $2"
  printf 'reload\nsettle\nrun %s\n' "$3" >"$work/run-script"
  out=$("$editor" headless "$sysroot" "$oleans" "$1" "$work/run-script")
  printf '%s\n%s\n' "$4" "run $3: ok" >"$work/wanted"
  printf '%s\n' "$out" | diff "$work/wanted" - ||
    fail "$5: the converted config did not load and run $3"
}

write "$work/three/10-greet.lean" <<'LEAN'
def greet : EditorM Unit :=
  message "three"
LEAN
write "$work/three/20-evil-keys.lean" <<'LEAN'
def evilKeys : SetupM Unit :=
  command "greet" greet
LEAN
write "$work/three/90-setup.lean" <<'LEAN'
def again : EditorM Unit :=
  greet

def setup : SetupM Unit := do
  evilKeys
  command "again" again
LEAN
converted "$work/three" "./Config/EvilKeys.lean ./Config/Greet.lean ./init.lean " again \
  "reload 1: installed, 3 files, 2 commands" "three files, the last using a declaration of the first"

write "$work/one/10-keys.lean" <<'LEAN'
def setup : SetupM Unit :=
  command "only" (message "one")
LEAN
converted "$work/one" "./init.lean " only "reload 1: installed, 1 files, 1 commands" "one file"

# A `setup` defined in a file before the last, as the old form allowed: the
# file that defines it and the files after it become `init.lean`, so the
# root itself defines the `setup` the editor runs.
write "$work/earlier/10-greet.lean" <<'LEAN'
def greet : EditorM Unit :=
  message "earlier"
LEAN
write "$work/earlier/20-setup.lean" <<'LEAN'
namespace Inner

def value : Nat := 1

end Inner

open Inner

def setup : SetupM Unit :=
  command "greet" greet
LEAN
write "$work/earlier/30-checks.lean" <<'LEAN'
-- A file after the one that defines `setup`: it sees that file's
-- declarations, and not what that file opened. Were `Inner` still open
-- here, `value` below would be ambiguous.
def value : Nat := 2

def useValue : Nat := value

def alsoSetup : SetupM Unit :=
  setup
LEAN
converted "$work/earlier" "./Config/Greet.lean ./init.lean " greet \
  "reload 1: installed, 2 files, 1 commands" "a setup defined in the second of three files"

write "$work/first/10-setup.lean" <<'LEAN'
def setup : SetupM Unit :=
  command "first" (message "first")
LEAN
write "$work/first/20-more.lean" <<'LEAN'
def more : SetupM Unit :=
  setup
LEAN
converted "$work/first" "./init.lean " first "reload 1: installed, 1 files, 1 commands" \
  "a setup defined in the first of two files"

# A private declaration is visible in its own module alone, and the old
# form's files were one module: the file that declares one stays with the
# files after it.
write "$work/private/10-helpers.lean" <<'LEAN'
private def secret : String :=
  "kept"
LEAN
write "$work/private/90-setup.lean" <<'LEAN'
def setup : SetupM Unit :=
  command "tell" (message secret)
LEAN
converted "$work/private" "./init.lean " tell "reload 1: installed, 1 files, 1 commands" \
  "a private declaration a later file uses"

# A `setup` declared so that no line starts its declaration (here a doc
# comment before `def` on its line): the script cannot tell where `setup`
# is, and every file goes in `init.lean`, each but the last in a section of
# its own, which loads.
write "$work/unseen/10-greet.lean" <<'LEAN'
namespace Greeting

def text : String :=
  "unseen"

end Greeting

open Greeting

def greet : EditorM Unit :=
  message text
LEAN
write "$work/unseen/20-keys.lean" <<'LEAN'
def keys : SetupM Unit :=
  command "greet" greet
LEAN
write "$work/unseen/90-setup.lean" <<'LEAN'
/-- The config's setup. -/ def setup : SetupM Unit := do
  keys
  command "again" greet
LEAN
converted "$work/unseen" "./init.lean " again "reload 1: installed, 1 files, 2 commands" \
  "a setup no line is seen to declare"
grep -q 'no line of any file was seen to define setup' "$work/moves" ||
  fail "a setup no line is seen to declare: the script did not say it kept every file together"

# 4. What the script refuses is left as it was.
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

mkdir "$work/nameless"
printf 'def a : Nat := 1\n' >"$work/nameless/10.lean"
printf 'def setup : SetupM Unit := pure ()\n' >"$work/nameless/90-setup.lean"
refused "$work/nameless" "a file whose name has no letter after its digits"

mkdir -p "$work/taken/Config"
printf 'def a : Nat := 1\n' >"$work/taken/10-keys.lean"
printf 'def setup : SetupM Unit := pure ()\n' >"$work/taken/90-setup.lean"
printf 'mine\n' >"$work/taken/Config/Keys.lean"
refused "$work/taken" "a Config/<Name>.lean that is already there"

write "$work/open/10-setup.lean" <<'LEAN'
def setup : SetupM Unit :=
  pure ()

namespace LeftOpen

def inside : Nat := 1
LEAN
write "$work/open/20-more.lean" <<'LEAN'
def more : Nat := 2
LEAN
refused "$work/open" "a file that would go in init.lean before another and leaves a namespace open"
grep -q '10-setup.lean' "$work/refusal" ||
  fail "a file that leaves a namespace open: the refusal does not name the file"

write "$work/closes/10-setup.lean" <<'LEAN'
def setup : SetupM Unit :=
  pure ()

end Stray
LEAN
write "$work/closes/20-more.lean" <<'LEAN'
def more : Nat := 2
LEAN
refused "$work/closes" "a file that would go in init.lean before another and closes what it did not open"
grep -q '10-setup.lean' "$work/refusal" ||
  fail "a file that closes what it did not open: the refusal does not name the file"

mkdir "$work/empty"
printf 'notes\n' >"$work/empty/notes.txt"
sh "$migrate" "$work/empty" >/dev/null ||
  fail "a directory with no .lean file: the script did not exit 0"
[ "$(cd "$work/empty" && find . -type f)" = "./notes.txt" ] ||
  fail "a directory with no .lean file: the script changed it"

echo "config-migrate: the old form was refused, converted copies of it loaded, and what the script refuses was left as it was"
