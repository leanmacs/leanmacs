import Editor.Headless.Wait
import ModelTest.Check

/-!
# Model tests: `Editor/Headless/Wait.lean`

The model tests of a driver's wait's round judgement (`Round.judge`), the
one both drivers' waits call, the real host's and a stepped one's:
`waitRoundChecks`. The root module `ModelTest` runs them; its module doc
says what they show.
-/

namespace ModelTest

open Editor
open Editor.Headless

/-- A round of a `join` that found a job still running, the count at 1 at
the epoch it began with, a minute left before its guard: each check changes
what it is about. -/
def busyRound : Round :=
  { busy := true, tracked := true, before := { running := 1, epoch := 4 },
    now := { running := 1, epoch := 4 }, due := false, remaining := 60000, still := some .working,
    hung := .busy }

/-- The checks of a wait's round judgement, each a pure verdict. -/
def waitRoundChecks : List Check :=
  [{  name := "a round whose wait is no longer busy is settled, whatever else it found"
      run := do
        let done : Round := { busyRound with busy := false }
        return Round.judge done == .answer .settled &&
            Round.judge
                { done with
                  now := { running := 0, epoch := 9 }, remaining := 0 } ==
              .answer .settled &&
            Round.judge { done with tracked := false } == .answer .settled },
    { name :=
        "a busy round at idle, the count 0 at the epoch it began with and no fake-clock wait due, answers the wait's idle outcome"
      run := do
        let idle : Round :=
          { busyRound with
            before := { running := 0, epoch := 4 }, now := { running := 0, epoch := 4 } }
        return Round.judge idle == .answer .working &&
            Round.judge { idle with still := some .ended } == .answer .ended &&
            Round.judge { idle with remaining := 0 } == .answer .working },
    { name :=
        "a busy round at idle whose wait has no idle outcome, a settle's, blocks until its guard, then hangs"
      run := do
        let idle : Round :=
          { busyRound with
            before := { running := 0, epoch := 4 }, now := { running := 0, epoch := 4 },
            still := none, hung := .reloading }
        return Round.judge idle == .block 4 &&
            Round.judge { idle with remaining := 0 } == .hang .reloading },
    { name :=
        "a busy round with the count 0 but moved since it began, or 0 with a fake-clock wait due, goes round again, even at its guard"
      run := do
        let moved : Round :=
          { busyRound with
            before := { running := 1, epoch := 4 }, now := { running := 0, epoch := 5 } }
        let due : Round :=
          { busyRound with
            before := { running := 0, epoch := 4 }, now := { running := 0, epoch := 4 },
            due := true }
        return Round.judge moved == .again && Round.judge { moved with remaining := 0 } == .again &&
            Round.judge due == .again &&
            Round.judge { due with still := none } == .again },
    { name :=
        "a busy round with work still running blocks on the count's next change after the epoch it read, and at its guard hangs with the wait's hang outcome"
      run := do
        let moved : Round := { busyRound with now := { running := 2, epoch := 7 } }
        return Round.judge busyRound == .block 4 && Round.judge moved == .block 7 &&
            Round.judge { busyRound with remaining := 0 } == .hang .busy },
    { name :=
        "a busy round of a host that keeps no count is never idle and never goes round again: it blocks, then hangs at its guard"
      run := do
        let untracked : Round :=
          { busyRound with
            tracked := false, before := { running := 0, epoch := 0 },
            now := { running := 0, epoch := 0 } }
        return Round.judge untracked == .block 0 &&
            Round.judge { untracked with now := { running := 0, epoch := 3 } } == .block 3 &&
            Round.judge { untracked with remaining := 0 } == .hang .busy }]

end ModelTest
