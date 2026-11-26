#!/bin/sh
# Runs one step of the gate over every package of a package set
# (docs/design/packages.md, "The package set and its build";
# docs/dev-practices/the-gate.md, "The package steps"): the core's tests,
# lint, format check and headless fixtures each have a step here that does
# the same for a package outside the core. It decides nothing itself: it
# runs each package's commands and passes their exit status through.
#
#   tools/package-set.sh test <set dir>
#   tools/package-set.sh build <set dir>
#   tools/package-set.sh fmt <set dir>
#   tools/package-set.sh format <set dir>
#   tools/package-set.sh [--wiring | --no-linked] run <set dir> <sysroot> <core olean dir>
#
# Run it in `lean/`. The packages are the ones Lake names for the set
# (`lake -d <set dir> query :editorPackages`, a facet the core defines in
# `lean/lakefile.lean`), each after the packages it requires, with the
# module and the executable of its linked test, `<Name>Test.Linked`, when
# it has one. For each package, in that order:
#
# - `test`: its Lake test driver, `lake -d <package> test --wfail`.
# - `build`: first, once, the set's editor and its fixture harness
#   (`lake -d <set dir> build --wfail :editor :editorFixtures`); then the
#   package's default targets, `lake -d <package> build --wfail`, and its
#   linked test's executable (`+<Name>Test.Linked:editorLinked`).
# - `fmt`: `lean-fmt format --check` and `lean-fmt check` over the package,
#   from the formatter's host (`lake -d ../tools/lean-fmt exe lean-fmt`),
#   its workers sized by tools/lean-fmt-workers.sh; `format` rewrites
#   instead (`format`, `check --fix`).
# - `run`: its linked test, in the package's directory, with the
#   toolchain's directory and the core's `.olean` directory; then, when it
#   has a `tests/headless/` directory, the set's fixture harness over it
#   (`<set dir>/.lake/build/bin/fixture-test <sysroot> <core olean dir>
#   --repo <repository> run <package>/tests/headless`), which runs each
#   fixture stepped on the fakes and exits 1 for a root that holds none
#   (docs/dev-practices/headless-mode.md, "How the gate runs a fixture").
#   With `--wiring`, each linked test runs with `--wiring`, its check
#   set's wiring groups alone, and no fixture runs: the stress loop's
#   `linked-wiring` suite. With `--no-linked`, only the fixtures run, on
#   the set's own harness: the gate runs `run` over the fixture set, which
#   names every default package too, and `--no-linked run` over the
#   default set, so no linked test runs twice (`mise run ffi-test`).
#
# It stops at the first command that fails and exits with its status. It
# exits 2 for a command line it does not take, and when Lake fails the
# query.
set -eu

usage() {
  echo "usage: tools/package-set.sh test|build|fmt|format <set dir>" >&2
  echo "       tools/package-set.sh [--wiring | --no-linked] run <set dir> <sysroot> <core olean dir>" >&2
  exit 2
}

# Whether `run` runs the wiring set alone, or no linked test.
wiring=
no_linked=
while [ "$#" -gt 0 ]; do
  case $1 in
    --wiring)
      wiring=1
      shift
      ;;
    --no-linked)
      no_linked=1
      shift
      ;;
    *) break ;;
  esac
done

[ "$#" -ge 2 ] || usage
step=$1
set_dir=$2
shift 2
case $step in
  test | build | fmt | format) [ "$#" -eq 0 ] || usage ;;
  run) [ "$#" -eq 2 ] || usage ;;
  *) usage ;;
esac
if { [ -n "$wiring" ] || [ -n "$no_linked" ]; } && [ "$step" != run ]; then
  usage
fi
if [ -n "$wiring" ] && [ -n "$no_linked" ]; then
  usage
fi
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

tab=$(printf '\t')

# The formatter's host, from `lean/`, and its workers, sized to the
# machine's memory (tools/lean-fmt-workers.sh).
host=../tools/lean-fmt
case $step in fmt | format) workers=$(sh ../tools/lean-fmt-workers.sh) ;; esac

case $step in
  build)
    echo "package-set: build the editor of the set in $set_dir, and its fixture harness"
    lake -d "$set_dir" build --wfail :editor :editorFixtures
    ;;
  run)
    sysroot=$1
    # A linked test runs in its package's directory, so the paths it and
    # the fixtures are handed are absolute.
    oleans=$(cd "$2" && pwd)
    harness=$(cd "$set_dir" && pwd)/.lake/build/bin/fixture-test
    # Run in `lean/`: the repository's root, which the harness names each
    # fixture from, is the directory above.
    repo=$(cd .. && pwd -P)
    ;;
esac

# The list is read on a descriptor of its own, so that no command of a step
# can take it for its input.
while IFS=$tab read -r name dir linked linked_exe <&3; do
  [ -n "$name" ] || continue
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
    fmt)
      lake -d "$host" exe lean-fmt format --check --workers "$workers" --root "$dir"
      lake -d "$host" exe lean-fmt check --workers "$workers" --root "$dir"
      ;;
    format)
      lake -d "$host" exe lean-fmt format --workers "$workers" --root "$dir"
      lake -d "$host" exe lean-fmt check --fix --workers "$workers" --root "$dir"
      ;;
    run)
      if [ "$linked" != - ] && [ -z "$no_linked" ]; then
        if [ -n "$wiring" ]; then
          echo "package-set: linked test $linked of $name, its wiring set"
          (cd "$dir" && "$linked_exe" "$sysroot" "$oleans" --wiring)
        else
          echo "package-set: linked test $linked of $name"
          (cd "$dir" && "$linked_exe" "$sysroot" "$oleans")
        fi
      fi
      # With --wiring, no headless fixture: those run stepped on the fakes.
      if [ -z "$wiring" ] && [ -d "$dir/tests/headless" ]; then
        echo "package-set: headless fixtures of $name"
        "$harness" "$sysroot" "$oleans" --repo "$repo" run "$dir/tests/headless"
      fi
      ;;
  esac
done 3<<LIST
$packages
LIST
