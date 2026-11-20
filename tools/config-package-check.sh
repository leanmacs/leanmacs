#!/bin/sh
# Checks that an editor run from the checkout makes a config directory a
# Lake package: it generates the directory's lakefile and toolchain file
# when they are absent, and never otherwise, and Lean's language server,
# started there, checks a config file as the editor elaborates it
# (docs/dev-practices/the-gate.md, "The config directory";
# docs/design/lean-runtime.md, "Config and reload").
#
#   tools/config-package-check.sh <set dir> <sysroot> <olean dir>
#
# Run it in `lean/`; `mise run ffi-test` runs it with the default set's
# directory, `../packages`. `<set dir>` is a package set whose editor is
# built (`<set dir>/.lake/build/bin/editor`), `<sysroot>` the Lean
# toolchain's directory and `<olean dir>` the core's `.olean` directory, as
# the headless mode takes them.
#
# The fixture is tests/headless/generate, whose config directory holds
# `init.lean` alone. Every run is on a copy of it in a temporary directory:
# the fixture is never written to.
#
# 1. `editor headless --generate` on a copy must print exactly the
#    fixture's `expected` (the config loads), and leave a `lean-toolchain`
#    that is `lean/lean-toolchain` byte for byte and a `lakefile.toml` that
#    names the package `config`, requires the set by its Lake name and its
#    directory, then `editor-core` by the checkout's `lean/` (the core the
#    editor links, its `.coredir`), last, and declares the library
#    `Config`.
# 2. A second run with `--generate` must leave both files as they were:
#    a file that is there is never rewritten.
# 3. A run without `--generate` on a second copy must print the same and
#    leave neither file: without the option the headless mode writes
#    nothing into a config directory.
#
# 4. Lean's language server checks the directory as the editor elaborates
#    it. The root and the config file of tests/config-package/lsp are put
#    in the directory step 1 generated, beside its lakefile and toolchain
#    file: a root that imports `Lean`, a module of a default package
#    (`Compile`) and the config file `Config/Keys.lean`, and holds one type
#    error, on line 8 at column 19. `config-test lsp` starts
#    `<sysroot>/bin/lake serve` there and opens the root
#    (lean/ConfigTest/Lsp.lean): the server must report that one error and
#    no other, so no import failed. Lake writes `lake-manifest.json` and
#    `.lake/` in the temporary directory and fetches nothing: the lakefile
#    requires the set by path.
#
# It exits 0 and prints two lines when all of that holds, and otherwise
# says what does not and exits 1. Everything it writes is in a temporary
# directory of its own, which it removes.
set -eu

if [ "$#" -ne 3 ]; then
  echo "usage: tools/config-package-check.sh <set dir> <sysroot> <olean dir>" >&2
  exit 2
fi

set_dir=$(cd "$1" && pwd -P)
sysroot=$2
oleans=$3
editor=$set_dir/.lake/build/bin/editor
root=$(cd "$(dirname "$0")/.." && pwd)
fixture=$root/tests/headless/generate
pin=$root/lean/lean-toolchain

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail() {
  echo "config-package-check: $1" >&2
  exit 1
}

# The set's Lake name, from its lakefile: the editor writes the name the
# build handed it.
set_name=$(sed -n 's/^name = "\(.*\)"$/\1/p' "$set_dir/lakefile.toml" | head -n 1)
[ -n "$set_name" ] || fail "cannot read the set's name from $set_dir/lakefile.toml"

# 1. Generated when absent, and the config loads.
cp -R "$fixture/config" "$work/config"
out=$("$editor" headless --generate "$sysroot" "$oleans" "$work/config" "$fixture/script")
printf '%s\n' "$out" | diff "$fixture/expected" - ||
  fail "with --generate the config did not load as the fixture's expected says"
cmp -s "$work/config/lean-toolchain" "$pin" ||
  fail "the generated lean-toolchain is not lean/lean-toolchain"
[ -f "$work/config/lakefile.toml" ] || fail "no lakefile.toml was generated"
core_dir=$(cd "$root/lean" && pwd -P)
printf 'name = "config"\n\n[[require]]\nname = "%s"\npath = "%s"\n\n[[require]]\nname = "editor-core"\npath = "%s"\n\n[[lean_lib]]\nname = "Config"\nglobs = ["Config.+"]\n' \
  "$set_name" "$set_dir" "$core_dir" >"$work/wanted"
diff "$work/wanted" "$work/config/lakefile.toml" ||
  fail "the generated lakefile.toml does not require the set $set_name at $set_dir, then the core at $core_dir"
held=$(cd "$work/config" && find . -type f | LC_ALL=C sort | tr '\n' ' ')
[ "$held" = "./init.lean ./lakefile.toml ./lean-toolchain " ] ||
  fail "the config directory holds $held after the run"

# 2. Never rewritten.
before=$(cd "$work/config" && cksum lakefile.toml lean-toolchain && ls -l lakefile.toml lean-toolchain)
out=$("$editor" headless --generate "$sysroot" "$oleans" "$work/config" "$fixture/script")
printf '%s\n' "$out" | diff "$fixture/expected" - ||
  fail "a second run with --generate did not load the config"
after=$(cd "$work/config" && cksum lakefile.toml lean-toolchain && ls -l lakefile.toml lean-toolchain)
[ "$before" = "$after" ] || fail "a second run with --generate rewrote a generated file"

# 3. Nothing without the option.
cp -R "$fixture/config" "$work/plain"
out=$("$editor" headless "$sysroot" "$oleans" "$work/plain" "$fixture/script")
printf '%s\n' "$out" | diff "$fixture/expected" - ||
  fail "without --generate the config did not load"
held=$(cd "$work/plain" && find . -type f | tr '\n' ' ')
[ "$held" = "./init.lean " ] || fail "without --generate the config directory holds $held"

echo "config-package: generated lakefile.toml and lean-toolchain, the config loaded, and a second run wrote nothing"

# 4. The language server, in the directory step 1 generated.
lsp=$root/tests/config-package/lsp
cp "$lsp/init.lean" "$work/config/init.lean"
mkdir "$work/config/Config"
cp "$lsp/Config/Keys.lean" "$work/config/Config/Keys.lean"
"$root/lean/.lake/build/bin/config-test" lsp "$sysroot" "$work/config" 8 19 ||
  fail "Lean's language server did not check the config directory as the editor does"
