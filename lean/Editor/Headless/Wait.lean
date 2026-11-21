import Editor.Job.Activity

/-!
# A driver's wait, judged

What a driver's wait for its host came to (`Wait`), and the verdict of each
of its rounds (`Round.judge`), one for both drivers: the real host's wait
(`Host.waitWhile`, `Editor/Headless.lean`), which posts a marker and waits
for the loop's thread to answer it, and a stepped host's
(`Stepped.waitWhile`, `Editor/Headless/Stepped.lean`), which drains its
queue on its caller's thread. Each driver brings its loop up to date in its
own way, reads what the round found into a `Round` (through
`Wait.Kind.judge`, `Editor/Headless.lean`), and acts on the verdict: only
how a round reaches the loop and what a block waits on differ between
them, so the two waits cannot come to mean different things. What each
kind of wait waits for, a settle's, a join's or an advance's, is said once
too, beside the progress it reads (`Wait.Kind`, `Editor/Headless.lean`).

The verdict, once the loop is up to date:

- the wait is no longer busy: it is over, `settled`;
- the host is **idle**: it keeps a count (`Job.Activity.tracked`), the
  count is 0 at the epoch the round began with
  (`Job.Activity.Seen.idleSince`), and the fake clock, if the host has one,
  holds no wait that is due. Nothing left can run, so nothing can end what
  the wait is for: it is answered with the wait's idle outcome (`still`), when
  it has one. A wait with none, a `settle`'s, goes on, for what only its
  guard can end;
- the count is 0 but moved during the round, or 0 with a fake-clock wait
  due: another round at once, which says whether the host is idle now;
- otherwise the wait's guard has run out, a hang (`hung`), or it blocks on
  work still running: on the count's next change after the epoch it read,
  and on what else its driver wakes it with.

A host that keeps no count is never idle and never goes round again at
once. This module imports nothing that imports `Editor.Ffi`, so the model
tests pin the verdict (`ModelTest/Editor/Headless/Wait.lean`).
-/

namespace Editor.Headless

/-- What a driver's wait for the editor thread came to. -/
inductive Wait where
  /-- The editor thread has handled everything sent so far, and what the wait
  was for is over: no reload is running, for a `settle`, and no job, for a
  `join`. -/
  | settled
  /-- A hang: the wait reached its guard with the editor thread up to date
  and a reload still running. -/
  | reloading
  /-- The wait found the host idle (`Round.judge`) with what it was for
  still not over: for a `join`, a job still running that nothing left to
  run could end. Not a hang: nothing would change however long it waited. -/
  | working
  /-- A hang: the wait reached its guard before the editor thread had
  handled everything sent to it: it is still inside an event. -/
  | unanswered
  /-- The editor thread's loop has ended: a command quit the editor, or the
  window was asked to close. Nothing more will be handled. -/
  | ended
  /-- A hang: a `join` or an `advance` reached its guard with the host not
  idle, work still running that could end what it waits for. -/
  | busy
  deriving DecidableEq, Repr

/-- What one round of a wait found, once its driver had the loop up to
date: what the round's verdict is made of (`Round.judge`). -/
structure Round where
  /-- Whether what the wait waits for still holds of the loop's progress. -/
  busy : Bool
  /-- Whether the host keeps an activity count (`Job.Activity.tracked`). -/
  tracked : Bool
  /-- The count and its epoch as the round began, before the loop was
  brought up to date. -/
  before : Job.Activity.Seen
  /-- The count and its epoch once it was. -/
  now : Job.Activity.Seen
  /-- Whether the host's fake clock, if it has one, holds a wait that is
  due now. -/
  due : Bool
  /-- How many milliseconds are left before the wait's guard. -/
  remaining : Nat
  /-- What the wait answers once the host is idle with it still busy, if
  it answers anything then: `working` for a join's, a stall for an
  advance's, none for a settle's. -/
  still : Option Wait
  /-- What the wait answers at its guard: the hang. -/
  hung : Wait

/-- What a round of a wait comes to (`Round.judge`). -/
inductive Round.Verdict where
  /-- The wait is over and answers this: `settled`, or its idle outcome. -/
  | answer (wait : Wait)
  /-- Another round at once: the count moved, or a fake-clock wait is due. -/
  | again
  /-- The wait's guard ran out: it says the hang once and answers this. -/
  | hang (wait : Wait)
  /-- Work is still running: the wait blocks until the count changes after
  `since`, or its driver wakes it otherwise, and then goes round again. -/
  | block (since : Nat)
  deriving DecidableEq, Repr

/-- The verdict of a wait's round (the module docs). -/
def Round.judge (round : Round) : Round.Verdict :=
  if !round.busy then .answer .settled
  else
    let idle := round.tracked && round.before.idleSince round.now && !round.due
    match idle, round.still with
    | true, some still => .answer still
    | _, _ =>
      if round.tracked && !idle && round.now.running == 0 then .again
      else if round.remaining == 0 then .hang round.hung else .block round.now.epoch

end Editor.Headless
