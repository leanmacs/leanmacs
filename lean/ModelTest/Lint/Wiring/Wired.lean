import Editor.RealHost
import ModelTest.Check
import ModelTest.Lint.Wiring.Helper

/-!
# Model tests: `Lint/Wiring.lean`, a module that declares `.wiring`

The wiring-set linter's fixtures of a module of the wiring set: its checks,
a single check and two lists, which a check set runs from its `.wired`
groups (`ModelTest/Lint/Wiring.lean`); and rule (b), a declaration of it
that runs checks as an IO list, refused for `IO (List String)` and
`IO (List (String × Bool))`, and allowed for a generic `IO (List β)`. The
helper it imports, which declares no wiring set, defines one too and is
refused nothing.
-/

/-- This module's declaration: a fixture's. -/
def wiringSet.ModelTest.Lint.Wiring.Wired : Editor.WiringSet :=
  .wiring "a stand-in for a real adapter" "a fixture of the wiring-set linter"

/-- A single check, which `wiredChecks` holds: reached from a check set by
unfolding. -/
def ModelTest.WiringFixture.wiredCheck : ModelTest.Check :=
  { name := "a wired check", run := return (← ModelTest.WiringFixture.helperRun).isEmpty }

/-- A list of this module's checks. -/
def ModelTest.WiringFixture.wiredChecks : List ModelTest.Check :=
  [ModelTest.WiringFixture.wiredCheck]

/-- Another list of this module's checks, which a check set may run from a
second group of this module. -/
def ModelTest.WiringFixture.wiredLater (count : Nat) : List ModelTest.Check :=
  (List.range count).map fun index => { name := s!"a later wired check {index}", run := pure true }

/--
error: `ModelTest.WiringFixture.producer` of `ModelTest.Lint.Wiring.Wired`, a module of the wiring set, runs checks as an IO list: make its checks a list of the root's check type (`List Check`), which the root's check set runs from its `.wired` group, or mark it a real host

Note: This linter can be disabled with `set_option linter.wiringSet false`
-/
#guard_msgs in
/-- A bad declaration: it runs checks and hands back their failures. -/
def ModelTest.WiringFixture.producer : IO (List String) :=
  ModelTest.failures ModelTest.WiringFixture.wiredChecks

/--
error: `ModelTest.WiringFixture.pairProducer` of `ModelTest.Lint.Wiring.Wired`, a module of the wiring set, runs checks as an IO list: make its checks a list of the root's check type (`List Check`), which the root's check set runs from its `.wired` group, or mark it a real host

Note: This linter can be disabled with `set_option linter.wiringSet false`
-/
#guard_msgs in
/-- A bad declaration: it runs checks and hands back each name and outcome. -/
def ModelTest.WiringFixture.pairProducer : IO (List (String × Bool)) :=
  ModelTest.WiringFixture.wiredChecks.mapM fun check => return (check.name, ← check.run)

/-- A generic helper over `IO (List β)`: no producer of checks, refused
nothing. -/
def ModelTest.WiringFixture.generic {β : Type} (items : List β) : IO (List β) :=
  pure items
