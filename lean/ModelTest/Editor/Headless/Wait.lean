import Editor.Headless.Wait
import ModelTest.Check

/-!
# Model tests: `Editor/Headless/Wait.lean`

The model tests of a driver's wait's round judgement (`Round.judge`), the
one both drivers' waits call, the real host's and a stepped one's:
`waitRoundChecks`; and of a stepped host's wait over its fakes, judged at
their rest (`Rest.judge`): `restVerdictChecks`. The root module `ModelTest` runs them; its module doc
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

/-- A rest of a `join` with a job still running and nothing off the
caller's thread, a minute left before its guard: each check changes what it
is about. -/
def busyRest : Rest :=
  { busy := true, offThread := false, remaining := 60000, still := some .working, hung := .busy }

/-- The checks of a stepped wait's verdict at the rest of its fakes, each a
pure verdict, one a branch of `Rest.judge`. -/
def restVerdictChecks : List Check :=
  [{  name := "a rest whose wait is no longer busy is settled, whatever else it found"
      run := do
        let done : Rest := { busyRest with busy := false }
        return Rest.judge done == .answer .settled &&
            Rest.judge
                { done with
                  offThread := true, remaining := 0 } ==
              .answer .settled },
    { name :=
        "a busy rest with a reload in flight blocks on the reload's wake-up, even for a wait with an idle outcome"
      run := do
        let reloading : Rest := { busyRest with offThread := true }
        return Rest.judge reloading == .blockOnReload &&
            Rest.judge
                { reloading with
                  still := none, hung := .reloading } ==
              .blockOnReload },
    { name :=
        "a busy rest with nothing off the thread answers the wait's idle outcome at once, or working for a wait with none, never a hang, even at its guard"
      run := do
        return Rest.judge busyRest == .answer .working &&
            Rest.judge { busyRest with still := some .settled } == .answer .settled &&
            Rest.judge
                { busyRest with
                  still := none, hung := .reloading } ==
              .answer .working &&
            Rest.judge { busyRest with remaining := 0 } == .answer .working },
    { name :=
        "a busy rest blocked on a reload in flight whose guard has run out hangs, with the wait's hang"
      run := do
        let reloading : Rest :=
          { busyRest with
            offThread := true, remaining := 0 }
        return Rest.judge reloading == .hang .busy &&
            Rest.judge { reloading with hung := .reloading } == .hang .reloading }]

end ModelTest
