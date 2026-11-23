import Editor.SyntaxTree
import Editor.SyntaxTree.Model

/-!
# The contract of the syntax service's deliveries

What every syntax service keeps of the background half, its deliveries of
parses, as a list of properties over a `DeliveryRig`: the rig gives the
handler, how to make a json text and how to edit it to a new snapshot of
the same text, and how to settle a snapshot's delivery. The answers
themselves are the model's (`Editor/SyntaxTree/Model.lean`): each property
compares a question's answer with the model's for the same text. The same
list runs two ways:

- over the fake (`FakeSyntaxService`, `Editor/SyntaxTree/Fake.lean`), by
  `model-test` (`ModelTest.syntaxDeliveryChecks`): `settle` steps the fake
  until the text has nothing pending;
- over the real binding (`RealSyntaxTree`, `Editor/SyntaxTree/Real.lean`) on
  the library's syntax service, by `contract-test`
  (`ContractTest.syntaxDeliveryChecks`): `settle` waits on
  `Ffi.syntaxSettle` of the check's own snapshot, its own document's
  delivery.

No property highlights a text, so the real binding posts no `parsed` event
to the editor queue: that half of the real path is pinned by the binding's
own check (`FfiTest.syntaxChecks`).

This module imports the port and its model only.

## Where an addition goes

A new promise of a delivery is a `Property` here, in `properties`; both
runners run it.
-/

namespace Editor.SyntaxDeliveryContract

/-- A syntax service as the contract runs it. -/
structure DeliveryRig where
  /-- Which service, as a failure names it. -/
  name : String
  /-- The handler. -/
  handler : SyntaxTreeHandler
  /-- A new text holding `contents`, and the id of its snapshot. -/
  make : String → IO SnapshotId
  /-- The text of `snapshot` edited to hold `contents`, and the id of the new
  snapshot, of the same text. -/
  edit : SnapshotId → String → IO SnapshotId
  /-- Waits for the delivery of `snapshot`'s text, as the service does it:
  whether there was one to wait for. -/
  settle : SnapshotId → IO Bool

/-- One property: whether it holds on a fresh rig, or why not, thrown. -/
structure Property where
  /-- What must hold, as a sentence. -/
  name : String
  /-- Observes it on a fresh rig. -/
  holds : DeliveryRig → IO Bool

/-- The query every property asks: every number. -/
def query : String :=
  "(number) @n"

/-- The model's answer to the query over `contents`, attached to `json`. -/
def modelAnswer (contents : String) : Except SyntaxTreeError (Array SyntaxTree.Capture) :=
  let snapshot : SnapshotId := ⟨0⟩
  let program : SyntaxTreeM (Array SyntaxTree.Capture) := do
    SyntaxTree.attach snapshot "json"
    let compiled ← SyntaxTree.compile "json" query
    SyntaxTree.captures snapshot compiled 0 contents.utf8ByteSize
  (program.runModel { texts := #[(snapshot, contents)] }).1

/-- Two answers alike: the same captures, or the same refusal. -/
def same (a b : Except SyntaxTreeError (Array SyntaxTree.Capture)) : Bool :=
  match a, b with
  | .ok a, .ok b => a == b
  | .error a, .error b => a == b
  | _, _ => false

/-- An answer, said for a failure. -/
def shown : Except SyntaxTreeError (Array SyntaxTree.Capture) → String
  | .ok captures => s!"{repr captures}"
  | .error error => s!"refused {repr error}"

/-- The first text. -/
def first : String :=
  "[1, 2]"

/-- The text an edit makes of it. -/
def edited : String :=
  "[3, 40, 5]"

/-- A text of `first`, attached and its delivery settled, and the query
compiled: the snapshot and the query. -/
def attached (rig : DeliveryRig) : IO (SnapshotId × QueryId) := do
  let snapshot ← rig.make first
  let .ok () ← (SyntaxTree.attach snapshot "json").runWith rig.handler |
    throw <| IO.userError s!"{rig.name}: the attach was refused"
  discard <| rig.settle snapshot
  let .ok compiled ← (SyntaxTree.compile "json" query).runWith rig.handler |
    throw <| IO.userError s!"{rig.name}: the query was refused"
  return (snapshot, compiled)

/-- The captures of the whole of `snapshot`, holding `contents`. -/
def capturesOf (rig : DeliveryRig) (snapshot : SnapshotId) (compiled : QueryId) (contents : String) :
    IO (Except SyntaxTreeError (Array SyntaxTree.Capture)) :=
  (SyntaxTree.captures snapshot compiled 0 contents.utf8ByteSize).runWith rig.handler

/-- D1: after an attach and its delivery, captures answer the model's. -/
def afterAttach : Property where
  name :=
    "after an attach and its delivery, the captures of the snapshot answer the model's for its text, and are not refused as not parsed"
  holds rig := do
    let (snapshot, compiled) ← attached rig
    let answer ← capturesOf rig snapshot compiled first
    unless same answer (modelAnswer first) do
      throw <| IO.userError s!"{rig.name}: answered {shown answer}, the model {shown (modelAnswer first)}"
    return true

/-- D2: after an edit and its delivery, captures of the new snapshot answer
for the new text; before the delivery, not parsed or the new text's
answer, never the old text's. -/
def afterEdit : Property where
  name :=
    "after an edit, the new snapshot's captures asked before its delivery are refused as not parsed or answer the new text's, never the old text's; after the delivery they answer the new text's"
  holds rig := do
    let (snapshot, compiled) ← attached rig
    let next ← rig.edit snapshot edited
    let early ← capturesOf rig next compiled edited
    let earlyHeld := same early (.error .notParsed) || same early (modelAnswer edited)
    discard <| rig.settle next
    let late ← capturesOf rig next compiled edited
    unless earlyHeld && same late (modelAnswer edited) do
      throw <|
          IO.userError
            s!"{rig.name}: before the delivery {shown early}, after it {shown late}; the model {shown (modelAnswer edited)}"
    return true

/-- D3: a detached text's captures are refused, and its settle has nothing
to wait for. -/
def detached : Property where
  name :=
    "a detached text's captures are refused as not attached, and a settle of it answers at once with nothing delivered"
  holds rig := do
    let (snapshot, compiled) ← attached rig
    let .ok () ← (SyntaxTree.detach snapshot).runWith rig.handler |
      throw <| IO.userError s!"{rig.name}: the detach was refused"
    let answer ← capturesOf rig snapshot compiled first
    let settled ← rig.settle snapshot
    unless same answer (.error .notAttached) && !settled do
      throw <| IO.userError s!"{rig.name}: answered {shown answer}, and the settle said {settled}"
    return true

/-- The properties, in the order they run. -/
def properties : List Property :=
  [afterAttach, afterEdit, detached]

end Editor.SyntaxDeliveryContract
