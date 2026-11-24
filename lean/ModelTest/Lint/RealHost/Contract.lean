import Editor.RealHost
import ModelTest.Check

/-!
# Model tests: `Lint/RealHost.lean`, a contract module

The real-host linter's fixtures of a module that declares `.contract`: an
adapter's contract may reach a real service and runs no editor loop.
-/

/-- This module's declaration: a fixture's. -/
def wiringSet.ModelTest.Lint.RealHost.Contract : Editor.WiringSet :=
  .contract "a stand-in port's contract"

/-- The mark of `realService`, before it. -/
def ModelTest.RealHostContractFixture.realService.realHost : Editor.RealHost :=
  .service

/-- A stand-in for a real service, marked. -/
def ModelTest.RealHostContractFixture.realService : IO Unit :=
  pure ()

/-- The mark of `realLoop`, before it. -/
def ModelTest.RealHostContractFixture.realLoop.realHost : Editor.RealHost :=
  .loop

/-- A stand-in for a real host, marked. -/
def ModelTest.RealHostContractFixture.realLoop : IO Unit :=
  pure ()

/-- A contract check over the real service: refused nothing. -/
def ModelTest.RealHostContractFixture.serviceCheck : ModelTest.Check :=
  { name := "a contract over a real service",
    run := do
      ModelTest.RealHostContractFixture.realService
      return true }

/--
error: `ModelTest.RealHostContractFixture.realLoop`, in `ModelTest.RealHostContractFixture.loopCheck`, runs a real editor loop thread (loop): `ModelTest.Lint.RealHost.Contract` declares a contract, and a contract runs no editor loop

Note: This linter can be disabled with `set_option linter.realHost false`
-/
#guard_msgs in
/-- A bad declaration: a contract check over a real loop thread. -/
def ModelTest.RealHostContractFixture.loopCheck : ModelTest.Check :=
  { name := "a contract over a real loop thread",
    run := do
      ModelTest.RealHostContractFixture.realLoop
      return true }
