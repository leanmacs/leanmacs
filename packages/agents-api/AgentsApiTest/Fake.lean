import AgentsApiTest.Contract
import Editor.Job.Fake

/-!
# The fake of the service `agents`

A `PackageService` named `agents`, published for other packages' tests,
over a scripted agent in memory: so a check of a consumer runs sessions on
the runner with no crate and no child.

- **Its bookkeeping is the protocol's model.** Each session keeps a
  `Protocol.State`, and every order and every move of the script goes
  through `Protocol.State.step`, so the fake's rules on tickets, cancels
  and responses are the theorems' (`AgentsApiTest/Protocol/Theorems.lean`)
  by construction, and the contract holds it to them
  (`AgentsApiTest/Contract.lean`).
- **The script** says what the agent does in answer to each order
  (`Fake.Script`): `canonical`, the contract's scenario, which `acp`'s
  scripted agent executable plays too, and `answerEnds`, in which the answer
  to the first permission request gives the completed call and the turn's
  end.
- **A request completes** as the stage says (`FakeAnswer`): `open` and
  `send` at once; `next` at once when the session holds events, and
  otherwise once an order makes some, or never if it is withdrawn first.
  A second `next` of a session while one is pending is refused at its
  start. `flush` completes at once, never waiting for a pending `next`.
- **It records** every request with the session's model state it arrived
  in and the thread that handed it (`Fake.log`), and each session's trace of
  the model's actions (`Fake.trace`), and says when it holds no request
  (`Fake.quiescent`).

It is made once and given to the runner over a table of waits: as a
`PackageService` directly (`Fake.service`), or on a stepped stage as a
package's fake (`Fake.packageFake`, `Stage.stepped`). `Fake.Flaws` makes a
fake that breaks one rule, for the contract's own tests.
-/

namespace AgentsApiTest

open AgentsApi
open Editor (PackageError PackageReply PackageService HangGuard)

/-- What a scripted agent does, in answer to an order. -/
inductive Fake.Move where
  /-- Sends an event that needs no bookkeeping: a chunk, a tool call, usage,
  a title, a mode. -/
  | event (event : Event)
  /-- Asks permission for `call`, with `options`. -/
  | ask (call : ToolCall) (options : Array PermissionOption)
  /-- Answers the current turn's prompt, for `stopReason`. -/
  | endTurn (stopReason : String)
  /-- Exits with `code`. -/
  | exit (code : Int)
  deriving Repr, Inhabited

/-- A scripted agent. -/
structure Fake.Script where
  /-- The session id it gives. -/
  sessionId : String
  /-- The mode a session opens in. -/
  mode : Option String
  /-- The modes it offers. -/
  modes : Array Mode
  /-- What it does for a prompt of turn `turn` and text `text`. -/
  onPrompt : (turn : Nat) → (text : String) → List Fake.Move
  /-- What it does for the answer `optionId` to the ticket `ticket`. -/
  onAnswer : (ticket : Nat) → (optionId : String) → List Fake.Move
  /-- What it does once a cancel has withdrawn the turn's requests. -/
  onCancel : List Fake.Move

/-- The rules a flawed fake breaks, for the contract's own tests. The fake
keeps every rule with `Fake.Flaws.none`. -/
structure Fake.Flaws where
  /-- A cancel leaves the turn's permission requests parked, unanswered. -/
  keepsAfterCancel : Bool := false
  /-- A second answer to a ticket is taken. -/
  takesSecondAnswer : Bool := false
  /-- A withdrawn `next` is completed all the same, once events come. -/
  completesWithdrawn : Bool := false
  deriving Repr, Inhabited

/-- A fake that keeps every rule. -/
def Fake.Flaws.none : Fake.Flaws :=
  {}

/-- One session of the fake. -/
structure Fake.Session where
  /-- Its number, which `next` and `send` name. -/
  number : Nat
  /-- The protocol's model of it. -/
  protocol : Protocol.State := .init
  /-- Its events not yet taken by a `next`, oldest first. -/
  queue : Array Event := #[]
  /-- The wait of its pending `next`. -/
  waiting : Option UInt64 := none
  /-- Whether it has ended: its last event is queued. -/
  ended : Bool := false
  /-- The next ticket a permission request is parked under. -/
  ticket : Nat := 1
  /-- The next prompt's turn. -/
  turn : Nat := 1
  /-- The model's actions, oldest first. -/
  trace : Array Protocol.Action := #[]
  deriving Repr, Inhabited

/-- What the fake holds. -/
structure Fake.State where
  /-- Every session opened, oldest first. -/
  sessions : Array Fake.Session := #[]
  /-- The requests started and neither taken nor withdrawn, each with its
  wait's id and its reply, decided at its start; a `next`'s is made when it
  is taken. -/
  pending : Array (UInt64 × Request × PackageReply) := #[]
  /-- The waits withdrawn while a `next` of theirs was pending, which a flawed
  fake completes all the same. -/
  withdrawn : Array UInt64 := #[]
  /-- Every request the fake was handed, with its session's model state as it
  arrived and the thread that handed it, oldest first. -/
  log : Array (Request × Protocol.State × UInt64) := #[]
  deriving Inhabited

/-- The fake of the service `agents`. -/
structure Fake where
  /-- Its agent's script. -/
  script : Fake.Script
  /-- The rules it breaks. -/
  flaws : Fake.Flaws := .none
  /-- What it holds. Every change to it is one atomic step. -/
  state : IO.Ref Fake.State

namespace Fake

/-- The contract's scenario: the prompt gives a chunk, the call and a
permission request; the answer to its ticket gives the call completed and a
second permission request; a cancel ends the turn `cancelled`, and the agent
exits 0. -/
def canonical : Script where
  sessionId := Contract.sessionId
  mode := some Contract.mode
  modes := Contract.modes
  onPrompt _ _ :=
    [.event Contract.chunk, .event (.toolCall Contract.call), .ask Contract.call Contract.options]
  onAnswer ticket _ :=
    if ticket == 1 then
      [.event (.toolCall Contract.completed), .ask Contract.second Contract.options]
    else []
  onCancel := [.endTurn "cancelled", .exit 0]

/-- The canonical agent, but the answer to the first permission request gives
the call completed and the turn's end, `end_turn`. -/
def answerEnds : Script :=
  { canonical with
    onAnswer := fun ticket _ =>
      if ticket == 1 then [.event (.toolCall Contract.completed), .endTurn "end_turn"] else [] }

/-- A fake over `script`, breaking the rules `flaws` names. -/
def new (script : Script := canonical) (flaws : Flaws := .none) : BaseIO Fake :=
  return { script, flaws, state := ← IO.mkRef {} }

/-- `session` after the agent's `move`. -/
def Session.move (session : Session) : Move → Session
  | .event event => { session with queue := session.queue.push event }
  | .ask call options =>
    let ticket := session.ticket
    match session.protocol.step (.ask ticket) with
    | none => session
    | some protocol =>
      let event :=
        if protocol.answers.contains ticket then .withdrawn ticket
        else .permission ticket session.protocol.turn call options
      { session with
        protocol, ticket := ticket + 1, queue := session.queue.push event
        trace := session.trace.push (.ask ticket) }
  | .endTurn stopReason =>
    match session.protocol.turn with
    | none => session
    | some turn =>
      match session.protocol.step (.respond turn) with
      | none => session
      | some protocol =>
        { session with
          protocol, queue := session.queue.push (.turnEnded turn stopReason)
          trace := session.trace.push (.respond turn) }
  | .exit code =>
    match session.protocol.step .close with
    | none => session
    | some protocol =>
      { session with
        protocol, ended := true, queue := session.queue.push (.ended (.exited code))
        trace := session.trace.push .close }

/-- `session` after each of `moves`, in order. -/
def Session.moves (session : Session) (moves : List Move) : Session :=
  moves.foldl Session.move session

/-- The session `number`, if the fake opened it. -/
def State.session? (state : State) (number : Nat) : Option Session :=
  state.sessions.find? (·.number == number)

/-- `state` with the session `session` in place of the one of its number. -/
def State.put (state : State) (session : Session) : State :=
  { state with
    sessions :=
      state.sessions.map fun held => if held.number == session.number then session else held }

/-- A refusal of the service. -/
def refusal (reason : String) : PackageReply :=
  .error (.refused reason)

/-- What the fake does with the order `order` to `session`: the session after
it and the reply. -/
def order (fake : Fake) (session : Session) : Order → Session × PackageReply
  | .prompt text =>
    if session.ended then (session, refusal "the session has ended")
    else
      let turn := session.turn
      match session.protocol.step (.send turn (some turn)) with
      | none => (session, refusal "the prompt's request is outstanding")
      | some protocol =>
        let session :=
          { session with
            protocol, turn := turn + 1, trace := session.trace.push (.send turn (some turn)) }
        (session.moves (fake.script.onPrompt turn text), .ok (.mk ({ turn := some turn } : Sent)))
  | .answer ticket optionId =>
    match session.protocol.step (.answer ticket) with
    | some protocol =>
      let session :=
        { session with
          protocol, trace := session.trace.push (.answer ticket) }
      (session.moves (fake.script.onAnswer ticket optionId), .ok (.mk ({} : Sent)))
    | none =>
      if fake.flaws.takesSecondAnswer && session.protocol.asked.contains ticket then
        (session.moves (fake.script.onAnswer ticket optionId), .ok (.mk ({} : Sent)))
      else (session, refusal s!"the ticket {ticket} is not parked")
  | .cancel =>
    if fake.flaws.keepsAfterCancel then (session.moves fake.script.onCancel, .ok (.mk ({} : Sent)))
    else
      match session.protocol.step .cancel with
      | none => (session, refusal "the session has ended")
      | some protocol =>
        let withdrawn :=
          (session.protocol.parked.filter fun (ticket, _) =>
                !protocol.parked.any (·.1 == ticket)).map
            (·.1)
        let session :=
          { session with
            protocol, queue := session.queue ++ withdrawn.toArray.map Event.withdrawn
            trace := session.trace.push .cancel }
        (session.moves fake.script.onCancel, .ok (.mk ({} : Sent)))
  | .setMode _ => (session, .ok (.mk ({} : Sent)))

/-- The waits to complete once `session` changed: its pending `next`'s, when
it holds events or has ended, and every withdrawn one for a flawed fake. -/
def wake (fake : Fake) (state : State) (session : Session) : State × List UInt64 :=
  let ready := !session.queue.isEmpty || session.ended
  let (session, own) :=
    match session.waiting, ready with
    | some id, true => ({ session with waiting := none }, [id])
    | _, _ => (session, [])
  let stale := if fake.flaws.completesWithdrawn && ready then state.withdrawn.toList else []
  ({ (state.put session) with withdrawn := if stale.isEmpty then state.withdrawn else #[] },
    own ++ stale)

/-- Starts `request` as the wait `id`, over `completions`, answering as
`answer` says: whether it was taken, and the waits to complete. -/
def startIn (fake : Fake) (id : UInt64) (request : Request) (thread : UInt64) (state : State) :
    Bool × List UInt64 × State :=
  let arrived (session : Option Session) :=
    { state with log := state.log.push (request, (session.map (·.protocol)).getD .init, thread) }
  match request with
  | .open .. =>
    let number := state.sessions.size + 1
    let opened : Opened :=
      { session := number, sessionId := fake.script.sessionId, mode := fake.script.mode
        modes := fake.script.modes }
    let state := arrived none
    (true, [id],
      { state with
        sessions := state.sessions.push { number }
        pending := state.pending.push (id, request, .ok (.mk opened)) })
  | .next number =>
    match state.session? number with
    | none => (false, [], arrived none)
    | some session =>
      let state := arrived (some session)
      if session.waiting.isSome then (false, [], state)
      else
        if !session.queue.isEmpty || session.ended then
          (true, [id],
            { state with
              pending := state.pending.push (id, request, .ok (.mk ({ events := #[] } : Batch))) })
        else
          (true, [],
            { (state.put { session with waiting := some id }) with
              pending := state.pending.push (id, request, .ok (.mk ({ events := #[] } : Batch))) })
  | .send number order =>
    match state.session? number with
    | none =>
      (true, [id],
        { (arrived none) with
          pending := state.pending.push (id, request, refusal s!"no session {number}") })
    | some session =>
      let state := arrived (some session)
      let (session, reply) := fake.order session order
      let (state, woken) := fake.wake state session
      (true, id :: woken, { state with pending := state.pending.push (id, request, reply) })

/-- The reply to the wait `id`: a `next`'s is the session's queue, emptied, or
a refusal once the session has ended and nothing is left; any other's is the
one decided at its start. -/
def takeIn (id : UInt64) (state : State) : PackageReply × State :=
  match state.pending.find? (·.1 == id) with
  | none => (refusal "the request is not pending", state)
  | some (_, request, reply) =>
    let state := { state with pending := state.pending.filter (·.1 != id) }
    match request with
    | .next number =>
      match state.session? number with
      | none => (refusal s!"no session {number}", state)
      | some session =>
        if session.queue.isEmpty then
          (refusal (if session.ended then "the session has ended" else "no events"), state)
        else
          (.ok (.mk ({ events := session.queue } : Batch)), state.put { session with queue := #[] })
    | _ => (reply, state)

/-- Withdraws the wait `id`, if it is pending. -/
def cancelIn (fake : Fake) (id : UInt64) (state : State) : State :=
  if state.pending.any (·.1 == id) then
    let sessions :=
      state.sessions.map fun session =>
        if session.waiting == some id then { session with waiting := none } else session
    { state with
      pending := state.pending.filter (·.1 != id), sessions
      withdrawn :=
        if fake.flaws.completesWithdrawn then state.withdrawn.push id else state.withdrawn }
  else state

/-- The fake as the port the runner is given, completing its waits through
`completions` as `answer` says. -/
def serviceOver (fake : Fake) (completions : Editor.Job.Completions)
    (answer : Editor.Job.FakeAnswer := .atOnce) : PackageService
    where
  name := serviceName
  start id request := do
    let some request := Request.ofPackage? request | return false
    let thread ← IO.getTID
    let (taken, woken) ←
      fake.state.modifyGet fun state =>
          let (taken, woken, state) := fake.startIn id request thread state
          ((taken, woken), state)
    for wait in woken do
      answer.complete completions wait
    return taken
  take id _ := fake.state.modifyGet (takeIn id)
  cancel id := fake.state.modify (fake.cancelIn id)
  flush id := answer.complete completions id

/-- The fake as the port the runner is given, over `completions`, completing
each wait at once. -/
def service (fake : Fake) (completions : Editor.Job.Completions) : PackageService :=
  fake.serviceOver completions

/-- Whether the fake holds no request: none started and not yet taken or
withdrawn. -/
def quiescent (fake : Fake) : BaseIO Bool :=
  return (← fake.state.get).pending.isEmpty

/-- The fake as a package's own fake of its service, for a stepped stage
(`Stage.stepped`'s `packageFakes`): made over the stage's table and pump, so
each of its completions is a step of the check's. -/
def packageFake (fake : Fake) : Editor.Job.PackageFake where
  name := serviceName
  make completions answer :=
    return { service := fake.serviceOver completions answer, quiescent := fake.quiescent }

/-- Every request the fake was handed, with its session's model state as it
arrived and the thread that handed it, oldest first. -/
def log (fake : Fake) : BaseIO (Array (Request × Protocol.State × UInt64)) :=
  return (← fake.state.get).log

/-- The session `number`, the first by default, as the fake holds it now. -/
def session? (fake : Fake) (number : Nat := 1) : BaseIO (Option Session) :=
  return (← fake.state.get).session? number

/-- The trace of the protocol's model of the session `number`, the first by
default. -/
def trace (fake : Fake) (number : Nat := 1) : BaseIO (List Protocol.Action) :=
  return (((← fake.state.get).session? number).map (·.trace.toList)).getD []

end Fake

end AgentsApiTest
