import Editor.RealHost
import ModelTest.Check

/-!
# Model tests: `Lint/Wiring.lean`, a module that declares `.contract`

The wiring-set linter's fixture of a contract module: its list is of the
wiring set too, which a check set runs from its `.wired` group.
-/

/-- This module's declaration: a fixture's. -/
def wiringSet.ModelTest.Lint.Wiring.Contract : Editor.WiringSet :=
  .contract "a stand-in port"

/-- This module's checks. -/
def ModelTest.WiringFixture.contractChecks : List ModelTest.Check :=
  [{ name := "a contract check", run := pure true }]
