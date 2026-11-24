import ConfigTest.Editor.Headless
import Editor.RealHost

/-!
# Config tests: support for the real-host wiring checks

`withdrawingHeld`, which holds a real host's loop as it ends, in the
withdrawal of its jobs' waits: shared by the bracket's wiring checks
(`ConfigTest/Editor/Headless/Real/Bracket.lean`) and the runner's
(`ConfigTest/Editor/Headless/Real/Runner.lean`), the two modules of the
wiring set that hold a real loop past its guard. It holds no checks of its
own.
-/

namespace ConfigTest

open Editor
open Editor.Test.Linked

/-- The mark of `withdrawingHeld`: it runs a real editor loop thread (`Editor/RealHost.lean`). -/
def withdrawingHeld.realHost : Editor.RealHost :=
  .loop

/-- Runs `check` with `stage`'s collaborators, for one host's run of
`jobScript` that reaches its end: the loop's withdrawal of the job's wait, as
the loop ends, is held (`hold`) and then noted in `withdrew`, and each
dispose pushes onto `order` whether the withdrawal came first.

The spawn's line returns only once the job's wait is one the loop's end
withdraws: recorded as the job's by the runner. The event that says so is
the job's own `done`, the unit it gives back as it parks, which the runner
gives only after it has recorded the wait (`Job.drive`). The clock's own
arrival (`.waiting 1`) is too early: the clock has the wait inside its
`start`, before the runner has its answer, and a loop that ends then finds
no wait to withdraw and is never held. And it is not the job's own: any
wait on the stage's clock reaches it. The spawn's line waits first for the
check's own wrapper of the clock's `start` to have started the job's wait
(`started`), its own signal (row W5 of
`docs/dev-practices/inferred-waits.md`, which stays: the loop's end
withdrawing the job's wait is the subject, A3).

- **The hold at the clock's `start`** keeps the job's thread there, the
  wait on the clock and not yet recorded, until the spawn's line has seen
  the clock's arrival. So every run goes through the state a slow machine
  reaches by itself, and a line that returned on the clock's arrival would
  end the loop unheld every time.
- **The job's `done`** is told from the reload's, which gives its unit
  back on its own thread after its wake-up and can come late: only a `done`
  on the thread that was held at `start` counts.
- **The count** is this one host's own, made here and handed over with
  `tracksIdle := false`, so that `Collaborators.prepared` keeps it and its
  `done` can be seen; a fresh count for the host is all `tracksIdle` would
  have given it.

**The job's wake-up is held until the loop's end waits for it.** The loop's
end cancels the job, which ends on a pool thread and then posts its wake-up
to the editor queue, the library's, which the next check's host shares. A
stage's loop waits for that as it ends (`Collaborators.endCancelled`, which
`Stage.new` sets). Here the post is held until the loop's end has handed
over what it waits on, so every run goes through the state a loaded machine
reaches by itself, the job cancelled and its wake-up not yet posted: a
loop's end that did not wait would end with the wake-up still to come, and
`check`, looking at the queue once its host has ended, would find none.

The job's thread and the job's post are let go before this returns,
whatever `check` did. -/
def withdrawingHeld {α β σ : Type} (stage : Stage β σ) (hold : BaseIO Unit) (withdrew : IO.Ref Bool)
    (order : IO.Ref (Array Bool)) (check : Headless.Collaborators β σ TestScheme.scheme → IO α) :
    IO α := do
  let staged := stage.collaborators
  let timers := staged.services.timers
  let queue := staged.queue
  let count ← Job.Activity.counting
  -- Resolved to let the job's thread go on from the clock's `start`.
  let entering ← IO.Promise.new
  -- Resolved by the wrapper of the clock's `start` once it has started the
  -- job's wait.
  let started : IO.Promise Unit ← IO.Promise.new
  -- The thread held at the clock's `start`: the job's.
  let holder ← IO.mkRef (none : Option UInt64)
  -- Resolved by the job's `done`, after the count has taken it.
  let parked ← IO.Promise.new
  -- Resolved to let the job's wake-up be posted.
  let posting : IO.Promise Unit ← IO.Promise.new
  let activity : Job.Activity :=
    { count with
      done := do
        count.done
        if (← holder.get) == some (← IO.getTID) then
          parked.resolve () }
  try
    check
        { staged with
          tracksIdle := false
          queue :=
            { queue with
              post := fun posted => do
                if posted.source == staged.jobs then
                  discard <| IO.wait posting.result?
                queue.post posted }
          endCancelled := fun cancelled => do
            posting.resolve ()
            staged.endCancelled cancelled
          emit := fun line => do
            if line == "spawn count: job 1" then
              -- hang guard: the job's wait started on the clock, by the
              -- wrapper of its `start`; only a hang reaches the bound.
              unless (← Job.awaitWithin hangGuard started.result?).isSome do
                throw <|
                    IO.userError
                      s!"a hang: the job's sleep had not reached the clock within {hangGuard.ms} ms"
              entering.resolve ()
              -- hang guard: the job's `done` as it parks, its wait recorded;
              -- only a hang reaches the bound, and the check then fails as a hang.
              unless (← Job.awaitWithin hangGuard parked.result?).isSome do
                throw <|
                    IO.userError
                      s!"a hang: the job had not given its unit back within {hangGuard.ms} ms of its sleep's start"
            staged.emit line
          services :=
            { staged.services with
              activity
              timers :=
                { timers with
                  start := fun id deadline => do
                    timers.start id deadline
                    holder.set (some (← IO.getTID))
                    started.resolve ()
                    discard <| IO.wait entering.result?
                  cancel := fun id => do
                    hold
                    timers.cancel id
                    withdrew.set true } }
          dispose := do
            order.modify (·.push (← withdrew.get))
            staged.dispose }
  finally
    entering.resolve ()
    posting.resolve ()

end ConfigTest
