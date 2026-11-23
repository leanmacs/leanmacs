import Editor.Headless
import Editor.InferredWait

/-!
# A host stepped on its caller's thread

The headless host's loop (`Editor/Headless.lean`, "The loop") run on the
thread of whoever drives it, for a test: the same turn of the loop
(`Running.turn`) over an in-memory editor queue (`Queue.Memory`), with no
loop thread and no pull of the library's queue. Everything else of the host
is what its collaborators make it: the elaborator, the reload job's task,
the jobs on the pool, the clock, the display and the text binding. Only the
transport and the thread change, so a check stepped here runs the host's own
logic, and a mutation of it kills the check as it would on a real loop.

`withStepped` is the bracket, as `withHost` is a real host's:

- It installs the queue itself: the collaborators it steps post to the
  memory queue it is handed (`Queue.Memory.queue Posted.toFfi`), whatever
  queue the collaborators carried, so a stepped host's posts and its drain
  are one queue.
- On entry it prepares the collaborators as a real host's start does
  (`Collaborators.prepared`) and makes the loop's state (`Running.new`), on
  the caller's thread. It tells the library no interrupt key, since no key
  comes from the library, and never calls `Collaborators.loopStarted`.
- Whether the body returned or threw, it closes the queue, so a late post is
  refused and gives its unit back, and ends the loop (`Running.wind`): every
  job cancelled, every pause and hint delay withdrawn, and the reload job,
  if one is running, waited for after `Collaborators.endWaits "reload"`. An
  end not over `guard` milliseconds after it began says the hang once, and
  with `grace` gives up as a hang after that many more, handing the
  reload's task to `abandoned`, as `withHost` does. The body's error is the one thrown; when it returned, an error a turn
  threw is.

`Stepped.waitWhile` is `Host.waitWhile` over the stepped loop, with the same
signature and outcomes (`Wait`), and the same kinds of wait (`Wait.Kind`),
so a `settle`, a `join` and an `advance` mean the same. Only the transport
differs. A round takes the queue's next-push task (`arrived`) and the
activity count's reading, then drains the queue, each event through the
turn (the first round's marker among them, so a settle publishes the scene
a real host's does, and a later round posts nothing, so publishes none).
The round is then judged by the one verdict both drivers' waits take
(`Wait.Kind.judge`, `Round.judge`, `Editor/Headless/Wait.lean`); a block,
after `waitBlocked "running work"`, is on the first of the next push and
the count's next change. The next push is armed before the drain: an event
posted after the drain found the queue empty, with the count unchanged, is
the one a lost wake-up would miss, and it ends the block. At its guard the
wait says the hang once through `waitHung` and answers the hang outcome. A
loop that a turn stopped, or that threw, is answered `ended`.
-/

namespace Editor.Headless

/-- A host stepped on its caller's thread, as its driver holds it. Only its
bracket makes one (`withStepped`): its constructor is private. -/
structure Stepped where private mk ::
  /-- The Lean source id the driver's events are posted under. -/
  requests : UInt64
  /-- The queue the host's posters post to, and the driver drains. -/
  memory : Queue.Memory Ffi.Event
  /-- Takes every event the queue holds, each through the loop's turn, until
  the queue is empty or the loop has ended. -/
  drain : IO Unit
  /-- How far the loop has got, as it stood after the last turn. -/
  progress : IO Progress
  /-- How the loop ended, once it has: a turn that stopped it, or the error
  a turn threw. -/
  ending : IO.Ref (Option (Except IO.Error Unit))
  /-- The host's activity count, its idle signal. -/
  activity : Job.Activity
  /-- The fake clock the host's jobs wait on, if they wait on one. -/
  clock : Option Job.FakeClock

namespace Stepped

/-- `activitySeen` is an inferred wait (`Editor/InferredWait.lean`). -/
def activitySeen.inferredWait : InferredWait :=
  .count []

/-- The host's activity count and its epoch, read in one step. -/
def activitySeen (stepped : Stepped) : BaseIO Job.Activity.Seen :=
  stepped.activity.seen

/-- How the loop ended, if it has. -/
def ended? (stepped : Stepped) : BaseIO (Option (Except IO.Error Unit)) :=
  stepped.ending.get

/-- The queue port the host's posters post to. -/
def queue (stepped : Stepped) : Queue :=
  stepped.memory.queue Posted.toFfi

/-- Enqueues `event`. Throws if the queue refuses it, which it does once the
bracket has closed it. -/
def enqueue (stepped : Stepped) (event : Ffi.Event) : IO Unit := do
  unless ← stepped.memory.push event do
    throw (IO.userError "the editor queue refused an event: it has been closed")

/-- Enqueues `signal` as `Host.post` posts it. -/
def post (stepped : Stepped) (signal : Signal) : IO Unit :=
  let (code, text) := signal.encode
  stepped.enqueue (Posted.toFfi { source := stepped.requests, code, text })

/-- Asks the loop to do `request`, after everything asked before: the event
`Host.send` posts. Handled at the next wait. -/
def send (stepped : Stepped) (request : Request) : IO Unit :=
  stepped.post (.request request)

/-- Enqueues `event` as the library delivers a window's report of it
(`Event.toFfi`). Throws for an event no window reports. -/
def input (stepped : Stepped) (event : Event) : IO Unit := do
  let some delivered := Event.toFfi event
    | throw (IO.userError "no window reports that event")
  stepped.enqueue delivered

/-- `Host.waitWhile` over the stepped loop (the module docs): a round drains
the queue, and is judged as the real host's is (`Wait.Kind.judge`). -/
def waitWhile (stepped : Stepped) (waitGuard : HangGuard) (kind : Wait.Kind)
    (_answer : HangGuard := waitGuard) (line : Option Nat := none)
    (waitHung : String → IO Unit := IO.eprintln)
    (waitBlocked : String → IO Unit := fun _ => pure ()) : IO Wait := do
  if (← stepped.ending.get).isSome then
    return .ended
  let deadline ← waitGuard.deadline
  let mut first := kind.marker
  repeat
    -- The next push's task is armed before the drain: an event posted after
    -- the drain found the queue empty ends it, so the block below sees it.
    let arrived ← stepped.memory.arrived
    let before ← stepped.activity.seen
    if first then
      stepped.post .marker
    first := false
    stepped.drain
    if (← stepped.ending.get).isSome then
      return .ended
    match
      ←
        kind.judge (← stepped.progress) stepped.activity stepped.clock before deadline waitGuard
            line waitHung with
    | .answer wait | .hang wait =>
      return wait
    | .again =>
      continue
    | .block since =>
      waitBlocked "running work"
      discard <| awaitAnyWithin (← deadline.rest) [arrived, ← stepped.activity.changedSince since]
  return .ended

/-- `Host.await` over the stepped loop: a `settle`'s wait (`Wait.Kind.settle`). -/
def await (stepped : Stepped) (waitGuard : HangGuard) (answer : HangGuard := waitGuard)
    (line : Option Nat := none) (waitHung : String → IO Unit := IO.eprintln)
    (waitBlocked : String → IO Unit := fun _ => pure ()) : IO Wait :=
  stepped.waitWhile waitGuard .settle answer line waitHung waitBlocked

/-- `join` is an inferred wait (`Editor/InferredWait.lean`). -/
def join.inferredWait : InferredWait :=
  .idle [`Editor.Headless.Wait, `Editor.Test.Linked.Host]

/-- `Host.join` over the stepped loop: a `join`'s wait (`Wait.Kind.join`). -/
def join (stepped : Stepped) (waitGuard : HangGuard) (answer : HangGuard := waitGuard)
    (line : Option Nat := none) (waitHung : String → IO Unit := IO.eprintln)
    (waitBlocked : String → IO Unit := fun _ => pure ()) : IO Wait :=
  stepped.waitWhile waitGuard .join answer line waitHung waitBlocked

/-- Whether the loop has ended, stopped by a turn or by the error one
threw. -/
def hasEnded (stepped : Stepped) : BaseIO Bool :=
  return (← stepped.ending.get).isSome

end Stepped

/-- Runs `body` against a host over `collaborators` stepped on the caller's
thread, and returns only once its loop has ended, whether `body` returned or
threw (the module docs). The collaborators' queue is replaced with
`memory`'s port, whatever it was, and `memory` is closed at the end: a
caller hands a fresh one, and may build a poster over it before the bracket
(an environments' report, `reportedEnvironments`). The end's wait for a reload still running is
guarded by `guard`: past it the hang is said once through `hung`, and with
`grace` the bracket gives up as a hang once `grace` has run out, the
reload left running and its task handed to `abandoned`, so a check can let
it go and wait for it, as `withHost` does. When `body` threw, its error is the
one thrown; when it returned and a turn threw, that error is. -/
def withStepped {α β σ : Type} {scheme : InputScheme} (collaborators : Collaborators β σ scheme)
    (memory : Queue.Memory Ffi.Event) (body : Stepped → IO α) (guard : HangGuard := settlePatience)
    (hung : String → IO Unit := IO.eprintln) (grace : Option HangGuard := none)
    (abandoned : Task (Except IO.Error Unit) → IO Unit := fun _ => pure ()) : IO α := do
  let collaborators ← ({ collaborators with queue := memory.queue Posted.toFfi }).prepared
  let ending ← IO.mkRef none
  let progress ← IO.mkRef ({} : Progress)
  let state ← IO.mkRef (none : Option (Running β σ scheme))
  try
    state.set (some (← Running.new collaborators))
  catch error =>
    ending.set (some (.error error))
  let drain : IO Unit := do
    repeat
      if (← ending.get).isSome then
        break
      let some running ← state.get | break
      let some event ← memory.take? | break
      try
        let running ← running.turn collaborators event
        state.set (some running)
        if running.stopped then
          ending.set (some (.ok ()))
        else
          progress.set running.progress
      catch error =>
        ending.set (some (.error error))
  let stepped : Stepped :=
    { requests := collaborators.requests, memory, drain, progress := progress.get, ending
      activity := collaborators.services.activity, clock := collaborators.clock }
  -- The end: the queue closed first, so the reload's late wake-up is
  -- refused and gives its unit back; then the loop's end, its wait for the
  -- reload guarded; and the loop's state dropped, so nothing of it is kept.
  let finish : IO Unit := do
    memory.close
    if let some running← state.get then
      running.wind collaborators fun task => do
          if (← Job.awaitWithin guard task).isSome then
            return
          hung (hangLine guard.ms)
          match grace with
          | some grace =>
            if (← Job.awaitWithin grace task).isNone then
              abandoned task
              throw <|
                  IO.userError
                    s!"a hang: the stepped host's end had not ended {grace.ms} ms after the hang was said ({guard.ms} ms after it began); giving up"
          | none =>
            discard <| IO.wait task
    state.set none
  let result ←
    try
      body stepped
    catch error =>
      try
        finish
      catch _ =>
        pure ()
      throw error
  finish
  if let some (.error error)← ending.get then
    throw error
  return result

end Editor.Headless
