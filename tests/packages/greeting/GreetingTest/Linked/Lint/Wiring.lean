import Editor.RealHost
import Editor.Test.Linked.Host
import GreetingTest.Linked.Lint.Wiring.Wired

/-!
# Greeting tests: `Linked/Lint/Wiring.lean`

The wiring-set linter's fixtures of rules (c) and (d), under a package's
linked root, whose imports reach the library's bindings (through the linked
test kit), so the two rules hold here as they hold every root that links
the library: a `main` that reads its mode with the shared reader
(`Editor.CheckGroup.Mode.ofArguments?`), selects its check set's checks by
it (`Editor.CheckGroup.select`) and reaches its scenario through the table,
refused nothing, nor one that reads it from its subcommands
(`Editor.CheckGroup.Mode.ofSubcommand?`), as ffi-test's `wiring`; one that
reaches the module's list outside the check set (c); one that runs the
marked scenario itself (c); and, for (d), one with no wiring mode at all,
one that prints the wiring set's lines (`Editor.CheckGroup.ranLines`) but
reads `--wiring` and runs the wiring groups itself, never selecting by
mode, one that reads `--wiring` itself and selects by the mode it maps it
to, and one that reads the mode but never selects by it. Each bad `main`
is wrapped
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

/-- Refused nothing: it reads its mode with the shared reader, runs the
checks the mode selects from the check set, and runs the scenario through
the table. -/
def Good.main (arguments : List String) : IO UInt32 := do
  match CheckGroup.Mode.ofArguments? arguments with
  | some mode =>
    runAll (CheckGroup.select mode checks ())
  | none =>
    match arguments with
    | command :: rest =>
      match scenarios.find? (·.command == command) with
      | some scenario =>
        return (← scenario.run rest).toUInt32
      | none =>
        return 2
    | [] =>
      return 2

/-- Refused nothing: its command line names the wiring run by a
subcommand, as ffi-test's `wiring`, which the shared reader of subcommands
reads, and it selects the check set's checks by that mode. -/
def Subcommand.main (arguments : List String) : IO UInt32 := do
  match CheckGroup.Mode.ofSubcommand? arguments with
  | some mode =>
    runAll (CheckGroup.select mode checks ())
  | none =>
    return 2

/--
error: `GreetingTest.WiringFixture.Reaches.main` reaches `GreetingTest.WiringFixture.wiredChecks` of `GreetingTest.Linked.Lint.Wiring.Wired`, a module of the wiring set, outside a check set: run its checks from the root's check set (`Editor.CheckGroup`), or a scenario from a table of them (`List Editor.Scenario`)

Note: This linter can be disabled with `set_option linter.wiringSet false`
-/
#guard_msgs in
/-- A bad `main` (c): it runs the module's list itself, beside the check
set's wiring groups. -/
def Reaches.main (arguments : List String) : IO UInt32 := do
  match CheckGroup.Mode.ofArguments? arguments with
  | some mode =>
    runAll (CheckGroup.select mode checks ())
  | none =>
    runAll wiredChecks

/--
error: `GreetingTest.WiringFixture.Runs.main` reaches `GreetingTest.WiringFixture.scenario` of `GreetingTest.Linked.Lint.Wiring.Wired`, a module of the wiring set, outside a check set: run its checks from the root's check set (`Editor.CheckGroup`), or a scenario from a table of them (`List Editor.Scenario`)

Note: This linter can be disabled with `set_option linter.wiringSet false`
-/
#guard_msgs in
/-- A bad `main` (c): it runs the marked scenario itself, not through the
table. -/
def Runs.main (arguments : List String) : IO UInt32 := do
  match CheckGroup.Mode.ofArguments? arguments with
  | some mode =>
    runAll (CheckGroup.select mode checks ())
  | none =>
    return (← scenario []).toUInt32

/--
error: `GreetingTest.WiringFixture.NoBranch.main` links the library and its imports reach `GreetingTest.Linked.Lint.Wiring.Wired`, a module of the wiring set, but it does not select its check set's checks by the shared wiring mode: read the mode with a shared reader (`Editor.CheckGroup.Mode.ofArguments?`, `Editor.CheckGroup.Mode.read?` or `Editor.CheckGroup.Mode.ofSubcommand?`) and run what `Editor.CheckGroup.select` selects by it from a check set

Note: This linter can be disabled with `set_option linter.wiringSet false`
-/
#guard_msgs in
/-- A bad `main` (d): it runs every check, and has no wiring mode. -/
def NoBranch.main : IO UInt32 :=
  runAll (CheckGroup.all checks ())

/--
error: `GreetingTest.WiringFixture.ByHand.main` links the library and its imports reach `GreetingTest.Linked.Lint.Wiring.Wired`, a module of the wiring set, but it does not select its check set's checks by the shared wiring mode: read the mode with a shared reader (`Editor.CheckGroup.Mode.ofArguments?`, `Editor.CheckGroup.Mode.read?` or `Editor.CheckGroup.Mode.ofSubcommand?`) and run what `Editor.CheckGroup.select` selects by it from a check set

Note: This linter can be disabled with `set_option linter.wiringSet false`
-/
#guard_msgs in
/-- A bad `main` (d): it prints the wiring set's lines, naming the check
set's wiring groups (`Editor.CheckGroup.ranLines`), but reads `--wiring`
and runs those groups itself, so nothing holds its mode to the others'. -/
def ByHand.main (arguments : List String) : IO UInt32 := do
  let status ←
    match arguments with
    | ["--wiring"] =>
      runAll ((CheckGroup.wiring checks).flatMap (·.2 ()))
    | _ =>
      runAll (CheckGroup.all checks ())
  for line in CheckGroup.ranLines "greeting" (CheckGroup.wiring checks) () do
    IO.println line
  return status

/--
error: `GreetingTest.WiringFixture.OwnReader.main` links the library and its imports reach `GreetingTest.Linked.Lint.Wiring.Wired`, a module of the wiring set, but it does not select its check set's checks by the shared wiring mode: read the mode with a shared reader (`Editor.CheckGroup.Mode.ofArguments?`, `Editor.CheckGroup.Mode.read?` or `Editor.CheckGroup.Mode.ofSubcommand?`) and run what `Editor.CheckGroup.select` selects by it from a check set

Note: This linter can be disabled with `set_option linter.wiringSet false`
-/
#guard_msgs in
/-- A bad `main` (d): it selects by mode, but reads `--wiring` itself and
maps it to the wiring mode, so its reading can drift from the others'. -/
def OwnReader.main (arguments : List String) : IO UInt32 := do
  match arguments with
  | ["--wiring"] =>
    runAll (CheckGroup.select .wiring checks ())
  | _ =>
    runAll (CheckGroup.select .all checks ())

/--
error: `GreetingTest.WiringFixture.Unselected.main` links the library and its imports reach `GreetingTest.Linked.Lint.Wiring.Wired`, a module of the wiring set, but it does not select its check set's checks by the shared wiring mode: read the mode with a shared reader (`Editor.CheckGroup.Mode.ofArguments?`, `Editor.CheckGroup.Mode.read?` or `Editor.CheckGroup.Mode.ofSubcommand?`) and run what `Editor.CheckGroup.select` selects by it from a check set

Note: This linter can be disabled with `set_option linter.wiringSet false`
-/
#guard_msgs in
/-- A bad `main` (d): it reads its mode with the shared reader, but runs
every check whatever the mode, never selecting by it. -/
def Unselected.main (arguments : List String) : IO UInt32 := do
  match CheckGroup.Mode.ofArguments? arguments with
  | some _ =>
    runAll (CheckGroup.all checks ())
  | none =>
    return 2

end GreetingTest.WiringFixture
