import ModelTest.Check

/-!
# Model tests: `Lint/Wiring.lean`, a module that declares nothing

The wiring-set linter's fixture of a module outside the wiring set: its
checks run from a `.plain` group.
-/

/-- This module's checks. -/
def ModelTest.WiringFixture.steppedChecks : List ModelTest.Check :=
  [{ name := "a stepped check", run := pure true }]
