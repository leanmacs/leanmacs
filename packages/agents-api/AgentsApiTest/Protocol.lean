/-!
# The protocol's rules, as a pure model

What a client of a coding agent keeps of the Agent Client Protocol, as a
state machine (`docs/design/agent-hosting.md`, "ACP"): the requests it has
sent and not had answered, the permission requests the agent has made of it
and it has not answered, every ticket it was asked under, the answers it
has given, the turn it is in, the turns it cancelled, and whether the
connection is closed.

- **`send r turn`**: the client sends the request `r`, refused while `r` is
  outstanding. A prompt names the turn it begins (`some turn`), which is
  the current turn from then on.
- **`respond r`**: the agent answers the request `r`, refused unless `r` is
  outstanding. A response to nothing is refused.
- **`ask t`**: the agent asks permission under the ticket `t`, refused when
  `t` was asked before. It is parked under the current turn, unless that
  turn is cancelled: then the client answers it at once (`cancelled`), and
  it is never parked.
- **`answer t`**: the client answers the parked ticket `t`, refused unless
  `t` is parked: a second answer, or an answer to a ticket never asked,
  is refused.
- **`cancel`**: the client cancels the current turn: every parked request
  of that turn is answered (`cancelled`), and the turn is marked cancelled,
  so a request of it that comes later is answered at once.
- **`close`**: the connection ends: every parked request is answered, as a
  dropped responder answers, and nothing is outstanding any more. Every
  step after a close is refused.

`step` is the one transition function and `replay` its checker over a
trace, which the contract runs on what it observed of an implementation
(`AgentsApiTest/Contract.lean`); the fake of the service keeps its
bookkeeping with `step` itself (`AgentsApiTest/Fake.lean`), so it agrees
with the theorems (`AgentsApiTest/Protocol/Theorems.lean`) by construction.
-/

namespace AgentsApiTest.Protocol

/-- A request the client sent, by its number. -/
abbrev RequestId :=
  Nat

/-- A permission request the agent made, by the ticket the client parked it
under. -/
abbrev Ticket :=
  Nat

/-- A prompt turn, by its number. -/
abbrev Turn :=
  Nat

/-- What the client keeps of the protocol. -/
structure State where
  /-- The requests sent and not yet answered, oldest first. -/
  outstanding : List RequestId := []
  /-- The permission requests not yet answered, each with the turn it came
  in, oldest first. -/
  parked : List (Ticket × Option Turn) := []
  /-- Every ticket asked, in the order asked. -/
  asked : List Ticket := []
  /-- The tickets answered, in the order answered: explicitly, by a cancel's
  withdrawal, at once after a cancel, or by the close. -/
  answers : List Ticket := []
  /-- The current turn: the last prompt's. -/
  turn : Option Turn := none
  /-- The turns cancelled. -/
  cancelled : List Turn := []
  /-- Whether the connection has ended. -/
  closed : Bool := false
  deriving DecidableEq, Repr, Inhabited

/-- One thing that happens on the connection. -/
inductive Action where
  /-- The client sends the request `request`; a prompt names the turn it
  begins. -/
  | send (request : RequestId) (turn : Option Turn)
  /-- The agent answers the request `request`. -/
  | respond (request : RequestId)
  /-- The agent asks permission under the ticket `ticket`. -/
  | ask (ticket : Ticket)
  /-- The client answers the parked ticket `ticket`. -/
  | answer (ticket : Ticket)
  /-- The client cancels the current turn. -/
  | cancel
  /-- The connection ends. -/
  | close
  deriving DecidableEq, Repr, Inhabited

namespace State

/-- The initial state: nothing sent, nothing asked. -/
def init : State :=
  {}

/-- The tickets parked, oldest first. -/
def parkedTickets (state : State) : List Ticket :=
  state.parked.map (·.1)

/-- Whether the current turn is cancelled. -/
def turnCancelled (state : State) : Prop :=
  ∃ turn ∈ state.cancelled, state.turn = some turn

instance (state : State) : Decidable state.turnCancelled :=
  inferInstanceAs (Decidable (∃ turn ∈ state.cancelled, state.turn = some turn))

/-- The state after `action`, or `none` when the protocol refuses it. -/
def step (state : State) : Action → Option State
  | .send request turn =>
    if state.closed = true ∨ request ∈ state.outstanding then none
    else
      some
        { state with
          outstanding := state.outstanding ++ [request]
          turn := turn.orElse fun _ => state.turn }
  | .respond request =>
    if state.closed = true ∨ request ∉ state.outstanding then none
    else some { state with outstanding := state.outstanding.erase request }
  | .ask ticket =>
    if state.closed = true ∨ ticket ∈ state.asked then none
    else
      if state.turnCancelled then
        some
          { state with
            asked := state.asked ++ [ticket]
            answers := state.answers ++ [ticket] }
      else
        some
          { state with
            asked := state.asked ++ [ticket]
            parked := state.parked ++ [(ticket, state.turn)] }
  | .answer ticket =>
    if state.closed = true ∨ ticket ∉ state.parkedTickets then none
    else
      some
        { state with
          parked := state.parked.filter (·.1 != ticket)
          answers := state.answers ++ [ticket] }
  | .cancel =>
    if state.closed = true then none
    else
      match state.turn with
      | none => some state
      | some turn =>
        some
          { state with
            parked := state.parked.filter (·.2 != some turn)
            answers := state.answers ++ (state.parked.filter (·.2 == some turn)).map (·.1)
            cancelled :=
              if turn ∈ state.cancelled then state.cancelled else state.cancelled ++ [turn] }
  | .close =>
    if state.closed = true then none
    else
      some
        { state with
          parked := []
          answers := state.answers ++ state.parked.map (·.1)
          outstanding := []
          closed := true }

end State

/-- The first step a trace breaks: its index in the trace, the step, and the
state it was refused in. -/
structure Violation where
  /-- The step's index, from 0. -/
  index : Nat
  /-- The step. -/
  action : Action
  /-- The state that refused it. -/
  state : State
  deriving Repr

/-- The state `actions` reach from `state`, the first of them at `index`, or
the first step refused. -/
def replayFrom (state : State) (index : Nat) : List Action → Except Violation State
  | [] => .ok state
  | action :: rest =>
    match state.step action with
    | some after => replayFrom after (index + 1) rest
    | none => .error { index, action, state }

/-- The state a trace reaches from the initial state, or the first step it
breaks: the checker the contract runs on an observed trace. -/
def replay (actions : List Action) : Except Violation State :=
  replayFrom State.init 0 actions

/-- A violation as a sentence. -/
def Violation.text (violation : Violation) : String :=
  s!"step {violation.index}, {repr violation.action}, is refused in {repr violation.state}"

end AgentsApiTest.Protocol
