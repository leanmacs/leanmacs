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

## A wait over the fakes

A driver whose collaborators are the fakes it steps (the job services'
fakes, the journal's and the syntax service's) hands the bracket their
work (`Stepped.Work`, `withStepped`'s `work`), and its waits are then
judged at the rest of the fakes, never by the activity count:

- each time round, the queue's next push is armed and the first round
  posts the kind's marker, as above;
- the loop is brought to rest (`toRest`): rounds of the queue drained
  through the turn and then every piece of the fakes' work run, until a
  round moves nothing;
- the rest is judged by `Rest.judge` (`Editor/Headless/Wait.lean`): an
  answer, or, while a reload is in flight, a block on the queue's next
  push, the reload's own wake-up (its elaboration is the one thing left on
  another thread), with the hang at the guard.

Over the fakes every job's code, completion, delivery and journal order
runs on a step on the caller's thread, and the fake clock moves only on an
`advance`, so a `join` whose job sleeps on the clock answers `working` at
once, and an `advance` with nothing due stalls at once. A `restarted`'s
wait (`awaitEnd`) is the loop brought to rest: ended, or `none` at once. A
turn that ends the loop for a restart publishes the plan in `progress`
(`Progress.handOver`), as the real loop does.

## The runner over it

`Stepped.hosting` is the script runner's bracket over a stepped host
(`Hosting`, `runOn`), and `Stepped.run` and `Stepped.runFrom` are the
runner over it: a script's directives answered by the stepped host's turn
and, over the fakes, by their steps. A stepped run's `abort` throws
(`Stepped.refuseAbort`) unless its caller hands another: a harness cannot
end its process.
-/

namespace Editor.Headless

/-- The fakes a stepped host's collaborators run their work on, as its
waits step them (the module docs, "A wait over the fakes"): one piece of
their work on the caller's thread, `false` when none can run. A driver
whose collaborators are the fakes hands it to the bracket (`withStepped`);
one whose jobs run on Lean's pool hands none. -/
structure Stepped.Work where
  /-- Runs one piece of the fakes' work: `false` when none can run. -/
  step : IO Bool

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
  /-- The fakes' work its waits step, when its collaborators are the fakes;
  none when its jobs run on Lean's pool. -/
  work : Option Stepped.Work

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

/-- Brings the loop to the rest of its fakes: in rounds, the queue drained
through the turn, then every piece of `work` that can run run, until a
round moves nothing (no event taken, no piece run), or the loop has
ended. -/
partial def toRest (stepped : Stepped) (work : Stepped.Work) : IO Unit := do
  let queued ← stepped.memory.size
  stepped.drain
  if (← stepped.ending.get).isSome then
    return
  let mut moved := decide (queued > 0)
  while ← work.step do
    moved := true
  if moved then
    stepped.toRest work

/-- A wait over the fakes (the module docs, "A wait over the fakes"): each
time round, the queue's next push is armed, the first round posts the
kind's marker, and the loop is brought to the rest of its fakes
(`toRest`); the rest is judged (`Rest.judge`), which reads no activity
count: an answer, the hang at the guard, said once, or a block on the
queue's next push while a reload is in flight, its wake-up. -/
private def restingWait (stepped : Stepped) (work : Stepped.Work) (waitGuard : HangGuard)
    (kind : Wait.Kind) (line : Option Nat) (waitHung : String → IO Unit)
    (waitBlocked : String → IO Unit) : IO Wait := do
  let deadline ← waitGuard.deadline
  let mut first := kind.marker
  repeat
    -- Armed before the rest: the reload's wake-up, pushed after the last
    -- drain found the queue empty, ends the block below.
    let arrived ← stepped.memory.arrived
    if first then
      stepped.post .marker
    first := false
    stepped.toRest work
    if (← stepped.ending.get).isSome then
      return .ended
    let progress ← stepped.progress
    let rest : Rest :=
      { busy := ← kind.busy progress, offThread := progress.reloading
        remaining := (← deadline.rest).ms, still := kind.still, hung := kind.hung }
    match rest.judge with
    | .answer wait =>
      return wait
    | .hang wait =>
      waitHung (waitHangLine kind.what line waitGuard)
      return wait
    | .blockOnReload =>
      waitBlocked "running work"
      discard <| awaitAnyWithin (← deadline.rest) [arrived]
  return .ended

/-- `Host.waitWhile` over the stepped loop (the module docs): over the
fakes, a wait judged at their rest (`restingWait`); otherwise a round drains
the queue, and is judged as the real host's is (`Wait.Kind.judge`). -/
def waitWhile (stepped : Stepped) (waitGuard : HangGuard) (kind : Wait.Kind)
    (_answer : HangGuard := waitGuard) (line : Option Nat := none)
    (waitHung : String → IO Unit := IO.eprintln)
    (waitBlocked : String → IO Unit := fun _ => pure ()) : IO Wait := do
  if (← stepped.ending.get).isSome then
    return .ended
  if let some work := stepped.work then
    return ← stepped.restingWait work waitGuard kind line waitHung waitBlocked
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

/-- A `restarted`'s wait over the stepped loop: drains the queue until a
turn has ended the loop, and says how it ended. Over the fakes, the loop is
brought to their rest (`toRest`), and at rest with no end it is `none` at
once, with no hang said: nothing left can end it. Otherwise, at `guard`,
with the loop not ended, the hang said through `hang`, and `none`; each
block is on the queue's next push, armed before the drain. -/
def Stepped.awaitEnd (stepped : Stepped) (guard : HangGuard) (hang : IO Unit) :
    IO (Option (Except IO.Error Unit)) := do
  -- Over the fakes, the loop brought to their rest: a turn that ended it
  -- did so on the way, and at rest with no end nothing left can end it.
  if let some work := stepped.work then
    if let some ended← stepped.ending.get then
      return some ended
    stepped.toRest work
    return ← stepped.ending.get
  let deadline ← guard.deadline
  repeat
    if let some ended← stepped.ending.get then
      return some ended
    let arrived ← stepped.memory.arrived
    stepped.drain
    if let some ended← stepped.ending.get then
      return some ended
    unless ← awaitAnyWithin (← deadline.rest) [arrived] do
      hang
      return none
  return none

/-- A stepped host, driven (`Driven`, the runner's port): its requests and
the window's events onto its memory queue (`Stepped.send`,
`Stepped.input`), its waits (`Stepped.waitWhile`), and its loop's end
(`Stepped.awaitEnd`). -/
def Driven.ofStepped (stepped : Stepped) : Driven :=
  .over stepped.send stepped.input
    (fun guard kind answer line waitHung waitBlocked =>
      stepped.waitWhile guard kind answer line waitHung waitBlocked)
    stepped.progress stepped.ended? stepped.clock stepped.awaitEnd

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
    (abandoned : Task (Except IO.Error Unit) → IO Unit := fun _ => pure ())
    (work : Option Stepped.Work := none) : IO α := do
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
          -- A loop that ended for a restart tells its driver the plan, as
          -- the real loop does (`loop`).
          if let some plan := running.handOver then
            progress.modify fun progress => { progress with handOver := some plan }
          ending.set (some (.ok ()))
        else
          progress.set running.progress
      catch error =>
        ending.set (some (.error error))
  let stepped : Stepped :=
    { requests := collaborators.requests, memory, drain, progress := progress.get, ending
      activity := collaborators.services.activity, clock := collaborators.clock, work }
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

/-- A stepped host's bracket for the script runner (`Hosting`, `runOn`): a
host over the collaborators stepped on the caller's thread over `memory`
(`withStepped`), driven by `Driven.ofStepped`, whose waits step `work`, the
fakes', when it is given. `guard`, `hung`, `grace` and `abandoned` bound the
end's wait for a reload still running, as `withStepped`'s do: past `grace`
it throws the hang. A loop's error is thrown by the bracket itself. -/
def Stepped.hosting {β σ : Type} {scheme : InputScheme} (memory : Queue.Memory Ffi.Event)
    (work : Option Stepped.Work) (guard : HangGuard := settlePatience)
    (grace : Option HangGuard := none) (hung : String → IO Unit := IO.eprintln)
    (abandoned : Task (Except IO.Error Unit) → IO Unit := fun _ => pure ()) : Hosting β σ scheme
    where
  hosted collaborators body := do
    let ran ←
      withStepped collaborators memory (fun stepped => body (Driven.ofStepped stepped)) guard hung
          grace abandoned work
    return .ok (ran, .ok ())

/-- What a stepped run's `abort` does by default: it throws, since a
stepped run cannot end its driver's process. -/
def Stepped.refuseAbort : IO Unit :=
  throw (IO.userError "abort: a stepped run cannot end the process it runs in")

/-- `runFrom` over a host stepped on the caller's thread (`Stepped.hosting`,
over `memory` and the fakes' `work`), with the same patiences, guards and
hooks; `abort` calls `onAbort`, which throws unless the caller hands
another. -/
def Stepped.runFrom {β σ : Type} {scheme : InputScheme} (collaborators : Collaborators β σ scheme)
    (memory : Queue.Memory Ffi.Event) (work : Option Stepped.Work) (script : Array Line)
    (waitGuard : HangGuard) (resume : Nat := 0) (answer : HangGuard := waitGuard)
    (guard : HangGuard := answer) (grace : Option HangGuard := none)
    (hung : String → IO Unit := IO.eprintln)
    (abandoned : Task (Except IO.Error Unit) → IO Unit := fun _ => pure ())
    (waitHung : String → IO Unit := IO.eprintln)
    (waitBlocked : String → IO Unit := fun _ => pure ())
    (onAbort : IO Unit := Stepped.refuseAbort) : IO Ran :=
  runOn (Stepped.hosting memory work guard grace hung abandoned) collaborators script waitGuard
    resume answer waitHung waitBlocked onAbort

/-- `run` over a host stepped on the caller's thread: `Stepped.runFrom`
from the script's start, saying only why it could not run to its end. -/
def Stepped.run {β σ : Type} {scheme : InputScheme} (collaborators : Collaborators β σ scheme)
    (memory : Queue.Memory Ffi.Event) (work : Option Stepped.Work) (script : Array Line)
    (waitGuard : HangGuard) (answer : HangGuard := waitGuard) (guard : HangGuard := answer)
    (grace : Option HangGuard := none) (hung : String → IO Unit := IO.eprintln)
    (abandoned : Task (Except IO.Error Unit) → IO Unit := fun _ => pure ())
    (waitHung : String → IO Unit := IO.eprintln)
    (waitBlocked : String → IO Unit := fun _ => pure ())
    (onAbort : IO Unit := Stepped.refuseAbort) : IO (Option Failure) :=
  (·.1) <$>
    Stepped.runFrom collaborators memory work script waitGuard 0 answer guard grace hung abandoned
      waitHung waitBlocked onAbort

end Editor.Headless
