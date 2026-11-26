#!/bin/sh
# Runs one step of the gate over every package of a package set
# (docs/design/packages.md, "The package set and its build";
# docs/dev-practices/the-gate.md, "The package steps"): the core's tests,
# lint, format check and headless fixtures each have a step here that does
# the same for a package outside the core.
#
# A package's tests, by convention: its Lake test driver holds the tests
# that need no Rust library; the module `<Name>Test.Linked`, when it has
# one, `<Name>` being the package's name in upper camel case, is the root
# of one executable linked as the editor is, with the Rust library; and its
# headless fixtures are the directories under `tests/headless/`.
#
#   tools/package-set.sh test <set dir>
#   tools/package-set.sh build <set dir>
#   tools/package-set.sh fmt <set dir>
#   tools/package-set.sh format <set dir>
#   tools/package-set.sh [--wiring | --no-linked] run <set dir> <sysroot> <core olean dir>
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
# - `build`: once, the set's editor and its fixture harness, `lake -d
#   <set dir> build --wfail :editor :editorFixtures`; then each package's default targets, `lake -d <package> build
#   --wfail`, which is its lint gate when its lakefile turns the linters on;
#   and, for a package with a linked test, its executable
#   (`lake -d <package> build --wfail +<Name>Test.Linked:editorLinked`, a
#   facet the core defines).
# - `fmt`: `lean-fmt format --check` and `lean-fmt check` over each package
#   (`--root <package>`, `--workers` sized by tools/lean-fmt-workers.sh),
#   run from the formatter's host
#   (`lake -d ../tools/lean-fmt exe lean-fmt`); it changes nothing. The
#   formatter requires a `lean-toolchain` in the root it is given, so each
#   package holds a link to the pin. `format` rewrites instead: `lean-fmt
#   format` and `lean-fmt check --fix`.
# - `run`: for each package, its linked test, when it has one, run in the
#   package's directory with the toolchain's directory and the core's
#   `.olean` directory as its arguments; then its headless fixtures, the
#   directories `<package>/tests/headless/<name>/` that hold `config/`,
#   `script` and `expected`, run by the set's fixture harness, once for the
#   package (`<set dir>/.lake/build/bin/fixture-test <sysroot> <core olean
#   dir> --repo <repository> run <package>/tests/headless`): each stepped
#   on the fakes, its output exactly `expected`, but those the real-thread
#   set leaves to the CLI (docs/dev-practices/headless-mode.md, "How the
#   gate runs a fixture"). The harness's count line must cover every
#   fixture found here, or the step fails. `run` builds nothing: `build`
#   comes first. It prints a line for each thing it runs, `package-set:
#   linked test <module> of <package>` and `package-set: headless fixture
#   <name> of <package>`, and a last line with the counts, `package-set: ran
#   <n> linked test(s) and <m> headless fixture(s) over <k> package(s)`, for
#   people reading the log.
#   With `--wiring`, `run` runs each linked test with `--wiring` after its
#   two directories, which runs the groups of its check set's modules of
#   the wiring set alone (`Editor.CheckGroup.wiring`), and no headless
#   fixture: the stress loop's `linked-wiring` suite. A linked test whose
#   check set has no module of the wiring set (its `wiring-modules` answer
#   is empty) is skipped, with the line `package-set: linked test <module>
#   of <package> holds no module of the wiring set`; one that answers with
#   usage (exit 2) fails the step.
#   With `--no-linked`, `run` runs no linked test, only the headless
#   fixtures, on the set's own harness. The gate runs `run` over the
#   fixture set, which requires the default set, so Lake names every
#   default package there too and each linked test runs once; and then
#   `--no-linked run` over the default set, so its fixtures also run on the
#   shipped set's harness and no linked test runs twice (`mise run
#   ffi-test`).
#
# It exits 0 when the step passed for every package, and with the failing
# command's status at the first that did not. It exits 2 for a command line
# it does not take, when Lake fails the query, and when Lake names no
# package for the set, so that a step cannot pass by running over nothing.
# For the same reason `run` exits 2 for a directory under a package's
# `tests/headless/` that is not a whole fixture (no `config/`, no `script`
# or no `expected`), which it would otherwise skip in silence, and when the
# set's packages hold nothing this `run` could run: no linked test and no
# headless fixture at all, or, with `--no-linked`, no headless fixture.
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
if [ -z "$packages" ]; then
  echo "package-set: Lake names no package of the set in $set_dir, so there is nothing to $step" >&2
  exit 2
fi

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

# What `run` ran, for its last line.
count=0
linked_count=0
fixture_count=0

# The modules of the wiring set the linked test $1 holds, a line each, as
# it answers `wiring-modules`: the step fails on any other answer.
modules_of() {
  "$1" wiring-modules || {
    echo "package-set: $1 did not answer wiring-modules" >&2
    exit 2
  }
}

# The list is read on a descriptor of its own, so that no command of a step
# can take it for its input.
while IFS=$tab read -r name dir linked linked_exe <&3; do
  echo "package-set: $step $name ($dir)"
  count=$((count + 1))
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
        modules=
        if [ -n "$wiring" ]; then
          modules=$(modules_of "$linked_exe")
        fi
        if [ -n "$wiring" ] && [ -z "$modules" ]; then
          echo "package-set: linked test $linked of $name holds no module of the wiring set"
        else
          if [ -n "$wiring" ]; then
            echo "package-set: linked test $linked of $name, its wiring set"
            (cd "$dir" && "$linked_exe" "$sysroot" "$oleans" --wiring)
          else
            echo "package-set: linked test $linked of $name"
            (cd "$dir" && "$linked_exe" "$sysroot" "$oleans")
          fi
          linked_count=$((linked_count + 1))
        fi
      fi
      # With --wiring, no headless fixture: those run stepped on the fakes.
      [ -z "$wiring" ] || continue
      fixtures=0
      for fixture in "$dir"/tests/headless/*; do
        # With no entry under `tests/headless/` the pattern stays as written.
        [ -e "$fixture" ] || continue
        for part in config script expected; do
          if [ ! -e "$fixture/$part" ]; then
            echo "package-set: $fixture is no headless fixture: it has no \`$part\`" >&2
            exit 2
          fi
        done
        echo "package-set: headless fixture ${fixture##*/} of $name"
        fixtures=$((fixtures + 1))
      done
      if [ "$fixtures" -gt 0 ]; then
        # The package's fixtures, run by the set's harness: each stepped
        # with the fakes but those the real-thread set leaves to the CLI.
        # Its count line must name every fixture found above, so none of
        # them can pass unrun.
        out=$("$harness" "$sysroot" "$oleans" --repo "$repo" run "$dir/tests/headless") || {
          printf '%s\n' "$out"
          exit 1
        }
        printf '%s\n' "$out"
        ran=$(printf '%s\n' "$out" | sed -n 's/^fixture-test: ran \([0-9]*\) fixtures stepped under .*, \([0-9]*\) left to the CLI$/\1 \2/p')
        set -- $ran
        if [ "$#" -ne 2 ] || [ "$(($1 + $2))" -ne "$fixtures" ]; then
          echo "package-set: the fixture harness ran ${1:-no} fixtures and left ${2:-no} to the CLI of the $fixtures headless fixtures of $name" >&2
          exit 1
        fi
        fixture_count=$((fixture_count + fixtures))
      fi
      ;;
  esac
done 3<<LIST
$packages
LIST

if [ "$step" = run ]; then
  if [ "$linked_count" -eq 0 ] && [ "$fixture_count" -eq 0 ]; then
    echo "package-set: the packages of the set in $set_dir hold nothing this run could run, so there is nothing to run" >&2
    exit 2
  fi
  plural() {
    if [ "$1" -eq 1 ]; then printf '%s %s' "$1" "$2"; else printf '%s %ss' "$1" "$2"; fi
  }
  echo "package-set: ran $(plural "$linked_count" "linked test") and $(plural "$fixture_count" "headless fixture") over $(plural "$count" package)"
fi
