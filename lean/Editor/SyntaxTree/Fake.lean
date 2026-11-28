import Editor.SyntaxTree.Model

/-!
# The syntax service's deliveries, faked

`FakeSyntaxService`, the recording fake of the background half of the
library's syntax service: the parse worker, whose deliveries a host meets as
`Event.parsed` (`Editor/Headless.lean`). The question half stays the
model's (`Editor/SyntaxTree/Model.lean`): the fake adds no query semantics,
it holds each delivery until the check steps it.

- Its handler forwards each request to the model, on the caller's thread,
  and records that thread.
- A delivery is pending from an attach, a highlight or an injection of a
  text, and from the first request that names a new snapshot of a text
  that is attached. Until it is stepped, `captures` and `capturesOf` of
  that text are refused `notParsed`, through the model's own
  `delivered := false`, after every check the real binding makes first.
- A text parsed once (`parseOnce`) makes no delivery pending: the library
  answers it in the call, and the fake forwards it to the model as every
  question.
- `step` delivers the oldest pending delivery, then calls `post` once, on
  the caller's thread: a host check's maker posts a `parsed` event there
  (`Stage.fakeSyntaxService`, `Editor/Test/Linked/Host.lean`).
- `learn`, when given, tells the model a snapshot's text the first time a
  request names one it does not know: the maker reads it from the host's
  published table.

It starts no thread: its state is one reference. Once stepped to its end
(`settleAll`) nothing is pending (`quiescent`). Its own promises are pinned
by `ModelTest.syntaxFakeChecks`, and the maker on a stepped host by
`ConfigTest.stageMakerChecks`.

## Where an addition goes

A new request that starts background work in the library is a case of
`answer` that makes a delivery pending; what every adapter must keep of it
is a property of `Editor/SyntaxTree/DeliveryContract.lean`.
-/

namespace Editor

/-- What the fake syntax service holds. -/
structure FakeSyntaxService.State where
  /-- What the questions are answered from. -/
  model : SyntaxTreeModel := {}
  /-- The thread of each request, oldest first. -/
  requestThreads : Array UInt64 := #[]
  /-- The snapshots whose text's delivery is pending, oldest first. -/
  pending : Array SnapshotId := #[]
  /-- The snapshots a request has named. -/
  seen : Array SnapshotId := #[]
  /-- The thread of each post, oldest first. -/
  postThreads : Array UInt64 := #[]

/-- The fake of the syntax service's deliveries. -/
structure FakeSyntaxService where
  /-- What it holds. Every change to it is one atomic step. -/
  state : IO.Ref FakeSyntaxService.State
  /-- Called once by each step, on the stepping thread. -/
  post : BaseIO Unit := pure ()
  /-- The text of a snapshot the model does not know, if any. -/
  learn : SnapshotId → BaseIO (Option String) := fun _ => pure none

namespace FakeSyntaxService

/-- A service over `model`, nothing pending. -/
def new (model : SyntaxTreeModel := {}) (post : BaseIO Unit := pure ())
    (learn : SnapshotId → BaseIO (Option String) := fun _ => pure none) :
    BaseIO FakeSyntaxService :=
  return { state := ← IO.mkRef { model }, post, learn }

/-- The snapshot a request names, if it names one. -/
def named? : SyntaxTreeRequest → Option SnapshotId
  | .attach snapshot _ | .detach snapshot | .captures snapshot _ _ _ | .highlight snapshot _ _ |
    .inject snapshot _ | .injectLanguage snapshot _ _ _ _ | .keep snapshot _ _ |
    .capturesOf snapshot _ _ _ => some snapshot
  | _ => none

namespace State

/-- Whether the text of `snapshot` has a delivery pending. -/
def undelivered (state : State) (snapshot : SnapshotId) : Bool :=
  state.pending.any (state.model.sameText · snapshot)

/-- `state` with a delivery of `snapshot`'s text pending, unless one is. -/
def deliver (state : State) (snapshot : SnapshotId) : State :=
  if state.undelivered snapshot then state
  else { state with pending := state.pending.push snapshot }

/-- `state` with a delivery of `snapshot`'s text pending when `reply` is
`ok`. -/
def deliverIf {α : Type} (state : State) (snapshot : SnapshotId) : Except SyntaxTreeError α → State
  | .ok _ => state.deliver snapshot
  | .error _ => state

end State

/-- The model's answer to `request`, a question of captures of a text whose
delivery is pending refused `notParsed`, and the state after it. -/
def answer : (request : SyntaxTreeRequest) → State → request.Reply × State
  | .captures snapshot query first last, state =>
    let model :=
      if state.undelivered snapshot then { state.model with delivered := false } else state.model
    (model.captures snapshot query first last, state)
  | .capturesOf snapshot kind first last, state =>
    let model :=
      if state.undelivered snapshot then { state.model with delivered := false } else state.model
    (model.capturesOf snapshot kind first last, state)
  | .attach snapshot named, state =>
    let (reply, model) := state.model.attach snapshot named
    (reply, ({ state with model }).deliverIf snapshot reply)
  | .highlight snapshot query faces, state =>
    let (reply, model) := state.model.highlight snapshot query faces
    (reply, ({ state with model }).deliverIf snapshot reply)
  | .inject snapshot query, state =>
    let (reply, model) := state.model.inject snapshot query
    (reply, ({ state with model }).deliverIf snapshot reply)
  | .detach snapshot, state =>
    let (reply, model) := state.model.detach snapshot
    let pending := state.pending.filter (!state.model.sameText · snapshot)
    (reply,
      { state with
        model, pending })
  | request, state =>
    let (reply, model) := SyntaxTreeModel.handle request state.model
    (reply, { state with model })

/-- Answers `request` on the caller's thread, recording it: a snapshot it
names that the model does not know is learnt first, and a new snapshot of
an attached text makes its delivery pending. -/
def handle (fake : FakeSyntaxService) : SyntaxTreeHandler := fun request => do
  let thread ← IO.getTID
  let named := named? request
  if let some snapshot := named then
    if ((← fake.state.get).model.text? snapshot).isNone then
      if let some text← fake.learn snapshot then
        fake.state.modify fun state =>
            { state with
              model := { state.model with texts := state.model.texts.push (snapshot, text) } }
  fake.state.modifyGet fun state =>
      let state := { state with requestThreads := state.requestThreads.push thread }
      let state :=
        match named with
        | some snapshot =>
          if state.seen.contains snapshot then state
          else
            let fresh := { state with seen := state.seen.push snapshot }
            if
                (state.model.attachedTo? snapshot).isSome &&
                  !state.model.attached.any (·.1 == snapshot) then
              fresh.deliver snapshot
            else fresh
        | none => state
      answer request state

/-- Delivers the oldest pending delivery, then posts once, on the caller's
thread; `false` when nothing was pending. -/
def step (fake : FakeSyntaxService) : BaseIO Bool := do
  let thread ← IO.getTID
  let delivered ←
    fake.state.modifyGet fun state =>
        match state.pending[0]? with
        | some _ =>
          (true,
            { state with
              pending := state.pending.extract 1 state.pending.size
              postThreads := state.postThreads.push thread })
        | none => (false, state)
  if delivered then
    fake.post
  return delivered

/-- Steps until the text of `snapshot` has nothing pending; whether anything
was delivered on the way. -/
partial def settle (fake : FakeSyntaxService) (snapshot : SnapshotId) : BaseIO Bool := do
  if (← fake.state.get).undelivered snapshot then
    discard <| fake.step
    discard <| fake.settle snapshot
    return true
  return false

/-- Steps every pending delivery, oldest first. -/
partial def settleAll (fake : FakeSyntaxService) : BaseIO Unit := do
  if ← fake.step then
    fake.settleAll

/-- How many posts the steps made. -/
def posts (fake : FakeSyntaxService) : BaseIO Nat :=
  return (← fake.state.get).postThreads.size

/-- The thread of each request, oldest first. -/
def requestThreads (fake : FakeSyntaxService) : BaseIO (Array UInt64) :=
  return (← fake.state.get).requestThreads

/-- The thread of each post, oldest first. -/
def postThreads (fake : FakeSyntaxService) : BaseIO (Array UInt64) :=
  return (← fake.state.get).postThreads

/-- Whether nothing is pending. -/
def quiescent (fake : FakeSyntaxService) : BaseIO Bool :=
  return (← fake.state.get).pending.isEmpty

end FakeSyntaxService

end Editor
