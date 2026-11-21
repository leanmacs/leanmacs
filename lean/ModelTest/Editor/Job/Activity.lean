import Editor.Job.Activity
import ModelTest.Check

/-!
# Model tests: `Editor/Job/Activity.lean`

The model tests of `Editor/Job/Activity.lean`: `activityChecks`. The root
module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- The checks of a host's activity count (`Editor/Job/Activity.lean`), each
on a count of its own, on the check's own thread: nothing here sleeps or
waits on another thread. -/
def activityChecks : List Check :=
  [{  name :=
        "an activity count goes up at each begin and down at each done, and its epoch moves at every change"
      run := do
        let activity ← Job.Activity.counting
        let start ← activity.seen
        activity.begin
        activity.begin
        let two ← activity.seen
        activity.done
        let one ← activity.seen
        activity.done
        let none ← activity.seen
        return start == { running := 0, epoch := 0 } && two == { running := 2, epoch := 2 } &&
            one == { running := 1, epoch := 3 } &&
            none == { running := 0, epoch := 4 } &&
            (← activity.refused) == 0 },
    { name :=
        "a count that went from 0 to 1 and back to 0 between two readings is not idle since the first: the epoch moved"
      run := do
        let activity ← Job.Activity.counting
        let before ← activity.seen
        let still := before.idleSince (← activity.seen)
        activity.begin
        activity.done
        let after ← activity.seen
        return still && after.running == 0 && !before.idleSince after && after.idleSince after },
    { name := "a done with nothing held changes nothing, and is counted as refused"
      run := do
        let activity ← Job.Activity.counting
        activity.done
        let seen ← activity.seen
        return seen == { running := 0, epoch := 0 } && (← activity.refused) == 1 },
    { name := "a wait for a change since an epoch the count has moved past has ended at once"
      run := do
        let activity ← Job.Activity.counting
        let before ← activity.seen
        activity.begin
        let changed ← activity.changedSince before.epoch
        return (← IO.hasFinished changed) },
    { name :=
        "a wait for a change since the current epoch has not ended until the next begin, and has ended once it has"
      run := do
        let activity ← Job.Activity.counting
        activity.begin
        activity.done
        let now ← activity.seen
        let changed ← activity.changedSince now.epoch
        let again ← activity.changedSince now.epoch
        let early := (← IO.hasFinished changed) || (← IO.hasFinished again)
        activity.begin
        -- The begin resolved the waiter on this thread, so the task has
        -- ended: `IO.wait` returns, and nothing slept.
        IO.wait changed
        IO.wait again
        return !early && (← IO.hasFinished changed) && (← IO.hasFinished again) },
    { name :=
        "an untracked count is never idle: it reads one unit held whatever is begun or done, and says it is not tracked"
      run := do
        let activity := Job.Activity.untracked
        let before ← activity.seen
        activity.begin
        activity.done
        activity.done
        let after ← activity.seen
        return !before.idleSince after && after.running == 1 && !activity.tracked &&
            (← Job.Activity.counting).tracked }]

end ModelTest
