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

/-! A count wait (kind a of `docs/dev-practices/inferred-waits.md`) is
refused by `linter.inferredWait` outside its own module, its subject modules
and the test modules that mirror them. -/

/--
error: `Editor.Job.Activity.seen`, in `ModelTest.LintFixture.countRead`, is an inferred wait (count): it infers done from something shared, not from a signal for this work. It is allowed only in Editor.Job.Activity, Editor.Job.Runner, Editor.Headless, Editor.Headless.Stepped, Editor.Headless.Wait, Editor.Loop, Editor.Job.HandleContract, Editor.Test.Jobs, Editor.Test.Linked.Jobs and the test modules that mirror them; wait on the work's own handle, promise or flush, or, for a site a later phase removes, `set_option linter.inferredWait false in` with its row of docs/dev-practices/inferred-waits.md

Note: This linter can be disabled with `set_option linter.inferredWait false`
-/
#guard_msgs in
/-- A bad declaration: the count read to know that one job has ended. -/
def ModelTest.LintFixture.countRead (activity : Editor.Job.Activity) : BaseIO Bool :=
  return (← activity.seen).running == 0

/-! In the module that declares an inferred wait, or one of its subject
modules, when that is a test module, a public declaration that references
it must carry the attribute itself: a kit cannot hand it on to everyone. -/

/-- A stand-in for an inferred wait, declared here so this test module is
its own module, where a reference to it is allowed. -/
@[inferred_wait count]
def ModelTest.LintFixture.sharedCount : BaseIO Nat :=
  pure 0

/--
error: `ModelTest.LintFixture.launders` is public and hands on `ModelTest.LintFixture.sharedCount`, an inferred wait (count): tag it `@[inferred_wait count …]` or make it private

Note: This linter can be disabled with `set_option linter.inferredWait false`
-/
#guard_msgs in
/-- A bad declaration: a public wrapper of an inferred wait, untagged. -/
def ModelTest.LintFixture.launders : BaseIO Nat :=
  ModelTest.LintFixture.sharedCount

/-- A wrapper that carries the attribute is itself restricted, and is
refused nothing here. -/
@[inferred_wait count]
def ModelTest.LintFixture.tagged : BaseIO Nat :=
  ModelTest.LintFixture.sharedCount

/-! A wait does not take a number of milliseconds: `Job.awaitWithin` takes a
`HangGuard`. -/

example : True := by
  fail_if_success
    exact (fun (_ : IO (Option Nat)) => True.intro) (Job.awaitWithin 5000 (Task.pure 1))
  trivial
