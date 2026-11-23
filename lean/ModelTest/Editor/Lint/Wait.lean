import Editor.Job.Runner
import Editor.Lint.Wait
import ModelTest.Check

/-!
# Model tests: `Editor/Lint/Wait.lean`

The model tests of `Editor/Lint/Wait.lean`: `lintWaitChecks`, the rules on
module names the linters apply, and, below them, the linters' fixtures:
each a bad declaration wrapped in `#guard_msgs`, which expects the lint's
error (an error under `warningAsError`), so a build of this module shows
that the linter refuses it, and the declaration is no check of the suite.
The root module `ModelTest` runs the checks; its module doc says what each
shows.
-/

namespace ModelTest

open Editor

/-- The checks of the wait linters' rules on module names
(`Editor/Lint/Wait.lean`): what a test module is, and which test module
mirrors which. -/
def lintWaitChecks : List Check :=
  [{  name :=
        "a test module is one whose first name component ends in Test, or the core's test kits under Editor.Test"
      run :=
        return Lint.isTestModule `ModelTest.Editor.Job.Activity &&
            Lint.isTestModule `CompileTest.Linked &&
            Lint.isTestModule `FilesApiTest.Fake &&
            Lint.isTestModule `Editor.Test.Linked.Host &&
            !Lint.isTestModule `Editor.Job.Activity &&
            !Lint.isTestModule `Editor.Headless &&
            !Lint.isTestModule `Editor.Testing },
    { name := "a test module mirrors the module it names under its root, and no other"
      run :=
        return Lint.mirrors `ModelTest.Editor.Job.Activity `Editor.Job.Activity &&
            Lint.mirrors `ContractTest.Editor.Job.Activity `Editor.Job.Activity &&
            !Lint.mirrors `ModelTest.Editor.Job.Activity `Editor.Job.Runner &&
            !Lint.mirrors `Editor.Job.Activity `Editor.Job.Activity &&
            !Lint.mirrors `ModelTest `Editor.Job.Activity }]

end ModelTest

/-! A raw sleep, and a raw read of the clock, are refused by `linter.rawClock`
outside `Editor.Bound`. -/

/--
error: `IO.sleep` reads the clock: a wait takes a `HangGuard`, real time under test is `RealTime.sleep` (`Editor/Bound.lean`), and a measurement of real time says so with `set_option linter.rawClock false in` and its reason

Note: This linter can be disabled with `set_option linter.rawClock false`
-/
#guard_msgs in
/-- A bad declaration: a raw sleep. -/
def ModelTest.LintFixture.sleeps : IO Unit :=
  IO.sleep 10

/--
error: `IO.monoMsNow` reads the clock: a wait takes a `HangGuard`, real time under test is `RealTime.sleep` (`Editor/Bound.lean`), and a measurement of real time says so with `set_option linter.rawClock false in` and its reason

Note: This linter can be disabled with `set_option linter.rawClock false`
-/
#guard_msgs in
/-- A bad declaration: a deadline worked out from the raw clock. -/
def ModelTest.LintFixture.deadline (bound : Nat) : IO Nat :=
  return (← IO.monoMsNow) + bound

/-! A wait does not take a number of milliseconds: `Job.awaitWithin` takes a
`HangGuard`. -/

example : True := by
  fail_if_success
    exact (fun (_ : IO (Option Nat)) => True.intro) (Job.awaitWithin 5000 (Task.pure 1))
  trivial
