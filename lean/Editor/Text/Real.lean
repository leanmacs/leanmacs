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

A transaction, and a question about a text's edit log, go to the text's
document, since a snapshot has no log. The port's counts, offsets and
revisions are `Nat` and the library's are machine words. In a transaction,
one that no word holds is sent as the largest word, which no text accepts,
so the library refuses it in its own order (`RealTexts.word`); everywhere
else it is refused here, as what the library would have said of a number
that large.

A text's markers are the library's: the binding keeps no table of them,
because a marker's id is the library's number for it within its document.
Each marker request is one lookup of the document and one call. A marker's
offsets go as a transaction's do, as the largest word when no word holds
them. An id no word holds names no marker.

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

/-- The library's name for a shape of the port. -/
def shape : Shape → Ffi.Shape
  | .exclusive => .exclusive
  | .inclusive => .inclusive
  | .line => .line
  | .block => .block

/-- The library's form of a selection of the port. -/
def selection (selection : Selection) : Ffi.Selection where
  ranges := selection.ranges.map fun range => ⟨word range.anchor, word range.head⟩
  primary := word selection.primary
  shape := shape selection.shape

/-- The library's form of a marker of the port. -/
def marker : Marker → Ffi.Marker
  | .anchor position =>
    .anchor
      { offset := word position.offset
        bias :=
          match position.bias with
          | .before => .before
          | .after => .after }
  | .selection ranges => .selection (selection ranges)

/-- The port's form of a marker of the library. -/
def markerOf : Ffi.Marker → Marker
  | .anchor position =>
    .anchor
      { offset := position.offset.toNat
        bias :=
          match position.bias with
          | .before => .before
          | .after => .after }
  | .selection ranges =>
    .selection
      { ranges := ranges.ranges.map fun range => ⟨range.anchor.toNat, range.head.toNat⟩
        primary := ranges.primary.toNat
        shape :=
          match ranges.shape with
          | .exclusive => .exclusive
          | .inclusive => .inclusive
          | .line => .line
          | .block => .block }

/-- The port's refusal for a refusal of a marker by the library. -/
def markRefusal : Ffi.MarkRefusal → TextError
  | .badPosition => .badPosition
  | .badSelection => .badSelection
  | .noSuchMarker => .noSuchMarker

/-- The library's answer to marking the text `id` with `held`. Which markers
are refused is the library's decision. -/
def mark (id : TextId) (held : Marker) : StateT RealTexts IO (Except TextError MarkerId) := do
  let some document ← document? id | return .error .noSuchText
  match ← document.mark (marker held) with
  | .ok number =>
    return .ok ⟨number.toNat⟩
  | .error refusal =>
    return .error (markRefusal refusal)

/-- The library's answer to reading the marker `held` of the text `id`. An
id no word holds names no marker. -/
def markerAt (id : TextId) (held : MarkerId) : StateT RealTexts IO (Except TextError Marker) := do
  let some document ← document? id | return .error .noSuchText
  unless held.index < UInt64.size do
    return .error .noSuchMarker
  let some found ← document.marker held.index.toUInt64 | return .error .noSuchMarker
  return .ok (markerOf found)

/-- The library's answer to putting `next` in place of the marker `held` of
the text `id`. The order of the refusals is the library's. An id no word
holds names no marker; the library refuses a selection that is none before
it looks an id up, so that is said here first for such an id. -/
def place (id : TextId) (held : MarkerId) (next : Marker) :
    StateT RealTexts IO (Except TextError Unit) := do
  let some document ← document? id | return .error .noSuchText
  unless held.index < UInt64.size do
    match next with
    | .selection ranges =>
      return .error (if ranges.primary < ranges.ranges.size then .noSuchMarker else .badSelection)
    | .anchor _ =>
      return .error .noSuchMarker
  match ← document.place held.index.toUInt64 (marker next) with
  | .ok () =>
    return .ok ()
  | .error refusal =>
    return .error (markRefusal refusal)

/-- The library's answer to giving up the marker `held` of the text `id`. -/
def unmark (id : TextId) (held : MarkerId) : StateT RealTexts IO (Except TextError Unit) := do
  let some document ← document? id | return .error .noSuchText
  unless held.index < UInt64.size do
    return .error .noSuchMarker
  if ← document.unmark held.index.toUInt64 then
    return .ok ()
  return .error .noSuchMarker

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

/-- The port's form of a span of the library. -/
def span (span : Ffi.Span) : Span where
  start := span.start.toNat
  stop := span.stop.toNat
  startPoint := ⟨span.startPoint.row.toNat, span.startPoint.column.toNat⟩
  stopPoint := ⟨span.stopPoint.row.toNat, span.stopPoint.column.toNat⟩

/-- The port's form of a piece of a trace of the library. -/
def attribution (piece : Ffi.Attribution) : Attribution where
  start := piece.start.toNat
  stop := piece.stop.toNat
  author :=
    match piece.author with
    | .entry revision origin => .entry revision.toNat ⟨origin⟩
    | .earlier revision => .earlier revision.toNat

/-- The library's answer to `query` about the log of `document`.

The port's revisions and offsets are `Nat` and the library's are machine
words. A revision no word holds is one no text has reached, and an offset no
word holds is past the end of any text, so each is refused here as that:
converted, it would wrap round to one the library might answer. -/
def answerLog (document : Ffi.Document) : (query : LogQuery) → IO (Except TextError query.Answer)
  | .since revision => do
    unless revision < UInt64.size do
      return .error .unknownRevision
    match ← document.changesSince revision.toUInt64 with
    | .ok patch =>
      return .ok
          { since := patch.since.toNat
            revision := patch.revision.toNat
            edits := patch.edits.map fun edit => ⟨span edit.old, span edit.new⟩ }
    | .error .unknownRevision =>
      return .error .unknownRevision
    | .error .forgotten =>
      return .error .forgotten
  | .trace start stop => do
    unless start < USize.size ∧ stop < USize.size do
      return .error .badRange
    let some trace ← document.trace start.toUSize stop.toUSize | return .error .badRange
    return .ok (trace.map attribution)

/-- The library's answer to forgetting the log of the text `id` up to
`revision`. A revision no word holds is one no text has reached. -/
def forget (id : TextId) (revision : Nat) : StateT RealTexts IO (Except TextError Unit) := do
  let some document ← document? id | return .error .noSuchText
  unless revision < UInt64.size do
    return .error .unknownRevision
  if ← document.forget revision.toUInt64 then
    return .ok ()
  return .error .unknownRevision

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
  | .log id query => do
    let some document ← document? id | return .error .noSuchText
    answerLog document query
  | .forget id revision => forget id revision
  | .mark id held => mark id held
  | .marker id held => markerAt id held
  | .place id held next => place id held next
  | .unmark id held => unmark id held

end RealTexts

/-- Runs a command against the Rust library, with `texts` as the texts made
so far: its result, or the refusal it failed with, and the table after its
last request. -/
def EditorM.runReal {α : Type} (command : EditorM α) (texts : RealTexts) :
    IO (Except TextError α × RealTexts) :=
  (Program.runM (port := textPort) RealTexts.handle command.run).run texts

end Editor
