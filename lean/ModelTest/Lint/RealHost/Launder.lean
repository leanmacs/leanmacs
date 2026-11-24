import Editor.RealHost
import ModelTest.Check

/-!
# Model tests: `Lint/RealHost.lean`, the launder rule

The real-host linter's fixtures of a module of the wiring set that declares
`.wiring`: its checks may reach a real host, and a list of them is exported
unmarked, since it can only be run; a public helper that hands one on
unmarked, directly or through a private one, is refused.
-/

/-- This module's declaration: a fixture's. -/
def wiringSet.ModelTest.Lint.RealHost.Launder : Editor.WiringSet :=
  .wiring "a stand-in for a real host, marked here" "a fixture of the launder rule"

/-- The mark of `realLoop`, before it. -/
def ModelTest.RealHostLaunderFixture.realLoop.realHost : Editor.RealHost :=
  .loop

/-- A stand-in for a real host, marked. -/
def ModelTest.RealHostLaunderFixture.realLoop : IO Unit :=
  pure ()

/-- A private helper over the real host: not refused, as it is private. -/
private def ModelTest.RealHostLaunderFixture.hidden : IO Unit :=
  ModelTest.RealHostLaunderFixture.realLoop

/-- A list of checks over the real host, directly and through the private
helper: refused nothing, as it hands out only its runs. -/
def ModelTest.RealHostLaunderFixture.wiringChecks : List ModelTest.Check :=
  [{  name := "a wiring check"
      run := do
        ModelTest.RealHostLaunderFixture.realLoop
        return true },
    { name := "a wiring check through a private helper"
      run := do
        ModelTest.RealHostLaunderFixture.hidden
        return true }]

/--
error: `ModelTest.RealHostLaunderFixture.launders` is public and hands on `ModelTest.RealHostLaunderFixture.realLoop`, which runs a real editor loop thread (loop): mark it, with `def ModelTest.RealHostLaunderFixture.launders.realHost : RealHost := .loop` before it, or make it private

Note: This linter can be disabled with `set_option linter.realHost false`
-/
#guard_msgs in
/-- A bad declaration: a public helper that hands the real host on, unmarked. -/
def ModelTest.RealHostLaunderFixture.launders : IO Unit :=
  ModelTest.RealHostLaunderFixture.realLoop

/--
error: `ModelTest.RealHostLaunderFixture.laundersPrivately` is public and hands on `ModelTest.RealHostLaunderFixture.realLoop`, which runs a real editor loop thread (loop), through `ModelTest.RealHostLaunderFixture.hidden`: mark it, with `def ModelTest.RealHostLaunderFixture.laundersPrivately.realHost : RealHost := .loop` before it, or make it private

Note: This linter can be disabled with `set_option linter.realHost false`
-/
#guard_msgs in
/-- A bad declaration: a public helper that hands it on through a private
one, unmarked. -/
def ModelTest.RealHostLaunderFixture.laundersPrivately (body : IO Bool) : IO Bool := do
  ModelTest.RealHostLaunderFixture.hidden
  body
