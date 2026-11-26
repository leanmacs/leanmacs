import Editor
import Editor.RealHost
import Editor.Test.Linked.Services
import IniGrammarTest.Check
import IniGrammarTest.Linked.IniGrammar.Real

/-!
# The linked test of the package `ini-grammar`

The root of an executable linked as the editor is linked, with the glue and
the Rust library (the core's `editorLinked` facet,
`lake build +IniGrammarTest.Linked:editorLinked`): the wiring checks of the
grammar the package ships (`IniGrammarTest/Linked/IniGrammar/Real.lean`).
The gate builds it in `mise run lean` and runs it in `mise run ffi-test`,
in the package's directory, with three arguments: the grammar set's editor
(`tests/grammar-set/.lake/build/bin/editor`), beside which the set's build
wrote the record of where it staged the package's `grammars/`; the fixture
grammar library Cargo built (`crates/editor-syntax-fixture-ini`'s binary
prints its path); and the directory of the syntax fixtures
(`tests/syntax`). No package step runs it (`tools/package-set.sh`), since
those hand a linked test the toolchain's and the core's directories.

It prints `ini-grammar linked test: N checks passed` and exits 0 when all
hold, 1 after naming on stderr the ones that do not, and 2 for a command
line it does not take. The exit is explicit, after the library's services
are shut down and its queues quit: a task may still be blocked in the
library.

The real services are started here (`Editor.Test.Linked.Services.start`),
with the process's one completion pump. Its checks are a check set
(`IniGrammarTest.Linked.checks`, `Editor.CheckGroup`,
`docs/dev-practices/real-thread-checks.md`, "How the set runs"): with
`--wiring` after the three arguments it runs the wiring set's groups alone,
and `wiring-modules` prints their modules, one a line, building nothing.

It imports the config base, `Editor`, for the link alone, as every root
that links the elaborator does.
-/

/-- This module is of the wiring set (`Editor/RealHost.lean`). -/
def wiringSet.IniGrammarTest.Linked : Editor.WiringSet :=
  .edge "its main starts the library's services and pump and hands them to the wiring module"

/-- Every check of the linked test, in the order they run, over what `main`
hands them: its check set, the wiring module's in a group of its own. -/
def IniGrammarTest.Linked.checks :
    List (Editor.CheckGroup IniGrammarTest.Linked.Context IniGrammarTest.Check) :=
  [.wired "IniGrammarTest.Linked.IniGrammar.Real" wiringSet.IniGrammarTest.Linked.IniGrammar.Real
      IniGrammarTest.Linked.realChecks]

/-- Runs the checks `mode` selects from the check set
(`Editor.CheckGroup.select`) over the real services, started here, and the
three paths, and says which failed, or how many passed. -/
private def IniGrammarTest.Linked.runSelected (mode : Editor.CheckGroup.Mode)
    (editor library syntaxFixtures : System.FilePath) : IO UInt32 := do
  let services ← Editor.Test.Linked.Services.start
  let checks :=
    Editor.CheckGroup.select mode IniGrammarTest.Linked.checks
      { services, editor, library, syntaxFixtures }
  let failed ← IniGrammarTest.failures checks
  for name in failed do
    IO.eprintln s!"FAILED: {name}"
  if failed.isEmpty then
    IO.println s!"ini-grammar linked test: {checks.length} {mode.what} passed"
  (← IO.getStdout).flush
  Editor.Test.Linked.shutdown
  IO.Process.exit (if failed.isEmpty then 0 else 1)

/-- Says the command lines it takes, and exits 2. -/
private def IniGrammarTest.Linked.usage : IO UInt32 := do
  IO.eprintln
      "usage: IniGrammarTest-Linked <grammar set editor> <grammar library> <syntax fixtures> [--wiring], or IniGrammarTest-Linked wiring-modules"
  return 2

/-- Runs the checks (the module docs). -/
def main (arguments : List String) : IO UInt32 := do
  match arguments with
  | ["wiring-modules"] =>
    for module in Editor.CheckGroup.modules IniGrammarTest.Linked.checks do
      IO.println module
    return 0
  | editor :: library :: syntaxFixtures :: rest =>
    match Editor.CheckGroup.Mode.ofArguments? rest with
    | some mode =>
      IniGrammarTest.Linked.runSelected mode editor library syntaxFixtures
    | none =>
      IniGrammarTest.Linked.usage
  | _ =>
    IniGrammarTest.Linked.usage
