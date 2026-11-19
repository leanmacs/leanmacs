#!/bin/sh
# Runs one step of the gate over every package of a package set
# (docs/design/packages.md, "The package set and its build";
# docs/dev-practices/the-gate.md, "The package steps"): the core's tests,
# lint and headless fixtures each have a step here that does the same for a
# package outside the core.
#
# A package's tests, by convention: its Lake test driver holds the tests
# that need no Rust library; the module `<Name>Test.Linked`, when it has
# one, `<Name>` being the package's name in upper camel case, is the root
# of one executable linked as the editor is, with the Rust library; and its
# headless fixtures are the directories under `tests/headless/`.
#
#   tools/package-set.sh test <set dir>
#   tools/package-set.sh build <set dir>
#   tools/package-set.sh run <set dir> <sysroot> <core olean dir>
#
# Run it in `lean/`. The set's directory holds the set's lakefile. The
# packages a step runs over are the ones Lake names for the set
# (`lake -d <set dir> query :editorPackages`, a facet the core defines in
# `lean/lakefile.lean`): the packages the set requires, directly or through
# another, by path, that hold a Lean library, other than the core. Each is
# visited after the packages it requires. Nothing here reads a lakefile.
#
# - `test`: each package's Lake test driver, `lake -d <package> test
#   --wfail`: the tests that need no Rust library. A package with no test
#   driver fails the step, since Lake refuses to test it.
# - `build`: once, the set's editor, `lake -d <set dir> build --wfail
#   :editor`; then each package's default targets, `lake -d <package> build
#   --wfail`, which is its lint gate when its lakefile turns the linters on;
#   and, for a package with a linked test, its executable
#   (`lake -d <package> build --wfail +<Name>Test.Linked:editorLinked`, a
#   facet the core defines).
# - `run`: for each package, its linked test, when it has one, run in the
#   package's directory with the toolchain's directory and the core's
#   `.olean` directory as its arguments; then each of its headless fixtures,
#   the directories `<package>/tests/headless/<name>/` that hold `config/`,
#   `script` and `expected`, run on the set's editor
#   (`<set dir>/.lake/build/bin/editor headless <sysroot> <core olean dir>
#   <fixture>/config <fixture>/script`), whose output must be exactly
#   `expected`. `run` builds nothing: `build` comes first.
#
# It exits 0 when the step passed for every package, and with the failing
# command's status at the first that did not. It exits 2 for a command line
# it does not take, when Lake fails the query, and when Lake names no
# package for the set, so that a step cannot pass by running over nothing.
set -eu

usage() {
  echo "usage: tools/package-set.sh test|build <set dir>" >&2
  echo "       tools/package-set.sh run <set dir> <sysroot> <core olean dir>" >&2
  exit 2
}

[ "$#" -ge 2 ] || usage
step=$1
set_dir=$2
shift 2
case $step in
  test | build) [ "$#" -eq 0 ] || usage ;;
  run) [ "$#" -eq 2 ] || usage ;;
  *) usage ;;
esac
if [ ! -d "$set_dir" ]; then
  echo "package-set: no directory $set_dir" >&2
  exit 2
fi

# One line a package: its name, its directory, the module of its linked
# test and that test's executable, separated by tabs. The last two are `-`
# for a package with no linked test.
packages=$(lake -d "$set_dir" query :editorPackages) || {
  echo "package-set: lake -d $set_dir query :editorPackages failed" >&2
  exit 2
}
if [ -z "$packages" ]; then
  echo "package-set: Lake names no package of the set in $set_dir, so there is nothing to $step" >&2
  exit 2
fi

tab=$(printf '\t')

case $step in
  build)
    echo "package-set: build the editor of the set in $set_dir"
    lake -d "$set_dir" build --wfail :editor
    ;;
  run)
    sysroot=$1
    # A linked test runs in its package's directory, so the paths it and
    # the fixtures are handed are absolute.
    oleans=$(cd "$2" && pwd)
    editor=$(cd "$set_dir" && pwd)/.lake/build/bin/editor
    ;;
esac

# The list is read on a descriptor of its own, so that no command of a step
# can take it for its input.
while IFS=$tab read -r name dir linked linked_exe <&3; do
  echo "package-set: $step $name ($dir)"
  case $step in
    test)
      lake -d "$dir" test --wfail
      ;;
    build)
      lake -d "$dir" build --wfail
      if [ "$linked" != - ]; then
        lake -d "$dir" build --wfail "+$linked:editorLinked"
      fi
      ;;
    run)
      if [ "$linked" != - ]; then
        echo "package-set: linked test $linked"
        (cd "$dir" && "$linked_exe" "$sysroot" "$oleans")
      fi
      for fixture in "$dir"/tests/headless/*/; do
        fixture=${fixture%/}
        [ -f "$fixture/script" ] || continue
        echo "package-set: headless fixture $fixture"
        out=$("$editor" headless "$sysroot" "$oleans" "$fixture/config" "$fixture/script")
        printf '%s\n' "$out" | diff "$fixture/expected" -
      done
      ;;
  esac
done 3<<LIST
$packages
LIST
