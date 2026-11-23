/-!
# Typed time bounds

A time bound is a value that says which kind it is (`AGENTS.md`,
"Deterministic concurrency in tests"; `docs/design/concurrency.md`, "What a
test may still wait on time for"):

- **`HangGuard.on <event> <ms>`**: a guard against a hang, naming the event
  its wait ends on. Running out is a hang, reported as one, never a result.
- **`HangGuard.held <what> <ms>`**: a hang guard run out on purpose, naming
  what is held for good. Running out is the expected outcome.
- **`RealTime.under <timing> <ms>`**: real time under test, naming the
  timing that is the subject.

Their constructors are this module's and neither has an `OfNat` instance,
so a number of milliseconds, an anonymous constructor or a structure
instance does not elaborate as either outside this module: a wait whose
bound is a `HangGuard` takes nothing else, and the kind of a bound is a
type, not a comment.

The module owns the clock reads a bound needs: the guard's expiry (`expiry`,
which `within` races against a task), a deadline and what is left of it
(`deadline`, `Deadline.expired`, `Deadline.rest`), and real time's sleep
(`RealTime.sleep`). It is the one module the raw-clock linter
(`linter.rawClock`, `Editor/Lint/Wait.lean`) lets read the clock.

Its checks are `ModelTest.boundChecks` (`ModelTest/Editor/Bound.lean`).
-/

namespace Editor

/-- A bound on a wait that is a guard against a hang. Built by `on` or
`held`; nothing else makes one. -/
structure HangGuard where private mk ::
  /-- The event the wait ends on, or what is held for good. -/
  what : String
  /-- How long the wait may last, in milliseconds. -/
  ms : Nat
  /-- Whether running out is the expected outcome: what the wait is on is
  held for good (`held`). -/
  heldForGood : Bool
  deriving DecidableEq, Repr

/-- A hang guard on a wait that ends on `event`, of `ms` milliseconds. -/
def HangGuard.on (event : String) (ms : Nat) : HangGuard :=
  ⟨event, ms, false⟩

/-- A hang guard run out on purpose: `what` is held for good, and the wait
on it runs out after `ms` milliseconds. -/
def HangGuard.held (what : String) (ms : Nat) : HangGuard :=
  ⟨what, ms, true⟩

/-- What running out of `guard` means, for a message: a hang, naming the
event and the bound, or, for a guard held for good, that it ran out as
meant. -/
def HangGuard.hang (guard : HangGuard) : String :=
  if guard.heldForGood then
    s!"run out on purpose: {guard.what} is held for good, after {guard.ms} ms"
  else s!"a hang: {guard.what} had not come within {guard.ms} ms"

/-- The same guard with another bound: for a bound computed from another
(scaled, or what is left of it), which still names its event. -/
def HangGuard.withMs (guard : HangGuard) (ms : Nat) : HangGuard :=
  { guard with ms }

/-- A task that ends once `guard`'s bound has passed, or at its next step
once cancelled (`IO.cancel`). It reads the clock in steps of 10 ms on a
dedicated thread, so a cancelled one does not hold the process open for the
rest of the bound. -/
def HangGuard.expiry (guard : HangGuard) : BaseIO (Task Unit) :=
  BaseIO.asTask (prio := .dedicated) do
    let deadline := (← IO.monoMsNow) + guard.ms
    while (← IO.monoMsNow) < deadline && !(← IO.checkCanceled) do
      IO.sleep 10

/-- `task`'s value, or `none` if it has not ended within `guard`. It is a
guard against a hang, never a result: a caller that gets `none` reports a
hang (`hang`), or, for a guard held for good, goes on as meant. A task that
has ended is its value at once, with no clock read. -/
def HangGuard.within {α : Type} (guard : HangGuard) (task : Task α) : BaseIO (Option α) := do
  if ← IO.hasFinished task then
    return some task.get
  let expiry ← guard.expiry
  let first ← IO.waitAny [task.map (sync := true) some, expiry.map (sync := true) fun _ => none]
  IO.cancel expiry
  return first

/-- A hang guard's deadline: when its bound runs out, on the monotonic
clock. -/
structure HangGuard.Deadline where private mk ::
  /-- The guard it is the deadline of. -/
  guard : HangGuard
  /-- When it runs out, in milliseconds of the monotonic clock. -/
  ends : Nat

/-- `guard`'s deadline, from now. -/
def HangGuard.deadline (guard : HangGuard) : BaseIO HangGuard.Deadline :=
  return ⟨guard, (← IO.monoMsNow) + guard.ms⟩

/-- Whether `deadline` has passed. -/
def HangGuard.Deadline.expired (deadline : HangGuard.Deadline) : BaseIO Bool :=
  return (← IO.monoMsNow) >= deadline.ends

/-- What is left of `deadline`, as a guard on the same event: 0 ms once it
has passed. -/
def HangGuard.Deadline.rest (deadline : HangGuard.Deadline) : BaseIO HangGuard :=
  return deadline.guard.withMs (deadline.ends - (← IO.monoMsNow))

/-- A span of real time that is itself under test. Built by `under`;
nothing else makes one. -/
structure RealTime where private mk ::
  /-- The timing that is the subject. -/
  timing : String
  /-- How long, in milliseconds. -/
  ms : Nat
  deriving DecidableEq, Repr

/-- Real time under test: `ms` milliseconds of `timing`, the timing that is
the subject. -/
def RealTime.under (timing : String) (ms : Nat) : RealTime :=
  ⟨timing, ms⟩

/-- Sleeps for `span`: the one sleep of the core and its tests. -/
def RealTime.sleep (span : RealTime) : BaseIO Unit :=
  IO.sleep span.ms.toUInt32

end Editor
