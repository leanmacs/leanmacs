import Editor.RealHost
import ModelTest.Lint.Wait

/-!
# Model tests: `Lint/Wait.lean`, a module of the wiring set beside a mirror

The wait linter's fixture of a module beside the mirror of its target,
`<Root>.<target>.Real`, that declares `.wiring`: it counts as the mirror of
`Lint.Wait.Wired`, a subject of `besideCount`'s mark
(`ModelTest/Lint/Wait.lean`), so it may reference that wait.
`ModelTest/Lint/Wait/Unwired/Real.lean` is the same form, declaring
nothing, and is refused.
-/

/-- This module's declaration: a fixture's. -/
def wiringSet.ModelTest.Lint.Wait.Wired.Real : Editor.WiringSet :=
  .wiring "a stand-in adapter" "a fixture of the wait linter's mirror rule"

#guard_msgs in
/-- A reference to its target's inferred wait: refused nothing. -/
def ModelTest.LintBesideFixture.wiredRead : BaseIO Bool :=
  return (← ModelTest.LintFixture.besideCount) == 0
