import Editor.File.Model
import Editor.Headless.Journal

/-!
# The session journal's recording fake

`RecordingJournal`, the fake of the journal's port
(`Editor/Headless/Journal.lean`), published for `model-test` and
`config-test`. A host check hands its `journal` to the host
(`Collaborators.journal`) and steps it on its own thread.

- `perform` records the order with the thread that handed it, and does
  nothing else: no order is worked until the check steps.
- `step` works the oldest unworked order on the pure model of files
  (`Editor/File/Model.lean`), on the caller's thread, keeps a refusal as a
  failure, and then resolves every drain the orders worked so far cover.
- `drained` registers a drain over every order recorded so far: resolved at
  once, on the caller's thread, when all of them are already worked, and
  otherwise by the `step` that works the last of them.
- `failures` takes the kept failures, oldest first, once.

It starts no thread and calls nothing that does: its only state is one
reference and the promises it hands out. Once `stepAll` has run, nothing is
unworked and no drain is waiting (`quiescent`), so a check that ends there
leaves nothing to drain.

A save names a snapshot (`File.Source.snapshot`). When the fake was made
with a reader of a host's published table (`snapshots`), the text is read
when the order is handed, as the real journal finds the library's snapshot
then (`Journal.real`), since the host releases the snapshot right after;
otherwise the save reads the model's own snapshots when it is worked.

## Where an addition goes

- A new order kind is worked by `FileModel.handle`; nothing here changes.
- A new readout is a function at the end of the namespace, over `State`.
- What the fake promises that the real journal must keep too is a property
  of the contract (`Editor/Headless/Journal/Contract.lean`).
-/

namespace Editor.Headless

/-- What a recording journal holds. -/
structure RecordingJournal.State where
  /-- The files the orders are worked on, and the snapshots a save may
  name. -/
  model : FileModel := {}
  /-- Every order handed, with the thread that handed it, oldest first. -/
  recorded : Array (Restore.Order × UInt64) := #[]
  /-- How many of `recorded`, from the oldest, have been worked. -/
  worked : Nat := 0
  /-- The drains waiting, each the count of orders it covers and the promise
  resolved once that many are worked. -/
  drains : Array (Nat × IO.Promise Bool) := #[]
  /-- The failures not yet taken, each a path and why, oldest first. -/
  failures : Array (String × String) := #[]
  /-- The thread of each answer: an order worked, or a drain resolved. -/
  answerThreads : Array UInt64 := #[]

/-- The recording fake of the journal's port. -/
structure RecordingJournal where
  /-- What it holds. Every change to it is one atomic step. -/
  state : IO.Ref RecordingJournal.State
  /-- The text of a published snapshot, when the fake reads a host's table;
  `none` to read the model's own snapshots. -/
  snapshots : Option (SnapshotId → BaseIO (Option String)) := none

namespace RecordingJournal

/-- A journal over `model` that has recorded nothing, reading the text of a
save's snapshot from `snapshots` when given. -/
def new (model : FileModel := {})
    (snapshots : Option (SnapshotId → BaseIO (Option String)) := none) : BaseIO RecordingJournal :=
  return { state := ← IO.mkRef { model }, snapshots }

/-- `model` with `text` in the slot of the snapshot `id`. -/
private def withSnapshot (model : FileModel) (id : SnapshotId) (text : String) : FileModel :=
  let size := max model.snapshots.size (id.index + 1)
  let slots :=
    (model.snapshots ++ Array.replicate (size - model.snapshots.size) none).setIfInBounds id.index
      (some { contents := text })
  { model with snapshots := slots }

/-- Records `order`, with the calling thread; for a save of a snapshot,
with the text the fake's reader finds for it now. -/
def perform (journal : RecordingJournal) (order : Restore.Order) : BaseIO Unit := do
  let thread ← IO.getTID
  let text : Option (SnapshotId × String) ←
    match journal.snapshots, order.request with
    | some read, .save (.snapshot id) _ _ =>
      pure ((← read id).map (id, ·))
    | _, _ =>
      pure none
  journal.state.modify fun state =>
      let model :=
        match text with
        | some (id, text) => withSnapshot state.model id text
        | none => state.model
      { state with
        model, recorded := state.recorded.push (order, thread) }

/-- Resolves, with `true`, every drain of `state` that its worked orders
cover, on the caller's thread, and returns the state without them. -/
private def settled (state : State) (thread : UInt64) : State × Array (IO.Promise Bool) :=
  let (covered, waiting) := state.drains.partition (·.1 ≤ state.worked)
  ({ state with
      drains := waiting
      answerThreads := state.answerThreads ++ covered.map fun _ => thread },
    covered.map (·.2))

/-- A drain over every order recorded so far: a task that ends `true` once
all of them are worked. Ends at once when they already are. -/
def drained (journal : RecordingJournal) : BaseIO (Task Bool) := do
  let promise ← IO.Promise.new
  let thread ← IO.getTID
  let resolved ←
    journal.state.modifyGet fun state =>
        let state := { state with drains := state.drains.push (state.recorded.size, promise) }
        let (state, resolved) := settled state thread
        (resolved, state)
  for promise in resolved do
    promise.resolve true
  return promise.result?.map (sync := true) (·.getD false)

/-- Works the oldest unworked order on the model, on the caller's thread,
keeping a refusal as a failure, then resolves every drain now covered.
`false` when nothing was left to work. -/
def step (journal : RecordingJournal) : BaseIO Bool := do
  let thread ← IO.getTID
  let state ← journal.state.get
  let some (order, _) := state.recorded[state.worked]? | return false
  let resolved ←
    journal.state.modifyGet fun state =>
        let (reply, model) := FileModel.handle order.request state.model
        let failures :=
          match order.failed reply with
          | some failure => state.failures.push failure
          | none => state.failures
        let state :=
          { state with
            model, failures, worked := state.worked + 1
            answerThreads := state.answerThreads.push thread }
        let (state, resolved) := settled state thread
        (resolved, state)
  for promise in resolved do
    promise.resolve true
  return true

/-- Works every order recorded, oldest first, with `step`. -/
partial def stepAll (journal : RecordingJournal) : BaseIO Unit := do
  if ← journal.step then
    journal.stepAll

/-- Takes the kept failures, oldest first, once. -/
def failures (journal : RecordingJournal) : BaseIO (Array (String × String)) :=
  journal.state.modifyGet fun state => (state.failures, { state with failures := #[] })

/-- The fake as the port a host is handed. -/
def journal (journal : RecordingJournal) : Journal where
  perform order := journal.perform order
  failures := journal.failures
  drained := journal.drained

/-- Every order handed, oldest first. -/
def orders (journal : RecordingJournal) : BaseIO (Array Restore.Order) :=
  return (← journal.state.get).recorded.map (·.1)

/-- The thread that handed each order of `orders`. -/
def orderThreads (journal : RecordingJournal) : BaseIO (Array UInt64) :=
  return (← journal.state.get).recorded.map (·.2)

/-- The thread of each answer, an order worked or a drain resolved, oldest
first. -/
def answerThreads (journal : RecordingJournal) : BaseIO (Array UInt64) :=
  return (← journal.state.get).answerThreads

/-- The model as it is now. -/
def model (journal : RecordingJournal) : BaseIO FileModel :=
  return (← journal.state.get).model

/-- How many orders are recorded and not yet worked. -/
def unworked (journal : RecordingJournal) : BaseIO Nat := do
  let state ← journal.state.get
  return state.recorded.size - state.worked

/-- Whether nothing is unworked and no drain is waiting: nothing is left to
drain. -/
def quiescent (journal : RecordingJournal) : BaseIO Bool := do
  let state ← journal.state.get
  return state.worked == state.recorded.size && state.drains.isEmpty

end RecordingJournal

end Editor.Headless
