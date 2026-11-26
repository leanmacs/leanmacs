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
  scripted agent executable plays too; `answerEnds`, in which the answer
  to the first permission request gives the completed call and the turn's
  end; `cancellable`, the canonical one whose cancel leaves the session
  open; `conversation`, a turn with a reply, a tool call whose diff is
  replaced by the whole file's, usage, a title and a mode;
  `permissionRequest`, a prompt that parks a permission request for an edit
  with its raw input and diff, offering the adapter's three options, whose
  answer ends the turn; `burst`, a prompt's many chunks; and `table`
  and `resumable`, the agent table's agent, whose prompts' texts say what
  they give and whose store, in `resumable`, holds a session's history. Between orders the agent may also send by itself
  (`Fake.agentSends`), through the same model.
- **A load** of a session the script holds a history of (`Script.history`)
  opens a session whose first events are that history, answered with the
  session id asked for; a load of any other is refused, `the agent has no
  session <id>`.
- **A request completes** as the stage says (`FakeAnswer`): `open`, `load`
  and `send` at once; `next` at once when the session holds events, and
  otherwise once an order makes some, or never if it is withdrawn first.
  A second `next` of a session while one is pending is refused at its
  start. `flush` completes at once, never waiting for a pending `next`.
- **It records** every request with the session's model state it arrived
  in and the thread that handed it (`Fake.log`), and each session's trace of
  the model's actions (`Fake.trace`), and says when it holds no request
  (`Fake.quiescent`).

It is made once and given to the runner over a table of waits: as a
`PackageService` directly (`Fake.service`), or on a stepped stage as a
package's fake (`Fake.packageFake`, `Stage.stepped`); or made afresh by each
stage that makes it (`Fake.fresh`), as a fixture's support hands it to the
stepped fixture harness (`AgentsApiTest/FixtureSupport.lean`). `Fake.Flaws` makes a
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
  /-- The history of each session it holds in its store, which a load
  replays first; none for a session it does not hold. -/
  history : String → Option (Array Event) := fun _ => none
  /-- The id of each session it opens, the first's first; past their end,
  `sessionId`. -/
  sessionIds : Array String := #[]

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
  /-- How the service last given to the runner completes a wait: recorded by
  each start of that service (`serviceOver`), so the agent's own sends
  (`agentSends`) wake a pending `next` as an order's moves do. -/
  waker : IO.Ref (UInt64 → BaseIO Unit)

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
  history id := if id == Contract.sessionId then some Contract.history else none

/-- The canonical agent, but the answer to the first permission request gives
the call completed and the turn's end, `end_turn`. -/
def answerEnds : Script :=
  { canonical with
    onAnswer := fun ticket _ =>
      if ticket == 1 then [.event (.toolCall Contract.completed), .endTurn "end_turn"] else [] }

/-- The path the conversation's tool call edits. -/
def notesPath : String :=
  "/work/example/notes.txt"

/-- The conversation's tool call before it runs: its diff holds only the
edit's own strings, as the adapter sends it (`docs/design/agent-hosting.md`,
"The ACP spike"). -/
def editPending : ToolCall :=
  { id := "call-edit-1", title := "Edit notes.txt", kind := "edit", status := "pending"
    locations := #[(notesPath, none)], content := #[.diff notesPath (some "beta") "gamma"] }

/-- The conversation's tool call once it has run: its diff is the whole
file, before and after. -/
def editCompleted : ToolCall :=
  { editPending with
    status := "completed", content := #[.diff notesPath (some "alpha\nbeta\n") "alpha\ngamma\n"] }

/-- A conversation, for a consumer's view of one: the session opens in
`mode-auto`; a prompt gives the mode `mode-ask`, the reply `Done.` in two
chunks of the message `msg-1`, the tool call `call-edit-1` pending with the
edit's own strings as its diff and then completed with the whole file's,
the usage, the title `Example title`, and the turn's end, `end_turn`. -/
def conversation : Script where
  sessionId := Contract.sessionId
  mode := some "mode-auto"
  modes := Contract.modes
  onPrompt _ _ :=
    [.event (.mode "mode-ask"), .event (.chunk (some "msg-1") "Do"),
      .event (.chunk (some "msg-1") "ne."), .event (.toolCall editPending),
      .event (.toolCall editCompleted), .event (.usage 1200 200000 (some ("0.01", "USD"))),
      .event (.title "Example title"), .endTurn "end_turn"]
  onAnswer _ _ := []
  onCancel := [.endTurn "cancelled"]

/-- The edit as the agent asks permission for it: the pending call with
its raw input, the edit's own strings, as the adapter sends it
(`docs/design/agent-hosting.md`, "The ACP spike"); every value synthetic. -/
def editAsked : ToolCall :=
  { editPending with
    rawInput :=
      "{\"file_path\":\"/work/example/notes.txt\",\"old_string\":\"beta\",\"new_string\":\"gamma\"}" }

/-- The options the adapter builds for an edit's permission request: allow
once, allow for the session, and reject once; never `reject_always`. -/
def adapterOptions : Array PermissionOption :=
  #[{ id := "allow-once", name := "Yes", kind := "allow_once" },
    { id := "allow-session", name := "Yes, for this session", kind := "allow_always" },
    { id := "reject", name := "No", kind := "reject_once" }]

/-- An agent that asks permission for its edit: a prompt gives the call
`editPending` and then parks a permission request for `editAsked` with
`adapterOptions`; the answer to ticket 1 gives the call completed and the
turn's end, `end_turn`; a cancel ends the turn `cancelled` and the session
goes on. -/
def permissionRequest : Script where
  sessionId := Contract.sessionId
  mode := some "mode-auto"
  modes := Contract.modes
  onPrompt _ _ := [.event (.toolCall editPending), .ask editAsked adapterOptions]
  onAnswer ticket _ :=
    if ticket == 1 then [.event (.toolCall editCompleted), .endTurn "end_turn"] else []
  onCancel := [.endTurn "cancelled"]

/-- The canonical agent, but a cancel ends the turn `cancelled` and the
session goes on: the agent does not exit. -/
def cancellable : Script :=
  { canonical with onCancel := [.endTurn "cancelled"] }

/-- An agent whose prompt gives `count` chunks of the message `msg-1`, each
`x`, and nothing else: its turn stays open. -/
def burst (count : Nat) : Script :=
  { canonical with
    onPrompt := fun _ _ => (List.range count).map fun _ => .event (.chunk (some "msg-1") "x")
    onAnswer := fun _ _ => []
    onCancel := [.endTurn "cancelled"] }

/-- A shell command running the tests, in progress. -/
def bashRunning : ToolCall :=
  { id := "call-bash-1", title := "Run the tests", kind := "execute", status := "in_progress" }

/-- The agent the agent table's checks run several sessions of, each with
its own id, `sess-0001` to `sess-0004`; what a prompt gives depends on its
text:

- `work`: the chunk `Working.` and `call-bash-1` in progress, its turn left
  open;
- `ask`: the edit `editPending`, then a permission request for `editAsked`
  with `adapterOptions`, whose answer to ticket 1 gives the edit completed
  and the turn's end;
- `bg`: the reply `Started.`, `call-bash-1` in progress, and the turn's
  end, `end_turn`, the call still in flight;
- anything else: `conversation`'s turn, with its title `Example title`. -/
def table : Script where
  sessionId := Contract.sessionId
  sessionIds := #["sess-0001", "sess-0002", "sess-0003", "sess-0004"]
  mode := some "mode-auto"
  modes := Contract.modes
  onPrompt turn text :=
    match text with
    | "work" => [.event (.chunk (some "msg-w") "Working."), .event (.toolCall bashRunning)]
    | "ask" => [.event (.toolCall editPending), .ask editAsked adapterOptions]
    | "bg" =>
      [.event (.chunk (some "msg-1") "Started."), .event (.toolCall bashRunning),
        .endTurn "end_turn"]
    | _ => conversation.onPrompt turn text
  onAnswer ticket _ :=
    if ticket == 1 then [.event (.toolCall editCompleted), .endTurn "end_turn"] else []
  onCancel := [.endTurn "cancelled"]

/-- The history the agent's store holds of `sess-0001`: the user's
`Read notes.txt.`, the reply `Done.`, the edit completed and the title. -/
def resumedHistory : Array Event :=
  #[.userChunk (some "msg-u1") "Read notes.txt.", .chunk (some "msg-1") "Done.",
    .toolCall editCompleted, .title "Example title"]

/-- `table`, whose store holds `sess-0001` with `resumedHistory`, so a load
of it is answered. -/
def resumable : Script :=
  { table with history := fun id => if id == "sess-0001" then some resumedHistory else none }

/-- A fake over `script`, breaking the rules `flaws` names. -/
def new (script : Script := canonical) (flaws : Flaws := .none) : BaseIO Fake :=
  return { script, flaws, state := ← IO.mkRef {}, waker := ← IO.mkRef fun _ => pure () }

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
      { session := number,
        sessionId := (fake.script.sessionIds[number - 1]?).getD fake.script.sessionId
        mode := fake.script.mode, modes := fake.script.modes }
    let state := arrived none
    (true, [id],
      { state with
        sessions := state.sessions.push { number }
        pending := state.pending.push (id, request, .ok (.mk opened)) })
  | .load _ _ _ sessionId =>
    let state := arrived none
    match fake.script.history sessionId with
    | none =>
      (true, [id],
        { state with
          pending :=
            state.pending.push (id, request, refusal s!"the agent has no session {sessionId}") })
    | some history =>
      let number := state.sessions.size + 1
      let opened : Opened :=
        { session := number, sessionId, mode := fake.script.mode, modes := fake.script.modes }
      (true, [id],
        { state with
          sessions := state.sessions.push { number, queue := history }
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
    fake.waker.set (answer.complete completions)
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

/-- A package's own fake of the service over a new fake of `script`, made
afresh each time the stage makes it (`PackageFake.make`): so each stepped
run, a fixture's among them, starts with no session, and what one run left
cannot reach the next. -/
def fresh (script : Script) : Editor.Job.PackageFake where
  name := serviceName
  make completions answer := do
    let fake ← Fake.new script
    return { service := fake.serviceOver completions answer, quiescent := fake.quiescent }

/-- The agent of the session `number` does `moves` by itself, between two
orders: each through the session's model (`Session.moves`), as an order's
moves go, and its pending `next`, if it has one, is woken through the
completion the service last given to the runner recorded. Nothing happens
to a session the fake did not open. -/
def agentSends (fake : Fake) (number : Nat) (moves : List Move) : BaseIO Unit := do
  let woken ←
    fake.state.modifyGet fun state =>
        match state.session? number with
        | none => ([], state)
        | some session => (fake.wake state (session.moves moves)).swap
  let waker ← fake.waker.get
  for id in woken do
    waker id

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
