import Editor
import Editor.RealHost
import Editor.Test.Linked.Services
import LanguagesTest.Check
import LanguagesTest.Linked.Languages.Grammars.Real
import LanguagesTest.Linked.Languages.Grammars.Real.SourceSet

/-!
# The linked test of the package `languages`

The package-set step `run` (`tools/package-set.sh`, in `mise run ffi-test`)
builds this root's executable with the Rust library linked, as the editor
is linked (the core's `editorLinked` facet), and runs it in the package's
directory with the Lean toolchain's directory and the core's `.olean`
directory. It prints `languages linked test: N checks passed`, and exits 0
when all hold, 1 after naming on stderr the ones that do not, and 2 for a
command line it does not take. The exit is explicit, after the library's
services are shut down and its queues quit: a task may still be blocked in
the library.

The real services are started here (`Editor.Test.Linked.Services.start`),
with the process's one completion pump. Each test module mirrors the
module it tests:

- `realChecks` (`LanguagesTest/Linked/Languages/Grammars/Real.lean`): the
  default set's build staged every grammar of the package it compiled from
  source, with the package's queries; every grammar registers and its
  queries compile; and the YAML fixture, a `.rs` file, a Markdown
  paragraph's inline markup, a `.py` file and a Markdown fence of Python
  are drawn highlighted by the package's grammars over the real services
  and display.
- `sourceSetChecks` (`LanguagesTest/Linked/Languages/Grammars/Real/SourceSet.lean`):
  a set whose package's grammar source does not compile fails its build,
  naming the package and the grammar, built with the toolchain's `lake`.

Its checks are a check set (`LanguagesTest.Linked.checks`,
`Editor.CheckGroup`, `docs/dev-practices/real-thread-checks.md`, "How the
set runs"): each wiring module's list in a group of its module, which the
build's `linter.wiringSet` holds true and complete. With `--wiring` after
the three arguments it runs the wiring set's groups alone, the stress
loop's `linked-wiring` suite (`tools/package-set.sh run --wiring`), and
`wiring-modules` prints their modules, building nothing.

It imports the config base, `Editor`, for the link alone, as every root
that links the elaborator does.
-/

/-- This module is of the wiring set (`Editor/RealHost.lean`). -/
def wiringSet.LanguagesTest.Linked : Editor.WiringSet :=
  .edge "its main starts the library's services and pump and hands them to the wiring modules"

/-- Every check of the linked test, in the order they run, over what `main`
hands them: its check set, each wiring module's in a group of its own. -/
def LanguagesTest.Linked.checks :
    List (Editor.CheckGroup LanguagesTest.Linked.Context LanguagesTest.Check) :=
  [.wired "LanguagesTest.Linked.Languages.Grammars.Real"
      wiringSet.LanguagesTest.Linked.Languages.Grammars.Real LanguagesTest.Linked.realChecks,
    .wired "LanguagesTest.Linked.Languages.Grammars.Real.SourceSet"
      wiringSet.LanguagesTest.Linked.Languages.Grammars.Real.SourceSet
      LanguagesTest.Linked.sourceSetChecks]

/-- Runs the checks `mode` selects from the check set
(`Editor.CheckGroup.select`) over the real services, started here, and the
toolchain's directory, and says which failed, or how many passed. -/
private def LanguagesTest.Linked.runSelected (mode : Editor.CheckGroup.Mode)
    (sysroot : System.FilePath) : IO UInt32 := do
  let services ← Editor.Test.Linked.Services.start
  let checks := Editor.CheckGroup.select mode LanguagesTest.Linked.checks { services, sysroot }
  let failed ← LanguagesTest.failures checks
  for name in failed do
    IO.eprintln s!"FAILED: {name}"
  if failed.isEmpty then
    IO.println s!"languages linked test: {checks.length} {mode.what} passed"
  (← IO.getStdout).flush
  Editor.Test.Linked.shutdown
  IO.Process.exit (if failed.isEmpty then 0 else 1)

/-- Says the command lines it takes, and exits 2. -/
private def LanguagesTest.Linked.usage : IO UInt32 := do
  IO.eprintln
      "usage: LanguagesTest-Linked <sysroot> <core olean dir> <test grammars dir> [--wiring], or LanguagesTest-Linked wiring-modules"
  return 2

/-- Runs the checks (the module docs). -/
def main (arguments : List String) : IO UInt32 := do
  match arguments with
  | ["wiring-modules"] =>
    for module in Editor.CheckGroup.modules LanguagesTest.Linked.checks do
      IO.println module
    return 0
  | sysroot :: _ :: _ :: rest =>
    match Editor.CheckGroup.Mode.ofArguments? rest with
    | some mode =>
      LanguagesTest.Linked.runSelected mode sysroot
    | none =>
      LanguagesTest.Linked.usage
  | _ =>
    LanguagesTest.Linked.usage
