import Editor.RealHost
import ModelTest.Check

/-!
# Model tests: `Lint/RealHost.lean`, an edge

The real-host linter's fixtures of a module that declares `.edge`, as an
executable's root does: its `main` may start real services, directly or
through a private helper, and nothing else of it may. The `main` here is
in a namespace, beside the test root's own.
-/

/-- This module's declaration: a fixture's. -/
def ModelTest.Lint.RealHost.Edge.wiringSet : Editor.WiringSet :=
  .edge "a fixture's main starts a stand-in service"

/-- The mark of `realService`, before it. -/
def ModelTest.RealHostEdgeFixture.realService.realHost : Editor.RealHost :=
  .service

/-- A stand-in for a real service, marked. -/
def ModelTest.RealHostEdgeFixture.realService : IO Unit :=
  pure ()

/-- A private helper of `main` that starts the service: linted where `main`
references it. -/
private def ModelTest.RealHostEdgeFixture.startServices : IO Unit :=
  ModelTest.RealHostEdgeFixture.realService

/-- An edge's `main`: refused nothing. -/
def ModelTest.RealHostEdgeFixture.main : IO UInt32 := do
  ModelTest.RealHostEdgeFixture.startServices
  ModelTest.RealHostEdgeFixture.realService
  return 0

/--
error: `ModelTest.RealHostEdgeFixture.realService`, in `ModelTest.RealHostEdgeFixture.serviceCheck`, runs a real background service (service): `ModelTest.Lint.RealHost.Edge` declares an edge, and only its `main` may reach one

Note: This linter can be disabled with `set_option linter.realHost false`
-/
#guard_msgs in
/-- A bad declaration: a check of an edge that starts the service. -/
def ModelTest.RealHostEdgeFixture.serviceCheck : ModelTest.Check :=
  { name := "a check of a root over a real service",
    run := do
      ModelTest.RealHostEdgeFixture.realService
      return true }
