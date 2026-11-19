#!/bin/sh
# Checks that the packages of a package set import only what a package may
# import of the core, on Lake's module graph (docs/design/packages.md,
# "What a package may import"): a package's library imports modules of the
# core's API alone; its tests may also import the core's test doubles; and
# the root of its linked test may also import what an executable linked as
# the editor is needs.
#
#   tools/package-imports-check.sh <set dir>
#   tools/package-imports-check.sh --lines <file>
#
# Run it in `lean/`. The set's directory holds the set's lakefile. It asks
# Lake (`lake -d <set dir> query :editorPackageImports`, a facet the core
# defines in `lean/lakefile.lean`) and reads no source text: one line for
# each direct import of a module of the core's Lake package by a module of
# a package of the set, its fields separated by tabs:
#
#   <package>	<importing module>	<kind>	<imported module>
#
# The kind is `library`, `test` (a module under `<P>Test`) or `linked` (the
# module `<P>Test.Linked`, the root of the package's linked test). Lake
# resolves the imports from the modules' headers and builds nothing, so the
# check follows a module that is renamed or moved, and an import written in
# any form. With `--lines`, the lines are read from a file instead: the
# gate hands the rule lines written by hand, one for each of its branches,
# to see each hold or bite (tests/package-imports/).
#
# The rule is about `import` lines, direct imports alone. Lean's imports
# are transitive, so a module an importable module imports is visible to a
# package's code whether or not the package may name it; what the rule
# limits is what a package depends on by name.
#
# The lists below are the rule. They are named here, never derived from the
# graph, as the core imports check's moving names are
# (tools/core-imports-check.sh), and docs/design/packages.md describes
# them: a core module that is neither internal nor a test double is part of
# the API.
#
# - A test double (`is_double`): the pure models of the ports, the
#   contracts and cases, the fakes, the test scheme, the loop's driver, the
#   reading of what a package registers (`Editor.Config.Packages`), the
#   theme picture check (`Editor.Themes.Picture`) and the core's test kit,
#   `Editor.Test` and everything under it: the support its own model tests
#   are written on (`Editor.Test.…`) and the rig of its checks over the
#   real services (`Editor.Test.Linked.…`). A test module and the linked
#   test may import one; a library module may not.
# - An internal module (`internal_reason`): the hosts and the executable's
#   modules, the loop and its dispatch, the config session, the raw
#   bindings, the real bindings of the ports and what runs them, the
#   modules that define the packages still in the core, the core's root,
#   everything under `Editor.Internal`, and every module of the core's Lake
#   package that is not named `Editor.…`: the config base, `Editor`, the
#   core's entry module and the core's own test modules. No library module
#   and no test module may import one.
# - What the linked test may import beyond the test doubles
#   (`linked_may`): the real bindings of the ports (`….Real`), the headless
#   host (`Editor.Headless`), the config base and the core's entry module.
#   It is an executable's root, linked as the editor is, and running a port
#   against the library or a host over a set is what it is for. The raw
#   bindings, the loop and the config session stay refused.
#
# It prints nothing and exits 0 when every import is allowed. Otherwise it
# prints each refused import, one a line, with its package, the importing
# module and its kind, and why, and exits 1. It exits 2 for a command line
# it does not take, when Lake fails the query, for a line that is not four
# fields with a kind it knows, and when there is no line to check, so that
# it cannot pass by checking nothing: a set with no package gives none.
set -eu

usage() {
  echo "usage: tools/package-imports-check.sh <set dir>" >&2
  echo "       tools/package-imports-check.sh --lines <file>" >&2
  exit 2
}

case $# in
  1)
    case $1 in
      '' | -*) usage ;;
    esac
    if [ ! -d "$1" ]; then
      echo "package-imports-check: no directory $1" >&2
      exit 2
    fi
    lines=$(lake -d "$1" query :editorPackageImports) || {
      echo "package-imports-check: lake -d $1 query :editorPackageImports failed" >&2
      exit 2
    }
    from="Lake names no import of the core by a package of the set in $1"
    ;;
  2)
    [ "$1" = --lines ] || usage
    if [ ! -f "$2" ]; then
      echo "package-imports-check: no file $2" >&2
      exit 2
    fi
    lines=$(cat "$2")
    from="$2 holds no line"
    ;;
  *) usage ;;
esac

if [ -z "$lines" ]; then
  echo "package-imports-check: $from, so there is nothing to check" >&2
  exit 2
fi

# Whether the module `$1` is a test double of the core.
is_double() {
  case $1 in
    Editor.Completion.Fake | Editor.Job.Fake) return 0 ;;
    Editor.InputScheme.Test | Editor.Loop.Driver) return 0 ;;
    Editor.Config.Packages | Editor.Themes.Picture) return 0 ;;
    Editor.Test | Editor.Test.*) return 0 ;;
    Editor.*.Model | Editor.*.Model.*) return 0 ;;
    Editor.*Contract | Editor.*.Cases) return 0 ;;
  esac
  return 1
}

# Why the module `$1` is internal, as a phrase; nothing, with status 1,
# when it is not. A test double is asked about first, so `Editor.Loop.Driver`
# and `Editor.Config.Packages` never reach here.
internal_reason() {
  case $1 in
    Editor) echo "the config base, which is not part of the API" ;;
    EditorCore.EditorPackage) echo "the core's entry module, which no package imports" ;;
    Editor.Internal | Editor.Internal.*) echo "internal: it is under Editor.Internal" ;;
    Editor.Core) echo "internal: the core's root" ;;
    Editor.Main | Editor.Headless | Editor.Headless.CommandLine | Editor.Window | \
      Editor.Window.Real | Editor.WindowCheck | Editor.WindowCheck.Real | Editor.Executable | \
      Editor.Version | Editor.ModuleLookup)
      echo "internal: a host or a module of the executable"
      ;;
    Editor.Loop | Editor.Command.Dispatch | Editor.Event.Queue | Editor.State.Outbox)
      echo "internal: the loop or its dispatch"
      ;;
    Editor.Config.*) echo "internal: the config session" ;;
    Editor.Ffi | Editor.Ffi.*) echo "internal: a raw binding" ;;
    Editor.*.Real | Editor.Clipboard.InProcess | Editor.Display.Recorder | Editor.Job.Runner | \
      Editor.Job.Jobs | Editor.Job.Table | Editor.Job.Pool)
      echo "internal: a real binding of a port, or what runs one"
      ;;
    Editor.*.Compiled) echo "internal: it defines a package still in the core" ;;
    Editor.*) return 1 ;;
    *) echo "no module of the editor: the core's Lake package holds it outside Editor" ;;
  esac
}

# Whether the root of a linked test may import the internal module `$1`.
linked_may() {
  case $1 in
    Editor | EditorCore.EditorPackage | Editor.Headless) return 0 ;;
    Editor.Window.Real | Editor.WindowCheck.Real) return 1 ;;
    Editor.*.Real) return 0 ;;
  esac
  return 1
}

tab=$(printf '\t')
refused=0
# The lines are read on a descriptor of their own, as the package steps
# read theirs (tools/package-set.sh).
while IFS=$tab read -r package module kind imported rest <&3; do
  if [ -z "$package" ] || [ -z "$module" ] || [ -z "$imported" ] || [ -n "$rest" ]; then
    echo "package-imports-check: not a line of four fields: $package $module $kind $imported $rest" >&2
    exit 2
  fi
  case $kind in
    library | test | linked) ;;
    *)
      echo "package-imports-check: $module of $package has the kind \`$kind\`, which is not library, test or linked" >&2
      exit 2
      ;;
  esac
  reason=
  if is_double "$imported"; then
    if [ "$kind" = library ]; then
      reason="a test double, which only a package's tests may import"
    fi
  elif why=$(internal_reason "$imported"); then
    if [ "$kind" != linked ] || ! linked_may "$imported"; then
      reason=$why
    fi
  fi
  if [ -n "$reason" ]; then
    echo "package-imports-check: $package: $module ($kind) imports $imported: $reason"
    refused=1
  fi
done 3<<LINES
$lines
LINES

exit "$refused"
