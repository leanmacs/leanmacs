import Editor.Job.Runner
import ModelTest.Check

/-!
# Model tests: `Lint/Wait.lean`

The wait linters' fixtures that need nothing but the model tests' modules:
each a bad declaration wrapped in `#guard_msgs`, which expects the lint's
error (an error under `warningAsError`), so a build of this module shows
that the linter refuses it, and the declaration is no check of the suite.
This module imports nothing of the linters: the build loads them as a Lean
plugin (`lean/lakefile.lean`, `lintPlugin`), and `model-test` links no
module of Lean's frontend. Their checks, which call the linters'
functions and so import them, are `LintTest.lintWaitChecks`
(`LintTest/Lint/Wait.lean`).
-/

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
it must have a mark itself: a kit cannot hand it on to everyone. -/

/-- The mark of `sharedCount`. -/
def ModelTest.LintFixture.sharedCount.inferredWait : Editor.InferredWait :=
  .count

/-- A stand-in for an inferred wait, declared here so this test module is
its own module, where a reference to it is allowed. -/
def ModelTest.LintFixture.sharedCount : BaseIO Nat :=
  pure 0

/--
error: `ModelTest.LintFixture.launders` is public and hands on `ModelTest.LintFixture.sharedCount`, an inferred wait (count): mark it, with `def ModelTest.LintFixture.launders.inferredWait : InferredWait := .count […]` before it, or make it private

Note: This linter can be disabled with `set_option linter.inferredWait false`
-/
#guard_msgs in
/-- A bad declaration: a public wrapper of an inferred wait, untagged. -/
def ModelTest.LintFixture.launders : BaseIO Nat :=
  ModelTest.LintFixture.sharedCount

/-- The mark of `tagged`, before it, as the linter reads it. -/
def ModelTest.LintFixture.tagged.inferredWait : Editor.InferredWait :=
  .count

/-- A wrapper that has a mark is itself restricted, and is refused nothing
here. -/
def ModelTest.LintFixture.tagged : BaseIO Nat :=
  ModelTest.LintFixture.sharedCount

/-! An allow covers the one declaration it is on, and a listed site's check
is a declaration of its own: so a check list holding such a check refuses
a new inferred wait written in the list beside it. -/

-- The allow a listed site's check carries (a fixture: no row of its own).
set_option linter.inferredWait false in
/-- A check under an allow, a declaration of its own, as each listed site's
check is. -/
def ModelTest.LintFixture.allowedCheck (activity : Editor.Job.Activity) : ModelTest.Check :=
  { name := "a check under an allow",
    run := do
      return (← activity.seen).running == 0 }

/--
error: `Editor.Job.Activity.seen`, in `ModelTest.LintFixture.listChecks`, is an inferred wait (count): it infers done from something shared, not from a signal for this work. It is allowed only in Editor.Job.Activity, Editor.Job.Runner, Editor.Headless, Editor.Headless.Stepped, Editor.Headless.Wait, Editor.Loop, Editor.Job.HandleContract, Editor.Test.Jobs, Editor.Test.Linked.Jobs and the test modules that mirror them; wait on the work's own handle, promise or flush, or, for a site a later phase removes, `set_option linter.inferredWait false in` with its row of docs/dev-practices/inferred-waits.md

Note: This linter can be disabled with `set_option linter.inferredWait false`
-/
#guard_msgs in
/-- A bad declaration: a check list with no allow, which holds a check under
one, given a new check that reads the count. -/
def ModelTest.LintFixture.listChecks (activity : Editor.Job.Activity) : List ModelTest.Check :=
  [ModelTest.LintFixture.allowedCheck activity,
    { name := "a new check",
      run := do
        return (← activity.seen).running == 0 }]

/-! A mark the linter cannot read is refused where the constant it marks is
referenced, in any module: one of another type than `Editor.InferredWait`,
and one whose value is not a kind applied to a list of module names
written out or named. -/

/-- A bad mark: not of the type of a mark. -/
def ModelTest.LintFixture.mistyped.inferredWait : Nat :=
  0

/-- A constant with a bad mark. -/
def ModelTest.LintFixture.mistyped : Nat :=
  0

/--
error: `ModelTest.LintFixture.mistyped.inferredWait` is named as a mark and is not of the type `Editor.InferredWait`

Note: This linter can be disabled with `set_option linter.inferredWait false`
-/
#guard_msgs in
/-- A reference to a constant whose mark is of another type. -/
def ModelTest.LintFixture.readsMistyped : Nat :=
  ModelTest.LintFixture.mistyped

/-- A bad mark: its kind is worked out, not written. -/
def ModelTest.LintFixture.computed.inferredWait : Editor.InferredWait :=
  if true then .count else .idle

/-- A constant with a bad mark. -/
def ModelTest.LintFixture.computed : Nat :=
  0

/--
error: `ModelTest.LintFixture.computed.inferredWait` is a mark the wait linter cannot read: write its value as a kind applied to a literal list of module names, or to a constant that is one, as `.count [`Editor.Job.Runner]`

Note: This linter can be disabled with `set_option linter.inferredWait false`
-/
#guard_msgs in
/-- A reference to a constant whose mark is worked out. -/
def ModelTest.LintFixture.readsComputed : Nat :=
  ModelTest.LintFixture.computed

/-! A wait does not take a number of milliseconds: `Job.awaitWithin` takes a
`HangGuard`. -/

example : True := by
  fail_if_success
    exact (fun (_ : IO (Option Nat)) => True.intro) (Editor.Job.awaitWithin 5000 (Task.pure 1))
  trivial
