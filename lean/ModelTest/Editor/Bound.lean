import Editor.Bound
import ModelTest.Check

/-!
# Model tests: `Editor/Bound.lean`

The model tests of `Editor/Bound.lean`: `boundChecks`. The root module
`ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- The checks of the typed time bounds (`Editor/Bound.lean`). None waits
on time to pass but the one whose guard is 0 ms, held for good on purpose. -/
def boundChecks : List Check :=
  [{  name := "a hang guard's message names the event it waited for and its bound"
      run := do
        let guard := HangGuard.on "the job's done" 130000
        return guard.hang == "a hang: the job's done had not come within 130000 ms" &&
            guard.what == "the job's done" &&
            guard.ms == 130000 &&
            !guard.heldForGood },
    { name := "a guard run out on purpose says that what it waited for is held for good"
      run := do
        let guard := HangGuard.held "the stuck write" 50
        return guard.heldForGood &&
            guard.hang == "run out on purpose: the stuck write is held for good, after 50 ms" },
    { name := "real time under test names the timing that is its subject"
      run := do
        let span := RealTime.under "the debounce" 50
        return span.timing == "the debounce" && span.ms == 50 },
    { name := "a guarded wait on a task that has ended is its value, at once"
      run := do
        -- A bound of 0 ms would run out at once if the clock were read
        -- before the task was looked at.
        return (← (HangGuard.on "an ended task" 0).within (Task.pure 7)) == some 7 },
    { name := "a guarded wait on a task that ends is its value"
      run := do
        let done : IO.Promise Nat ← IO.Promise.new
        let waited ←
          IO.asTask (prio := .dedicated)
              ((HangGuard.on "the promise's value" 130000).within done.result?)
        done.resolve 3
        return (← IO.wait waited).toOption == some (some (some 3)) },
    { name := "a guard held for good runs out to none"
      run := do
        let never : IO.Promise Nat ← IO.Promise.new
        let outcome ← (HangGuard.held "a promise nobody resolves" 0).within never.result?
        -- Resolved only now, so it is not dropped, and ended, while held.
        never.resolve 0
        return outcome.isNone },
    { name := "a deadline of 0 ms has expired, and what is left of it is a guard on the same event"
      run := do
        let deadline ← (HangGuard.on "the event" 0).deadline
        let rest ← deadline.rest
        return (← deadline.expired) && rest.what == "the event" && rest.ms == 0 }]

/-! A number of milliseconds is not a hang guard, nor real time under test,
and their constructors are the module's: a bound says which kind it is. -/

example : True := by
  fail_if_success exact (fun (_ : HangGuard) => True.intro) 5000
  trivial

example : True := by
  fail_if_success exact (fun (_ : HangGuard) => True.intro) ⟨"x", 1, false⟩
  trivial

example : True := by
  fail_if_success
    exact (fun (_ : HangGuard) => True.intro) { what := "x", ms := 1, heldForGood := false }
  trivial

example : True := by
  fail_if_success exact (fun (_ : RealTime) => True.intro) 50
  trivial

example : True := by
  fail_if_success exact (fun (_ : RealTime) => True.intro) ⟨"x", 1⟩
  trivial

end ModelTest
