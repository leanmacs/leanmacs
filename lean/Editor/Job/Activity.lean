/-!
# A host's activity count

What a host's idle is made of (`docs/design/concurrency.md`, "The idle
signal"): the number of units of work held that can still end by
themselves, and an epoch that moves at every change of that number. A unit
is taken (`begin`) before the thing it covers can run or post, and given
back (`done`) once it has: a job while it is runnable, a wait on a service
that ends it by itself, the reload job until it has posted its wake-up, and
an event a job, the reload, a pause or a hint delay posted until the editor
thread has handled it. Who takes and gives back each is said where it
happens (`Editor/Job/Runner.lean`, `Editor/Headless.lean`).

It is plain core code, not a port: data of closures, so a host that does not
track its idle carries `untracked`, whose steps do nothing.

- **`counting`** is one reference of the count, the epoch and at most one
  waiter: each step is one atomic change of it, and a waiter armed by
  `changedSince` is woken by the next change, outside the step.
- **Idle since a reading** (`Seen.idleSince`): the count is 0 now and the
  epoch has not moved since the earlier reading. The epoch closes the round
  in which the count went from 0 to 1 and back to 0 between two readings.
- **`untracked`** is never idle: its count reads 1 and its epoch never
  moves, and it says it is not tracked (`tracked := false`), so a waiter
  does not wait on it for a change that never comes.

Its checks are `ModelTest.activityChecks` (`ModelTest/Editor/Job/Activity.lean`).
-/

namespace Editor.Job

/-- The activity count and its epoch, read in one step. -/
structure Activity.Seen where
  /-- How many units are held. -/
  running : Nat
  /-- How many times the count has changed. -/
  epoch : Nat
  deriving DecidableEq, Repr, Inhabited

/-- Whether nothing is held now, and nothing was taken or given back since
`before`: the count is 0 and the epoch is the one `before` read. -/
def Activity.Seen.idleSince (before now : Activity.Seen) : Bool :=
  now.running == 0 && now.epoch == before.epoch

/-- A host's activity count: how it is moved and read. -/
structure Activity where
  /-- Takes a unit: the count up by one, the epoch moved, a waiter woken. -/
  begin : BaseIO Unit
  /-- Gives a unit back: the count down by one, the epoch moved, a waiter
  woken. A `done` with nothing held changes nothing, and is counted as
  refused (`refused`): it is a bug in whoever gave it. -/
  done : BaseIO Unit
  /-- The count and the epoch, read in one step. -/
  seen : BaseIO Activity.Seen
  /-- A task that ends at the first change after `epoch`, or at once if the
  epoch has already moved past it. Arms the one waiter. -/
  changedSince : Nat → BaseIO (Task Unit)
  /-- How many `done`s arrived with nothing held: for a test, which pins
  that it never happened. -/
  refused : BaseIO Nat := pure 0
  /-- Whether the count is kept: `false` only for `untracked`. -/
  tracked : Bool := true

/-- What `Activity.counting` holds. -/
structure Activity.State where
  /-- How many units are held. -/
  running : Nat := 0
  /-- How many times the count has changed. -/
  epoch : Nat := 0
  /-- The waiter the next change wakes, if one is armed. -/
  waiter : Option (IO.Promise Unit) := none
  /-- How many `done`s arrived with nothing held. -/
  refused : Nat := 0

namespace Activity

/-- Wakes `waiter`, if there is one. -/
def wake (waiter : Option (IO.Promise Unit)) : BaseIO Unit := do
  if let some waiter := waiter then
    waiter.resolve ()

/-- A count of 0 at epoch 0, with no waiter: one reference, each step one
atomic change of it. -/
def counting : BaseIO Activity := do
  let state ← IO.mkRef ({} : Activity.State)
  return {
      begin := do
        let waiter ←
          state.modifyGet fun held =>
              (held.waiter,
                { held with
                  running := held.running + 1, epoch := held.epoch + 1, waiter := none })
        wake waiter
      done := do
        let waiter ←
          state.modifyGet fun held =>
              if held.running == 0 then (none, { held with refused := held.refused + 1 })
              else
                (held.waiter,
                  { held with
                    running := held.running - 1, epoch := held.epoch + 1, waiter := none })
        wake waiter
      seen := do
        let held ← state.get
        return { running := held.running, epoch := held.epoch }
      changedSince := fun epoch => do
        let fresh ← IO.Promise.new
        let armed ←
          state.modifyGet fun held =>
              if held.epoch != epoch then (none, held)
              else
                match held.waiter with
                | some waiter => (some waiter, held)
                | none => (some fresh, { held with waiter := some fresh })
        match armed with
        | none =>
          return Task.pure ()
        | some waiter =>
          return waiter.result?.map (sync := true) fun _ => ()
      refused := return (← state.get).refused }

/-- No count kept: `begin` and `done` do nothing, the count reads 1 and the
epoch 0, so it is never idle, and it says so (`tracked := false`): there is
no change to wait for, so `changedSince` ends at once, and a waiter looks
again at what it waits for in its own way (`Headless.Host.waitWhile`). What
a host that does not track its idle carries, the window mode's. -/
def untracked : Activity where
  begin := pure ()
  done := pure ()
  seen := pure { running := 1, epoch := 0 }
  changedSince _ := pure (Task.pure ())
  tracked := false

end Activity

end Editor.Job
