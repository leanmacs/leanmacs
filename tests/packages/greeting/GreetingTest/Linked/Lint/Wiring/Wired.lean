import Editor.RealHost

/-!
# Greeting tests: `Linked/Lint/Wiring/Wired.lean`

The wiring-set linter's fixture of a module that declares `.wiring` under a
package's linked root: a list of checks, and a table of one scenario over a
stand-in marked a real host, which the fixtures' `main`s in
`GreetingTest/Linked/Lint/Wiring.lean` reach. It holds no check that a run
makes.
-/

/-- This module's declaration: a fixture's. -/
def wiringSet.GreetingTest.Linked.Lint.Wiring.Wired : Editor.WiringSet :=
  .wiring "a stand-in for a real adapter" "a fixture of the wiring-set linter"

namespace GreetingTest.WiringFixture

/-- A fixture's check. -/
structure Check where
  /-- What must hold. -/
  name : String
  /-- Observes it. -/
  run : IO Bool

/-- This module's checks. -/
def wiredChecks : List Check :=
  [{ name := "a wired check", run := pure true }]

/-- The mark of `scenario`, before it. -/
def scenario.realHost : Editor.RealHost :=
  .loop

/-- A stand-in for a scenario over a real host: marked, though it runs
nothing. -/
def scenario (_ : List String) : IO UInt8 :=
  pure 0

/-- The mark of `scenarios`, before it: running a scenario of it runs a
real host. -/
def scenarios.realHost : Editor.RealHost :=
  .loop

/-- The table of this module's scenarios. -/
def scenarios : List Editor.Scenario :=
  [{ command := "scenario", run := scenario }]

end GreetingTest.WiringFixture
