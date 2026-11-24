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
#   tools/package-set.sh run <set dir> <sysroot> <core olean dir>
#   tools/package-set.sh [--only <package>]... [--allow-empty-run] <step> ...
#
# Run it in `lean/`. The set's directory holds the set's lakefile. The
# packages a step runs over are the ones Lake names for the set
# (`lake -d <set dir> query :editorPackages`, a facet the core defines in
# `lean/lakefile.lean`): the packages the set requires, directly or through
# another, by path, that hold a Lean library, other than the core. Each is
# visited after the packages it requires. Nothing here reads a lakefile.
# With `--only`, given once for each, the step runs over the named packages
# of the set alone, still in the set's order: what the pre-commit hook runs
# for a change that reaches only those (tools/lean-hook.sh;
# docs/dev-practices/the-gate.md, "The pre-commit hook"). `build` still
# builds the set's editor first.
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
#   (`--root <package>`), run from the formatter's host
#   (`lake -d ../tools/lean-fmt exe lean-fmt`); it changes nothing. The
#   formatter requires a `lean-toolchain` in the root it is given, so each
#   package holds a copy of the pin. `format` rewrites instead: `lean-fmt
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
#   comes first. It prints a
#   line for each thing it runs, `package-set: linked test <module> of
#   <package>` and `package-set: headless fixture <name> of <package>`, and
#   a last line with the counts, `package-set: ran <n> linked test(s) and
#   <m> headless fixture(s) over <k> package(s)`, so a caller can require
#   that what it is there to run did run.
#
# It exits 0 when the step passed for every package, and with the failing
# command's status at the first that did not. It exits 2 for a command line
# it does not take, when Lake fails the query, and when Lake names no
# package for the set, so that a step cannot pass by running over nothing.
# For the same reason `run` exits 2 for a directory under a package's
# `tests/headless/` that is not a whole fixture (no `config/`, no `script`
# or no `expected`), which it would otherwise skip in silence, and when the
# set's packages hold no linked test and no headless fixture at all, and,
# with `--only`, for a name that is no package of the set. With `--only`,
# `--allow-empty-run` lets `run` pass over packages that hold no linked
# test and no fixture, as an interface package such as `greeting-api` does:
# the hook passes it, the gate, which runs over every package, never does.
set -eu

usage() {
  echo "usage: tools/package-set.sh test|build|fmt|format <set dir>" >&2
  echo "       tools/package-set.sh run <set dir> <sysroot> <core olean dir>" >&2
  echo "       each after any of: --only <package> (repeatable), --allow-empty-run (with --only)" >&2
  exit 2
}

# The names `--only` gives, one a line, and whether `run` may run nothing.
only=
allow_empty_run=
while [ "$#" -gt 0 ]; do
  case $1 in
    --only)
      [ "$#" -ge 2 ] && [ -n "$2" ] || usage
      only="$only$2
"
      shift 2
      ;;
    --allow-empty-run)
      allow_empty_run=1
      shift
      ;;
    *) break ;;
  esac
done
if [ -n "$allow_empty_run" ] && [ -z "$only" ]; then
  usage
fi

[ "$#" -ge 2 ] || usage
step=$1
set_dir=$2
shift 2
case $step in
  test | build | fmt | format) [ "$#" -eq 0 ] || usage ;;
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

if [ -n "$only" ]; then
  # Each name must be a package of the set; then the set's lines are kept
  # for the named packages alone, in the set's order.
  for name in $only; do
    if ! printf '%s\n' "$packages" | cut -f1 | grep -qxF -- "$name"; then
      echo "package-set: $name is no package of the set in $set_dir" >&2
      exit 2
    fi
  done
  packages=$(printf '%s\n' "$packages" | ONLY=$only awk -F "$tab" '
    BEGIN { k = split(ENVIRON["ONLY"], names, "\n"); for (i = 1; i <= k; i++) if (names[i] != "") wanted[names[i]] = 1 }
    $1 in wanted
  ')
fi

# The formatter's host, from `lean/`.
host=../tools/lean-fmt

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
      lake -d "$host" exe lean-fmt format --check --root "$dir"
      lake -d "$host" exe lean-fmt check --root "$dir"
      ;;
    format)
      lake -d "$host" exe lean-fmt format --root "$dir"
      lake -d "$host" exe lean-fmt check --fix --root "$dir"
      ;;
    run)
      if [ "$linked" != - ]; then
        echo "package-set: linked test $linked of $name"
        (cd "$dir" && "$linked_exe" "$sysroot" "$oleans")
        linked_count=$((linked_count + 1))
      fi
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
  if [ "$linked_count" -eq 0 ] && [ "$fixture_count" -eq 0 ] && [ -z "$allow_empty_run" ]; then
    echo "package-set: the packages of the set in $set_dir hold no linked test and no headless fixture, so there is nothing to run" >&2
    exit 2
  fi
  plural() {
    if [ "$1" -eq 1 ]; then printf '%s %s' "$1" "$2"; else printf '%s %ss' "$1" "$2"; fi
  }
  echo "package-set: ran $(plural "$linked_count" "linked test") and $(plural "$fixture_count" "headless fixture") over $(plural "$count" package)"
fi
