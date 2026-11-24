import Editor.RealHost
import Editor.Test.Linked.Host
import GreetingTest.Linked.Lint.Wiring.Wired

/-!
# Greeting tests: `Linked/Lint/Wiring.lean`

The wiring-set linter's fixtures of rules (c) and (d), under a package's
linked root, whose imports reach the library's bindings (through the linked
test kit), so the two rules hold here as they hold every root that links
the library: a `main` that runs its check set's wiring groups and reaches
its scenario through the table, refused nothing; one that reaches the
module's list outside the check set (c); one that runs the marked scenario
itself (c); and one with no wiring branch (d). Each bad `main` is wrapped
in `#guard_msgs`, which expects the lint's error. The `main`s are in a
namespace each, since the rules key on a declaration's last name
component, and this module declares `.edge`, as a root does, so the
real-host linter lets its `main`s reach the marked scenario. It is not
imported by `GreetingTest.Linked`, so the linked test's own `main` is not
the fixtures'. It holds no check that a run makes; model-test's fixtures of
the rules on a check set are `ModelTest/Lint/Wiring.lean`.
-/

/-- This module's declaration: a root's, as a fixture. -/
def wiringSet.GreetingTest.Linked.Lint.Wiring : Editor.WiringSet :=
  .edge "a fixture of the wiring-set linter's rules on a main"

namespace GreetingTest.WiringFixture

open Editor

/-- The fixtures' check set. -/
def checks : List (CheckGroup Unit Check) :=
  [.wired "GreetingTest.Linked.Lint.Wiring.Wired" wiringSet.GreetingTest.Linked.Lint.Wiring.Wired
      fun _ => wiredChecks]

/-- Runs `checks`'s checks, all or the wiring groups'. -/
def runAll (selected : List Check) : IO UInt32 := do
  let failed ← selected.filterM fun check => return !(← check.run)
  return if failed.isEmpty then 0 else 1

/-- Refused nothing: it runs the check set, all or its wiring groups, and
the scenario through the table. -/
def Good.main (arguments : List String) : IO UInt32 := do
  match arguments with
  | ["--wiring"] =>
    runAll ((CheckGroup.wiring checks).flatMap (·.2 ()))
  | command :: rest =>
    match scenarios.find? (·.command == command) with
    | some scenario =>
      return (← scenario.run rest).toUInt32
    | none =>
      return 2
  | [] =>
    runAll (CheckGroup.all checks ())

/--
error: `GreetingTest.WiringFixture.Reaches.main` reaches `GreetingTest.WiringFixture.wiredChecks` of `GreetingTest.Linked.Lint.Wiring.Wired`, a module of the wiring set, outside a check set: run its checks from the root's check set (`Editor.CheckGroup`), or a scenario from a table of them (`List Editor.Scenario`)

Note: This linter can be disabled with `set_option linter.wiringSet false`
-/
#guard_msgs in
/-- A bad `main` (c): it runs the module's list itself, beside the check
set's wiring groups. -/
def Reaches.main (arguments : List String) : IO UInt32 := do
  match arguments with
  | ["--wiring"] =>
    runAll ((CheckGroup.wiring checks).flatMap (·.2 ()))
  | _ =>
    runAll wiredChecks

/--
error: `GreetingTest.WiringFixture.Runs.main` reaches `GreetingTest.WiringFixture.scenario` of `GreetingTest.Linked.Lint.Wiring.Wired`, a module of the wiring set, outside a check set: run its checks from the root's check set (`Editor.CheckGroup`), or a scenario from a table of them (`List Editor.Scenario`)

Note: This linter can be disabled with `set_option linter.wiringSet false`
-/
#guard_msgs in
/-- A bad `main` (c): it runs the marked scenario itself, not through the
table. -/
def Runs.main (arguments : List String) : IO UInt32 := do
  match arguments with
  | ["--wiring"] =>
    runAll ((CheckGroup.wiring checks).flatMap (·.2 ()))
  | _ =>
    return (← scenario []).toUInt32

/--
error: `GreetingTest.WiringFixture.NoBranch.main` links the library and its imports reach `GreetingTest.Linked.Lint.Wiring.Wired`, a module of the wiring set, but it runs no check set's wiring groups: give it a `--wiring` branch over a check set (`Editor.CheckGroup.wiring checks`)

Note: This linter can be disabled with `set_option linter.wiringSet false`
-/
#guard_msgs in
/-- A bad `main` (d): it runs every check, and has no wiring branch. -/
def NoBranch.main : IO UInt32 :=
  runAll (CheckGroup.all checks ())

end GreetingTest.WiringFixture
