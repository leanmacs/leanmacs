import Editor.RealHost
import ModelTest.Check

/-!
# Model tests: `Lint/Wiring.lean`, a module that declares `.edge`

The wiring-set linter's fixture of an edge: its checks are of no module of
the wiring set, so a check set runs them from a `.plain` group.
-/

/-- This module's declaration: a fixture's. -/
def wiringSet.ModelTest.Lint.Wiring.Edge : Editor.WiringSet :=
  .edge "a fixture of the wiring-set linter"

/-- This module's checks. -/
def ModelTest.WiringFixture.edgeChecks : List ModelTest.Check :=
  [{ name := "an edge's check", run := pure true }]
