import Editor.Ffi
import Editor.Text

/-!
# The real binding of the text port

The text port (`Editor/Text.lean`) answered by the Rust library. This is the
only module of the port that imports `Editor.Ffi`, so only an executable
linked with the library imports it: the editor, to run commands for real, and
`contract-test`, which runs the port's contract against it.

It is a thin adapter. A request is plain data and names a text or a snapshot
by an id, so the binding keeps the tables from ids to the library's handles:
an id is an index into one. Each request is one lookup in a table and one or
two calls of a binding. What an edit means, when it is refused, what a row
and a point are: these are the library's decisions (`crates/editor-text`),
and the contract (`Editor/Text/Contract.lean`) is what says they are the same
as the model's.

A question asked of a text is answered by a snapshot of it, taken for the
question and dropped after it. Taking one copies none of the text, so the
library needs one set of read functions, on a snapshot, and none on a
document.

A text or a snapshot lives until it is released or its table is dropped,
whichever is first. Releasing empties its slot, which drops the last
reference to the library's object, and the finaliser frees it at once.
Dropping the table does the same for everything still in it.
-/

namespace Editor

/-- The tables of the real binding: the library's handle for each text and
for each snapshot made so far. An id is an index here, and a slot is `none`
once its text or its snapshot has been released, so an id is never used
again. -/
structure RealTexts where
  /-- The library's document for each text, in the order they were made. -/
  documents : Array (Option Ffi.Document) := #[]
  /-- The library's snapshot for each snapshot, in the order they were
  taken. -/
  snapshots : Array (Option Ffi.Snapshot) := #[]

namespace RealTexts

/-- The library's document for the text `id`; `none` when the id names no
text, or one that was released. -/
def document? (id : TextId) : StateT RealTexts IO (Option Ffi.Document) :=
  return ((← get).documents[id.index]?).join

/-- The library's snapshot for the snapshot `id`; `none` when the id names no
snapshot, or one that was released. -/
def snapshot? (id : SnapshotId) : StateT RealTexts IO (Option Ffi.Snapshot) :=
  return ((← get).snapshots[id.index]?).join

/-- The library's answer to an edit of the text `id`, replacing its bytes
from `start` up to `stop` by `s`.

The port's offsets are `Nat` and the library's are machine words. An offset
no word holds is past the end of any text, so it is refused here: converted,
it would wrap round to an offset the library might accept. -/
def edit (id : TextId) (start stop : Nat) (s : String) :
    StateT RealTexts IO (Except TextError Unit) := do
  let some document ← document? id | return .error .noSuchText
  unless start < USize.size ∧ stop < USize.size do
    return .error .badRange
  if ← document.replace start.toUSize stop.toUSize s then
    return .ok ()
  return .error .badRange

/-- The library's word for a count, an offset or an index of the port.

The port's are `Nat` and a word is 64 bits. One that no word holds is sent
as the largest word, which no text is long enough to accept, so the library
refuses it where it would refuse any other number that is too large:
converted, it would wrap round to one the library might accept. -/
def word (number : Nat) : UInt64 :=
  if number < UInt64.size then number.toUInt64 else 0xFFFF_FFFF_FFFF_FFFF

/-- The library's form of a change of the port. -/
def change : Change → Ffi.Change
  | .retain count => .retain (word count)
  | .delete count => .delete (word count)
  | .insert text => .insert text

/-- The library's form of a selection of the port. -/
def selection (selection : Selection) : Ffi.Selection where
  ranges := selection.ranges.map fun range => ⟨word range.anchor, word range.head⟩
  primary := word selection.primary

/-- The library's form of a transaction of the port. -/
def transaction (transaction : Transaction) : Ffi.Transaction where
  changes := transaction.changes.map change
  before := transaction.before.map selection
  after := transaction.after.map selection

/-- The library's answer to applying `changes` to the text `id`, with
`origin` as who made the edit. When a transaction fits and in what order it
is refused are the library's decisions. -/
def apply (id : TextId) (changes : Transaction) (origin : Origin) :
    StateT RealTexts IO (Except TextError Nat) := do
  let some document ← document? id | return .error .noSuchText
  match ← document.apply (transaction changes) origin.id with
  | .ok revision =>
    return .ok revision.toNat
  | .error .badChange =>
    return .error .badChange
  | .error .badSelection =>
    return .error .badSelection

/-- The library's name for a column unit of the port. -/
def unit : ColumnUnit → Ffi.ColumnUnit
  | .bytes => .bytes
  | .utf16 => .utf16

/-- The library's answer to `query` about `snapshot`.

The port's offsets, rows and columns are `Nat` and the library's are machine
words. One that no word holds is not a position of any text, so it is
refused here: converted, it would wrap round to one the library might
answer. -/
def answer (snapshot : Ffi.Snapshot) : (query : TextQuery) → IO (Except TextError query.Answer)
  | .revision => return .ok (← snapshot.info).revision.toNat
  | .byteLength => return .ok (← snapshot.info).byteLength.toNat
  | .rowCount => return .ok (← snapshot.info).rowCount.toNat
  | .contents => return .ok (← snapshot.read)
  | .pointOf column offset => do
    unless offset < USize.size do
      return .error .badPosition
    let some point ← snapshot.pointOf (unit column) offset.toUSize | return .error .badPosition
    return .ok ⟨point.row.toNat, point.column.toNat⟩
  | .offsetOf column point => do
    unless point.row < UInt64.size ∧ point.column < UInt64.size do
      return .error .badPosition
    let some offset ←
      snapshot.offsetOf (unit column) point.row.toUInt64
          point.column.toUInt64 | return .error .badPosition
    return .ok offset.toNat

/-- The library's snapshot of `source`: the snapshot it names, or a new one
of the text it names, as the text is now. The refusal when it names nothing,
or something that was released. -/
def snapshotOf : TextSource → StateT RealTexts IO (Except TextError Ffi.Snapshot)
  | .text id => do
    let some document ← document? id | return .error .noSuchText
    return .ok (← document.snapshot)
  | .snapshot id => do
    let some snapshot ← snapshot? id | return .error .noSuchSnapshot
    return .ok snapshot

/-- The refusal for `source` when it names nothing, or something that was
released; `none` when the table holds it. -/
def missing? : TextSource → StateT RealTexts IO (Option TextError)
  | .text id => return if (← document? id).isSome then none else some .noSuchText
  | .snapshot id => return if (← snapshot? id).isSome then none else some .noSuchSnapshot

/-- Empties the slot of `source`, which it holds. The slot stays, so later
ids are what they would have been. -/
def released (table : RealTexts) : TextSource → RealTexts
  | .text id => { table with documents := table.documents.setIfInBounds id.index none }
  | .snapshot id => { table with snapshots := table.snapshots.setIfInBounds id.index none }

/-- The library's answer to each request. -/
def handle : (request : TextRequest) → StateT RealTexts IO request.Reply
  | .create initial => do
    let document ← Ffi.Document.new initial
    modifyGet fun table =>
        (⟨table.documents.size⟩, { table with documents := table.documents.push (some document) })
  | .insert id offset s => edit id offset offset s
  | .delete id start stop => edit id start stop ""
  | .read id => do
    let some document ← document? id | return .error .noSuchText
    return .ok (← document.read)
  | .snapshot id => do
    let some document ← document? id | return .error .noSuchText
    let snapshot ← document.snapshot
    modifyGet fun table =>
        (.ok ⟨table.snapshots.size⟩,
          { table with snapshots := table.snapshots.push (some snapshot) })
  | .ask source query => do
    match ← snapshotOf source with
    | .error refusal =>
      return .error refusal
    | .ok snapshot =>
      answer snapshot query
  | .release source => do
    if let some refusal← missing? source then
      return .error refusal
    modify (·.released source)
    return .ok ()
  | .apply id transaction origin => apply id transaction origin

end RealTexts

/-- Runs a command against the Rust library, with `texts` as the texts made
so far: its result, or the refusal it failed with, and the table after its
last request. -/
def EditorM.runReal {α : Type} (command : EditorM α) (texts : RealTexts) :
    IO (Except TextError α × RealTexts) :=
  (Program.runM (port := textPort) RealTexts.handle command.run).run texts

end Editor
