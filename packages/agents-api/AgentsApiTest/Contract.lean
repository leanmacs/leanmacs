import AgentsApi
import AgentsApiTest.Protocol
import Editor.Bound
import Editor.Job.Runner

/-!
# The contract of the service `agents`

What every implementation of the service (`AgentsApi/Request.lean`) does, as
one list of properties over the port the runner reaches it through
(`Editor.PackageService`), run against the fake (`AgentsApiTest/Fake.lean`)
by the package's test driver and against `acp`'s crate, on a real scripted
agent, by `acp`'s linked test. That keeps the fake and the crate from
drifting apart.

Every property plays the canonical scenario, or a part of it, against the
rig's canonical agent: the fake's script (`AgentsApiTest.Fake.canonical`) or
`acp`'s scripted agent executable, which play the same exchange.

- `open` answers the session `sess-0001` in the mode `mode-ask`, of the two
  modes `mode-ask` and `mode-auto`.
- The prompt `ask` gives a chunk, the tool call `call-edit-1` and the
  permission request of ticket 1 for it.
- The answer `allow` to ticket 1 gives the call completed, and the
  permission request of ticket 2 for the call `call-edit-2`, while turn 1
  is still open.
- A cancel then withdraws ticket 2, the turn ends `cancelled`, and the
  agent exits 0.
- `load` of `sess-0001` answers that session, in the mode `mode-ask` of the
  same two modes, and its first events replay the agent's history
  (`history`): the user's chunk `ask`, the reply chunk, the call
  `call-edit-1` completed and the title `Example title`. A load of any other
  session is refused.

A property waits on each completion itself, within the rig's patience, a
hang guard: a wait that runs out fails the property as a hang. Each records
what it observed as a trace of the protocol's model (`traced`), which must
replay with no violation (`Protocol.replay`).
-/

namespace AgentsApiTest.Contract

open AgentsApi
open Editor (PackageError PackageReply PackageService HangGuard)

/-- The canonical agent's session id. -/
def sessionId : String :=
  "sess-0001"

/-- The canonical agent's modes. -/
def modes : Array Mode :=
  #[{ id := "mode-ask", name := "Ask" }, { id := "mode-auto", name := "Auto" }]

/-- The canonical agent's mode when the session opens. -/
def mode : String :=
  "mode-ask"

/-- The working directory a property opens its session in. -/
def cwd : String :=
  "/work/example"

/-- The prompt the canonical agent answers. -/
def promptText : String :=
  "ask"

/-- The option a property answers the first permission request with. -/
def allow : String :=
  "allow"

/-- The canonical agent's reply chunk. -/
def chunk : Event :=
  .chunk (some "msg-1") "I will edit notes.txt."

/-- The canonical tool call, as the agent first sends it. -/
def call : ToolCall :=
  { id := "call-edit-1", title := "Edit notes.txt", kind := "edit", status := "pending"
    locations := #[("/work/example/notes.txt", none)]
    rawInput := "{\"path\":\"/work/example/notes.txt\"}" }

/-- The options of each canonical permission request. -/
def options : Array PermissionOption :=
  #[{ id := "allow", name := "Allow", kind := "allow_once" },
    { id := "reject", name := "Reject", kind := "reject_once" }]

/-- The canonical call, once the agent has completed it. -/
def completed : ToolCall :=
  { call with
    status := "completed", content := #[.text "Edited."] }

/-- The call of the second permission request, which the agent asks about
with no tool call before. -/
def second : ToolCall :=
  { id := "call-edit-2", title := "Edit notes.txt again", kind := "edit" }

/-- What the prompt gives: a chunk, the call, and the permission request of
ticket 1 in turn 1. -/
def asked : Array Event :=
  #[chunk, .toolCall call, .permission 1 (some 1) call options]

/-- What the answer to ticket 1 gives: the call completed, and the
permission request of ticket 2 in turn 1. -/
def answered : Array Event :=
  #[.toolCall completed, .permission 2 (some 1) second options]

/-- What the cancel gives: ticket 2 withdrawn, the turn's end, and the
agent's exit. -/
def cancelled : Array Event :=
  #[.withdrawn 2, .turnEnded 1 "cancelled", .ended (.exited 0)]

/-- A session the canonical agent holds no history of. -/
def unknownSessionId : String :=
  "sess-0404"

/-- The canonical agent's title of its session. -/
def title : String :=
  "Example title"

/-- What a load of `sessionId` replays first: the user's prompt as a chunk,
the reply chunk, the call completed whole and the session's title. -/
def history : Array Event :=
  #[.userChunk (some "msg-u1") promptText, chunk, .toolCall completed, .title title]

/-- What a property runs on: the service, the table it completes through,
how long a property waits for one completion, and the canonical agent. -/
structure Rig where
  /-- The rig's name, for a failure. -/
  name : String
  /-- The service, as the runner reaches it. -/
  service : PackageService
  /-- The table of waits its completions end. -/
  completions : Editor.Job.Completions
  /-- How long a property waits for one completion: a hang guard. -/
  patience : HangGuard
  /-- Starts the canonical agent, and gives the number of its streaming child
  for `open` to hand over: any number for a fake that opens none. -/
  opened : IO Nat
  /-- Ends the child `opened` gave, at a property's end, whatever state the
  session is in. -/
  release : Nat → IO Unit

/-- One property of the service. -/
structure Property where
  /-- What must hold, as a sentence; printed when it does not. -/
  name : String
  /-- Observes the property; `true` when it holds. -/
  holds : Rig → IO Bool

/-- A session a property drives: its rig, its child, the service's number for
it, and what it observed. -/
structure Driven where
  /-- The rig. -/
  rig : Rig
  /-- The agent's child. -/
  child : Nat
  /-- What `open` answered. -/
  opened : Opened
  /-- The trace of the protocol's model it observed, oldest first. -/
  trace : IO.Ref (Array Protocol.Action)
  /-- The tickets it saw asked. -/
  asked : IO.Ref (Array Nat)

/-- Starts `request` at the rig's service as a wait of the rig's table, waits
for its completion within the rig's patience, and takes its reply: a refusal
when the service did not take it; a hang thrown when it did not complete. -/
def ask (rig : Rig) (request : Request) : IO PackageReply := do
  let (id, wait) ← rig.completions.register
  let request := request.toPackage
  unless ← rig.service.start id request do
    rig.completions.finish id .cancelled
    return .error (.refused s!"{rig.name} did not take {request.operation}")
  -- Waited for on the wait itself; the rig's patience is a hang guard.
  match ← Editor.Job.awaitWithin rig.patience wait.result? with
  | some (some .completed) =>
    rig.service.take id request
  | _ =>
    throw (IO.userError s!"{rig.name}: {request.operation} did not complete: {rig.patience.hang}")

/-- `ask`, its reply read back as `α`. -/
def askAs (α : Type) [TypeName α] (rig : Rig) (request : Request) : IO (Except PackageError α) := do
  match ← ask rig request with
  | .ok reply =>
    match reply.get? α with
    | some value =>
      return .ok value
    | none =>
      return .error (.refused "a reply of another type")
  | .error refusal =>
    return .error refusal

/-- Records `action` in the trace. -/
def Driven.record (driven : Driven) (action : Protocol.Action) : IO Unit :=
  driven.trace.modify (·.push action)

/-- The trace's action for an observed event, recorded: a permission request
is an `ask`; a withdrawal of a ticket never seen asked is an `ask` the client
answered at once, and of one seen asked part of the cancel that withdrew it;
a turn's end is the response to its prompt; the session's end is the close. -/
def Driven.observe (driven : Driven) : Event → IO Unit
  | .permission ticket .. => do
    driven.asked.modify (·.push ticket)
    driven.record (.ask ticket)
  | .withdrawn ticket => do
    unless (← driven.asked.get).contains ticket do
      driven.asked.modify (·.push ticket)
      driven.record (.ask ticket)
  | .turnEnded turn _ => driven.record (.respond turn)
  | .ended _ => driven.record .close
  | _ => pure ()

/-- Opens a session of the rig's canonical agent, or says why it did not
open. -/
def openSession (rig : Rig) : IO (Except String Driven) := do
  let child ← rig.opened
  match ← askAs Opened rig (.open child cwd #[]) with
  | .ok opened =>
    return .ok { rig, child, opened, trace := ← IO.mkRef #[], asked := ← IO.mkRef #[] }
  | .error refusal =>
    rig.release child
    return .error s!"open was refused: {repr refusal}"

/-- Loads the session `id` of the rig's canonical agent: the driven session,
or the refusal, with the child released. -/
def loadSession (rig : Rig) (id : String) : IO (Except PackageError Driven) := do
  let child ← rig.opened
  match ← askAs Opened rig (.load child cwd #[] id) with
  | .ok opened =>
    return .ok { rig, child, opened, trace := ← IO.mkRef #[], asked := ← IO.mkRef #[] }
  | .error refusal =>
    rig.release child
    return .error refusal

/-- The session's next batch of events, each observed. -/
def Driven.next (driven : Driven) : IO (Except PackageError (Array Event)) := do
  match ← askAs Batch driven.rig (.next driven.opened.session) with
  | .ok batch =>
    for event in batch.events do
      driven.observe event
    return .ok batch.events
  | .error refusal =>
    return .error refusal

/-- The session's events through successive `next`s, until one of them is
`last`, which is the final one given; or the events so far and the refusal
that stopped them. -/
partial def Driven.until (driven : Driven) (last : Event → Bool) (seen : Array Event := #[]) :
    IO (Except (Array Event × PackageError) (Array Event)) := do
  match ← driven.next with
  | .error refusal =>
    return .error (seen, refusal)
  | .ok events =>
    let seen := seen ++ events
    if events.any last then
      return .ok seen
    else
      driven.until last seen

/-- The session's events through successive `next`s, until at least `count`
have come; or the events so far and the refusal that stopped them. -/
partial def Driven.taking (driven : Driven) (count : Nat) (seen : Array Event := #[]) :
    IO (Except (Array Event × PackageError) (Array Event)) := do
  if seen.size ≥ count then
    return .ok seen
  match ← driven.next with
  | .error refusal =>
    return .error (seen, refusal)
  | .ok events =>
    driven.taking count (seen ++ events)

/-- Sends the session `order`, recording what the protocol's model sees of
it once it is taken: a prompt's turn, an answer, a cancel. -/
def Driven.send (driven : Driven) (order : Order) : IO (Except PackageError Sent) := do
  let sent ← askAs Sent driven.rig (.send driven.opened.session order)
  if let .ok answer := sent then
    match order, answer.turn with
    | .prompt _, some turn =>
      driven.record (.send turn (some turn))
    | .answer ticket _, _ =>
      driven.record (.answer ticket)
    | .cancel, _ =>
      driven.record .cancel
    | _, _ =>
      pure ()
  return sent

/-- Whether the trace the session observed replays on the protocol's model
with no violation. -/
def Driven.replays (driven : Driven) : IO Bool := do
  return (Protocol.replay (← driven.trace.get).toList).toOption.isSome

/-- Runs `body` on a session of the rig's canonical agent, and releases its
child afterwards, whether `body` returned or threw. -/
def withSession (rig : Rig) (body : Driven → IO Bool) : IO Bool := do
  match ← openSession rig with
  | .error reason =>
    throw (IO.userError reason)
  | .ok driven =>
    try
      body driven
    finally
      rig.release driven.child

/-- Prompts `ask` and reads the events up to the first permission request:
whether they are `asked`. -/
def prompted (driven : Driven) : IO Bool := do
  let sent ← driven.send (.prompt promptText)
  let events ← driven.until (· matches .permission ..)
  return sent.toOption == some { turn := some 1 } && events.toOption == some asked

/-- Answers ticket 1 `allow` and reads the events up to the next permission
request: whether they are `answered`. -/
def allowed (driven : Driven) : IO Bool := do
  let sent ← driven.send (.answer 1 allow)
  let events ← driven.until (· matches .permission ..)
  return sent.toOption == some {} && events.toOption == some answered

/-- Whether `reply` is a refusal. -/
def refused {α : Type} : Except PackageError α → Bool
  | .error (.refused _) => true
  | _ => false

/-- The properties every implementation of the service has. -/
def properties : List Property :=
  [{  name := "open answers a session with the agent's session id, its mode and its modes"
      holds := fun rig =>
        withSession rig fun driven =>
          return driven.opened.sessionId == sessionId && driven.opened.mode == some mode &&
              driven.opened.modes == modes },
    { name :=
        "a prompt's events arrive through successive nexts, and a permission request is answered while the prompt is pending: the agent's reaction, the call completed and a second request, arrives while the turn is still open"
      holds := fun rig =>
        withSession rig fun driven => do
          let held := (← prompted driven) && (← allowed driven)
          let trace ← driven.trace.get
          return held && !trace.any (· matches .respond _) },
    { name :=
        "a cancel with a permission request parked withdraws it before the turn ends cancelled, the session's end comes last, and no ticket of that turn is answerable afterwards"
      holds := fun rig =>
        withSession rig fun driven => do
          let played := (← prompted driven) && (← allowed driven)
          let sent ← driven.send .cancel
          let events ← driven.until (· matches .ended _)
          let late ← driven.send (.answer 2 allow)
          let after ← driven.next
          return played && sent.toOption == some {} && events.toOption == some cancelled && refused late &&
              refused after },
    { name := "an answer to a ticket never asked, and a second answer to a ticket, are refused"
      holds := fun rig =>
        withSession rig fun driven => do
          let played ← prompted driven
          let unknown ← driven.send (.answer 99 allow)
          let held ← allowed driven
          let again ← driven.send (.answer 1 allow)
          return played && refused unknown && held && refused again },
    { name :=
        "a withdrawn next is never completed: the events it would have had go to the next one, and once the service is flushed it is still pending"
      holds := fun rig =>
        withSession rig fun driven => do
          let (id, wait) ← rig.completions.register
          let request := (Request.next driven.opened.session).toPackage
          let started ← rig.service.start id request
          rig.service.cancel id
          let played ← prompted driven
          let (flush, flushed) ← rig.completions.register
          rig.service.flush flush
          -- Waited for on the flush itself; the rig's patience is a hang
          -- guard.
          let behind ← Editor.Job.awaitWithin rig.patience flushed.result?
          let pending := !(← wait.isResolved)
          rig.completions.finish id .cancelled
          return started && played && behind == some (some .completed) && pending },
    { name :=
        "the whole canonical scenario's trace, open, prompt, answer, cancel and the agent's exit, replays on the protocol's model with no violation, and leaves it closed with every ticket answered once"
      holds := fun rig =>
        withSession rig fun driven => do
          let played := (← prompted driven) && (← allowed driven)
          let cancel ← driven.send .cancel
          let ended ← driven.until (· matches .ended _)
          let trace ← driven.trace.get
          match Protocol.replay trace.toList with
          | .ok state =>
            return played && cancel.toOption.isSome && ended.toOption.isSome && state.closed &&
                state.answers == [1, 2] &&
                (← driven.replays)
          | .error _ =>
            return false },
    { name :=
        "a load answers the session asked for, with its mode and modes, its first events are the agent's history in order, and nothing is parked"
      holds := fun rig => do
        match ← loadSession rig sessionId with
        | .error refusal =>
          throw (IO.userError s!"load was refused: {repr refusal}")
        | .ok driven =>
          try
            let events ← driven.taking history.size
            let answer ← driven.send (.answer 1 allow)
            return driven.opened.sessionId == sessionId && driven.opened.mode == some mode &&
                driven.opened.modes == modes &&
                events.toOption == some history &&
                refused answer &&
                (← driven.trace.get).isEmpty
          finally
            rig.release driven.child },
    { name := "a load of a session the agent does not hold is refused"
      holds := fun rig => do
        match ← loadSession rig unknownSessionId with
        | .error (.refused _) =>
          return true
        | .error _ =>
          return false
        | .ok driven =>
          rig.release driven.child
          return false }]

/-- The names of the properties that do not hold of `rig`, each with the
rig's name; a property that throws, a hang among them, has failed. -/
def failures (rig : Rig) : IO (List String) :=
  properties.filterMapM fun property => do
    try
      return if ← property.holds rig then none else some s!"{rig.name}: {property.name}"
    catch error =>
      return some s!"{rig.name}: {property.name} ({error})"

end AgentsApiTest.Contract
