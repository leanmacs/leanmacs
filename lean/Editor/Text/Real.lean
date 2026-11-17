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
an id is an index into one (`RealTexts`; "The table of snapshots is
published", below, says where each table lives). Each request is one lookup in a table and one or
two calls of a binding. What an edit means, when it is refused, what a row
and a point are: these are the library's decisions (`crates/editor-text`),
and the contract (`Editor/Text/Contract.lean`) is what says they are the same
as the model's.

A question asked of a text is answered by a snapshot of it, taken for the
question and dropped after it. Taking one copies none of the text, so the
library needs one set of read functions, on a snapshot, and none on a
document.

A copy of a text or of a snapshot is a document the library makes from a
snapshot (`Ffi.Document.ofSnapshot`): the snapshot the request names, or one
taken of the text for the copy and dropped after it. The library shares the
text between the two and copies none of it.

What a job held when it ended is handed to the run of the job's command
(`TextM.runReal`'s `arrived`): the library's snapshots, each under the
job's name for it. `adopt` finds a name among them and adds the library's
snapshot to the table, which then holds the object together with whoever
handed it over. A run that is handed nothing, as every command's is but a
job's, adopts nothing. What was handed is dropped from the binding's state
when the run returns.

A transaction, and a question about a text's edit log, go to the text's
document, since a snapshot has no log. The port's counts, offsets and
revisions are `Nat` and the library's are machine words. In a transaction,
one that no word holds is sent as the largest word, which no text accepts,
so the library refuses it in its own order (`RealTexts.word`); everywhere
else it is refused here, as what the library would have said of a number
that large.

An excerpt text is a document the library makes with no excerpts
(`Ffi.Document.excerptsNew`) and then gives its list, the sources as an array
of their documents, one for each excerpt (`Ffi.Document.excerptsSet`). It is
added to the table only once the library accepts the list, so a refused list
makes no text. The library catches it up whenever it is read, and refuses its
edits: a refused edit or trace of it is told from a bad range by asking the
library whether it is an excerpt document (`RealTexts.badRangeOf`), and an
edit script is refused for one before the source is read. Any other request
the binding refuses itself, before it reaches the library (a marker id with
no number for the text's document, a revision no word holds), catches an
excerpt text up first (`RealTexts.catchUp`), as the port says every request
that names one does.

A text's markers are the library's: the binding keeps no table of them,
because a marker's id is its text and the library's number for it within
that text's document. The library numbers each document's markers on their
own, so the number alone does not say whose a marker is: an id is asked of
a document only when its text is the one the request names
(`RealTexts.markerWord?`, by the port's `MarkerId.numberIn?`), and is
refused with `noSuchMarker` otherwise. Each marker request is one lookup of
the document and one call. A marker's offsets go as a transaction's do, as
the largest word when no word holds them. An id no word holds names no
marker.

A text's kept inverses are the library's too, and the binding keeps no table
for them either: a run is two of the text's revisions, which are numbers of
its own document, so applying the inverse of a run and dropping kept
inverses are each one lookup of the document and one call. A revision no
word holds is one no text has reached. Nothing of an inverse comes back but
the revision it produced and the selection to place.

A text or a snapshot lives until it is released or its table is dropped,
whichever is first. Releasing empties its slot, which drops the last
reference to the library's object, and the finaliser frees it at once.
Dropping the table does the same for everything still in it.

## The table of snapshots is published

The documents are an array inside `RealTexts`, a value the editor thread
owns and passes from one command's run to the next. The snapshots are a
table behind a reference (`Snapshots`), which whoever starts the editor
makes first and hands to the binding (`RealTexts.over`).

- **Who writes it**: the handler here (`RealTexts.handle`), and nothing
  else: when a command takes a snapshot, adopts one or releases one. A
  command runs on the editor thread, so the editor thread is the table's one
  writer (`docs/design/concurrency.md`).
- **Who may read it, and through what**: a job, through the read half
  (`SnapshotReader`, from `Snapshots.reader`), which is all the job
  runner's file service is given (`Editor/Job/Real.lean`). It finds the
  library's snapshot for a `SnapshotId`, so a job can save a snapshot a
  command took. Nothing can be written through it. A read sees the table as
  it is at that instant: an id a command has released by then names
  nothing.
- **Why the snapshots and not the documents**: a snapshot never changes, and
  the library's object is safe on any thread, so a reader shares nothing
  that moves. A document has one writer and no reader but a command.

Every operation of the table is one atomic step of its reference, so a
reader sees the table before a write or after it.
-/

namespace Editor

/-- The read half of a table of snapshots: from an id, the library's
snapshot, if the table holds one at that instant. It is all a reader off the
editor thread is given, and nothing can be written through it. -/
structure SnapshotReader where
  /-- The library's snapshot for the snapshot `id`, as the table is now;
  `none` when the id names no snapshot, or one that was released. -/
  find? : SnapshotId → BaseIO (Option Ffi.Snapshot)

/-- The real binding's table of snapshots, behind a reference: the library's
handle for each snapshot taken or adopted so far. An id is an index here,
and a slot is `none` once its snapshot has been released, so an id is never
used again.

It is published: the module docs say who writes it and who may read it. Each
operation is one atomic step of the reference, so a reader on another thread
sees the table before a write or after it and never between. -/
structure Snapshots where private mk ::
  /-- The library's snapshot for each snapshot, in the order they entered. -/
  private slots : IO.Ref (Array (Option Ffi.Snapshot))

namespace Snapshots

/-- A table with no snapshots. -/
def new : BaseIO Snapshots :=
  return ⟨← IO.mkRef #[]⟩

/-- Adds `snapshot` to the table and returns its id: the next index. -/
def add (table : Snapshots) (snapshot : Ffi.Snapshot) : BaseIO SnapshotId :=
  table.slots.modifyGet fun slots => (⟨slots.size⟩, slots.push (some snapshot))

/-- The library's snapshot for the snapshot `id`, as the table is now; `none`
when the id names no snapshot, or one that was released. -/
def find? (table : Snapshots) (id : SnapshotId) : BaseIO (Option Ffi.Snapshot) :=
  return ((← table.slots.get)[id.index]?).join

/-- Empties the slot of the snapshot `id`, and returns whether it held one.
The slot stays, so later ids are what they would have been. -/
def release (table : Snapshots) (id : SnapshotId) : BaseIO Bool :=
  table.slots.modifyGet fun slots =>
    if (slots[id.index]?).join.isSome then (true, slots.setIfInBounds id.index none)
    else (false, slots)

/-- How many slots the table has: every snapshot that ever entered it, the
released ones included. A readout for tests. -/
def size (table : Snapshots) : BaseIO Nat :=
  return (← table.slots.get).size

/-- The read half of the table: it finds what the table holds when it is
asked, and nothing can be written through it. -/
def reader (table : Snapshots) : SnapshotReader where
  find? := table.find?

end Snapshots

/-- The tables of the real binding: the library's handle for each text and
for each snapshot made so far. An id is an index into one, and a slot is
`none` once its text or its snapshot has been released, so an id is never
used again. The documents are a value the editor thread owns; the snapshots
are a table it publishes (`Snapshots`). -/
structure RealTexts where
  /-- The library's document for each text, in the order they were made. -/
  documents : Array (Option Ffi.Document) := #[]
  /-- The library's snapshot for each snapshot, in the order they were taken
  or adopted. -/
  snapshots : Snapshots
  /-- The snapshots this run was handed: what a job held when it ended, each
  under the job's name for it. `TextM.runReal` sets it for one run and
  empties it after, so it is never part of the tables a later command
  finds. -/
  arrived : Array (JobSnapshotId × Ffi.Snapshot) := #[]

namespace RealTexts

/-- The tables with no texts, whose snapshots are the table `snapshots`. -/
def over (snapshots : Snapshots) : RealTexts where
  snapshots := snapshots

/-- The tables with no texts, over a table of snapshots made here: for a
caller that publishes its snapshots to nobody. -/
def new : BaseIO RealTexts :=
  return over (← Snapshots.new)

/-- The library's document for the text `id`; `none` when the id names no
text, or one that was released. -/
def document? (id : TextId) : StateT RealTexts IO (Option Ffi.Document) :=
  return ((← get).documents[id.index]?).join

/-- The library's snapshot for the snapshot `id`; `none` when the id names no
snapshot, or one that was released. -/
def snapshot? (id : SnapshotId) : StateT RealTexts IO (Option Ffi.Snapshot) := do
  (← get).snapshots.find? id

/-- The refusal of a range the library refused of `document`: `excerpted`
for an excerpt document, whose edits and traces are all refused, and
`badRange` for any other. -/
def badRangeOf (document : Ffi.Document) : IO TextError :=
  return if ← document.isExcerpts then .excerpted else .badRange

/-- Catches `document` up with its sources when it is an excerpt document, by
taking a snapshot of it, which locks it, and nothing otherwise. A request
that names an excerpt text catches it up before it is answered, refused
edits and traces aside, so a request refused here before it reaches the
library calls this first. -/
def catchUp (document : Ffi.Document) : IO Unit := do
  if ← document.isExcerpts then
    discard document.snapshot

/-- The library's answer to an edit of the text `id`, replacing its bytes
from `start` up to `stop` by `s`.

The port's offsets are `Nat` and the library's are machine words. An offset
no word holds is past the end of any text, so it is refused here: converted,
it would wrap round to an offset the library might accept. A refusal of an
excerpt text is `excerpted`, whatever the offsets (`badRangeOf`). -/
def edit (id : TextId) (start stop : Nat) (s : String) :
    StateT RealTexts IO (Except TextError Unit) := do
  let some document ← document? id | return .error .noSuchText
  unless start < USize.size ∧ stop < USize.size do
    return .error (← badRangeOf document)
  if ← document.replace start.toUSize stop.toUSize s then
    return .ok ()
  return .error (← badRangeOf document)

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

/-- The port's form of a selection of the library: what a marker read back
and an applied inverse both carry. -/
def selectionOf (ranges : Ffi.Selection) : Selection where
  ranges := ranges.ranges.map fun range => ⟨range.anchor.toNat, range.head.toNat⟩
  primary := ranges.primary.toNat
  shape :=
    match ranges.shape with
    | .exclusive => .exclusive
    | .inclusive => .inclusive
    | .line => .line
    | .block => .block

/-- The port's form of a marker of the library. -/
def markerOf : Ffi.Marker → Marker
  | .anchor position =>
    .anchor
      { offset := position.offset.toNat
        bias :=
          match position.bias with
          | .before => .before
          | .after => .after }
  | .selection ranges => .selection (selectionOf ranges)

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
    return .ok ⟨id, number.toNat⟩
  | .error refusal =>
    return .error (markRefusal refusal)

/-- The library's number for the marker `held`, to ask the document of the
text `id` with. `none` when the id names no marker of that text whatever the
document holds: another text gave it out (`MarkerId.numberIn?`; the library
numbers each document's markers on their own, so it could not tell), or no
word holds its number. -/
def markerWord? (id : TextId) (held : MarkerId) : Option UInt64 :=
  match held.numberIn? id with
  | some number => if number < UInt64.size then some number.toUInt64 else none
  | none => none

/-- The library's answer to reading the marker `held` of the text `id`. An
id with no number for that text's document names no marker; an excerpt text
is caught up first (`catchUp`). -/
def markerAt (id : TextId) (held : MarkerId) : StateT RealTexts IO (Except TextError Marker) := do
  let some document ← document? id | return .error .noSuchText
  let some number := markerWord? id held
    |
    do
      catchUp document
      return .error .noSuchMarker
  let some found ← document.marker number | return .error .noSuchMarker
  return .ok (markerOf found)

/-- The library's answer to putting `next` in place of the marker `held` of
the text `id`. The order of the refusals is the library's. An id with no
number for that text's document names no marker; the library refuses a
selection that is none before it looks an id up, so that is said here first
for such an id, after an excerpt text is caught up (`catchUp`). -/
def place (id : TextId) (held : MarkerId) (next : Marker) :
    StateT RealTexts IO (Except TextError Unit) := do
  let some document ← document? id | return .error .noSuchText
  let some number := markerWord? id held
    |
    do
      catchUp document
      match next with
      | .selection ranges =>
        return .error (if ranges.primary < ranges.ranges.size then .noSuchMarker else .badSelection)
      | .anchor _ =>
        return .error .noSuchMarker
  match ← document.place number (marker next) with
  | .ok () =>
    return .ok ()
  | .error refusal =>
    return .error (markRefusal refusal)

/-- The library's answer to giving up the marker `held` of the text `id`. An
id with no number for that text's document names no marker; an excerpt text
is caught up first (`catchUp`). -/
def unmark (id : TextId) (held : MarkerId) : StateT RealTexts IO (Except TextError Unit) := do
  let some document ← document? id | return .error .noSuchText
  let some number := markerWord? id held
    |
    do
      catchUp document
      return .error .noSuchMarker
  if ← document.unmark number then
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
  | .error .excerpted =>
    return .error .excerpted

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
converted, it would wrap round to one the library might answer. Such a
revision is refused after an excerpt text is caught up (`catchUp`); a trace
of one catches nothing up. -/
def answerLog (document : Ffi.Document) : (query : LogQuery) → IO (Except TextError query.Answer)
  | .since revision => do
    unless revision < UInt64.size do
      catchUp document
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
      return .error (← badRangeOf document)
    let some trace ←
      document.trace start.toUSize stop.toUSize | return .error (← badRangeOf document)
    return .ok (trace.map attribution)

/-- The library's answer to forgetting the log of the text `id` up to
`revision`. A revision no word holds is one no text has reached, refused
after an excerpt text is caught up (`catchUp`). -/
def forget (id : TextId) (revision : Nat) : StateT RealTexts IO (Except TextError Unit) := do
  let some document ← document? id | return .error .noSuchText
  unless revision < UInt64.size do
    catchUp document
    return .error .unknownRevision
  if ← document.forget revision.toUInt64 then
    return .ok ()
  return .error .unknownRevision

/-- The library's answer to applying to the text `id` the inverse of its run
of revisions from `first` to `last`, with `origin` as who made the edit.
When an inverse is allowed, in what order it is refused and what it hands
back are the library's decisions. A revision no word holds is one no text
has reached: converted, it would wrap round to one the text might have. -/
def applyInverse (id : TextId) (first last : Nat) (origin : Origin) :
    StateT RealTexts IO (Except TextError Inverted) := do
  let some document ← document? id | return .error .noSuchText
  unless first < UInt64.size ∧ last < UInt64.size do
    return .error (if ← document.isExcerpts then .excerpted else .unknownRevision)
  match ← document.applyInverse first.toUInt64 last.toUInt64 origin.id with
  | .ok inverted =>
    return .ok ⟨inverted.revision.toNat, inverted.selection.map selectionOf⟩
  | .error .unknownRevision =>
    return .error .unknownRevision
  | .error .noInverse =>
    return .error .noInverse
  | .error .notInState =>
    return .error .notInState
  | .error .excerpted =>
    return .error .excerpted

/-- The library's answer to dropping the inverses the text `id` keeps for
its revisions from `first` to `last`. A last revision no word holds is one
no text has reached, refused after an excerpt text is caught up (`catchUp`).
A first one no word holds is sent as the largest word (`word`), which is
after any last the library accepts, so nothing is dropped: what a run whose
first is after its last drops. -/
def dropInverses (id : TextId) (first last : Nat) : StateT RealTexts IO (Except TextError Unit) :=
  do
  let some document ← document? id | return .error .noSuchText
  unless last < UInt64.size do
    catchUp document
    return .error .unknownRevision
  if ← document.dropInverses (word first) last.toUInt64 then
    return .ok ()
  return .error .unknownRevision

/-- The library's name for a column unit of the port. -/
def unit : ColumnUnit → Ffi.ColumnUnit
  | .bytes => .bytes
  | .utf16 => .utf16
  | .cells => .cells

/-- The library's name for a kind of word of the port. -/
def wordKind : WordKind → Ffi.WordKind
  | .word => .word
  | .bigWord => .bigWord

/-- The library's form of a motion of the port. A count of rows and a column
that no word holds go as the largest word (`word`), which the library reads
as past any text's rows or cells: the motion stops at the first or the last
row and at the end of a row's content, as it does for any count or column
that large. -/
def motionOf : Motion → Ffi.Motion
  | .nextCell => .nextCell
  | .previousCell => .previousCell
  | .nextWordStart kind => .nextWordStart (wordKind kind)
  | .nextWordEnd kind => .nextWordEnd (wordKind kind)
  | .previousWordStart kind => .previousWordStart (wordKind kind)
  | .previousWordEnd kind => .previousWordEnd (wordKind kind)
  | .lineStart => .lineStart
  | .lineEnd => .lineEnd
  | .lineFirstNonBlank => .lineFirstNonBlank
  | .textStart => .textStart
  | .textEnd => .textEnd
  | .rowsUp count column => .rowsUp (word count) (word column)
  | .rowsDown count column => .rowsDown (word count) (word column)

/-- The library's kind of bracket for the port's. -/
def bracketOf : Bracket → Ffi.Bracket
  | .round => .round
  | .square => .square
  | .curly => .curly

/-- The library's kind of quote for the port's. -/
def quoteOf : Quote → Ffi.Quote
  | .double => .double
  | .single => .single
  | .back => .back

/-- The library's answer to `query` about `snapshot`.

The port's offsets, rows and columns are `Nat` and the library's are machine
words. One that no word holds is not a position of any text, so it is
refused here: converted, it would wrap round to one the library might
answer. For a range read that is `badRange`, as for an edit. -/
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
  | .extents ranges => do
    -- An offset no word holds goes as the largest word, which the library
    -- refuses as it would any other that is no position.
    let some extents ← snapshot.extents (selection ranges) | return .error .badSelection
    return .ok (extents.map fun extent => ⟨extent.start.toNat, extent.stop.toNat⟩)
  | .rowContent row => do
    -- A row no word holds is one no text has.
    unless row < UInt64.size do
      return .error .badPosition
    let some content ← snapshot.row row.toUInt64 | return .error .badPosition
    return .ok content
  | .slice start stop => do
    -- An offset no word holds is past the end of any text.
    unless start < USize.size ∧ stop < USize.size do
      return .error .badRange
    let some read ← snapshot.slice start.toUSize stop.toUSize | return .error .badRange
    return .ok read
  | .motion motion offset => do
    unless offset < USize.size do
      return .error .badPosition
    let some position ←
      snapshot.motion (motionOf motion) offset.toUSize | return .error .badPosition
    return .ok position.toNat
  | .search pattern forward offset => do
    unless offset < USize.size do
      return .error .badPosition
    match ← snapshot.search pattern forward offset.toUSize with
    | .found range wrapped =>
      return .ok (.found range.start.toNat range.stop.toNat wrapped)
    | .notFound =>
      return .ok .notFound
    | .invalid reason =>
      return .ok (.invalid reason)
    | .badPosition =>
      return .error .badPosition
  | .unmatched bracket opening forward escaped skipQuoted offset => do
    unless offset < USize.size do
      return .error .badPosition
    let some found ←
      snapshot.unmatched (bracketOf bracket) opening forward escaped skipQuoted
          offset.toUSize | return .error .badPosition
    return .ok (found.map (·.toNat))
  | .quoted quote offset => do
    unless offset < USize.size do
      return .error .badPosition
    let some found ← snapshot.quoted (quoteOf quote) offset.toUSize | return .error .badPosition
    return .ok (found.map fun range => ⟨range.start.toNat, range.stop.toNat⟩)
  | .matches pattern start stop => do
    unless start < USize.size ∧ stop < USize.size do
      return .error .badRange
    match ← snapshot.matches pattern start.toUSize stop.toUSize with
    | .ranges all =>
      return .ok (.ranges (all.map fun range => ⟨range.start.toNat, range.stop.toNat⟩))
    | .invalid reason =>
      return .ok (.invalid reason)
    | .badRange =>
      return .error .badRange

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

/-- The library's answer to giving `source` up: its slot is emptied and
stays, so later ids are what they would have been. The refusal when it names
nothing, or something that was released. -/
def release : TextSource → StateT RealTexts IO (Except TextError Unit)
  | .text id => do
    let some _ ← document? id | return .error .noSuchText
    modify fun table => { table with documents := table.documents.setIfInBounds id.index none }
    return .ok ()
  | .snapshot id => do
    if ← (← get).snapshots.release id then
      return .ok ()
    return .error .noSuchSnapshot

/-- The library's form of a step of an edit script. A count or an offset no
word holds goes as the largest word, which no text is long enough to accept,
so the library refuses it as a script that does not fit. -/
def scriptStep : Diff.Step → Ffi.ScriptStep
  | .retain count => .retain (word count)
  | .delete count => .delete (word count)
  | .insert start count => .insert (word start) (word count)

/-- The library's answer to applying `script` to the text `id`, taking what it
puts in from `source`, unless the text has moved past `base`. The refusals
come in the port's order: the text, then its revision, read from a snapshot
of it, then the source, then the library's own, which looks at the revision
again under the document's lock, so a script is never applied to a text that
moved in between. A base no word holds is one no text has reached. An excerpt
text is refused after the text is found and before anything else, so neither
it nor the source is caught up. -/
def applyScript (id : TextId) (base : Nat) (source : TextSource) (script : Diff.Script)
    (origin : Origin) : StateT RealTexts IO (Except TextError Nat) := do
  let some document ← document? id | return .error .noSuchText
  if ← document.isExcerpts then
    return .error .excerpted
  unless base < UInt64.size ∧ (← (← document.snapshot).info).revision.toNat == base do
    return .error .moved
  match ← snapshotOf source with
  | .error refusal =>
    return .error refusal
  | .ok taken =>
    match ← document.applyScript base.toUInt64 taken (script.map scriptStep) origin.id with
    | .ok revision =>
      return .ok revision.toNat
    | .error .moved =>
      return .error .moved
    | .error .badChange =>
      return .error .badChange
    | .error .excerpted =>
      return .error .excerpted

/-- The library's documents for the sources of `list`, one for each excerpt
in its order; `none` when a source names no text. -/
def sourcesOf? (list : Array Excerpt) : StateT RealTexts IO (Option (Array Ffi.Document)) := do
  let mut sources := #[]
  for excerpt in list do
    let some document ← document? excerpt.source | return none
    sources := sources.push document
  return some sources

/-- The library's answer to giving the excerpt document `document` the list
`list`, whose sources are `sources`, one for each excerpt. An offset no word
holds goes as the largest word (`word`), which no text is long enough to
accept, so the library refuses it as a range that is not two positions. -/
def setList (document : Ffi.Document) (sources : Array Ffi.Document) (list : Array Excerpt) :
    IO (Except TextError Unit) := do
  let words := list.mapIdx fun index excerpt => (index, word excerpt.start, word excerpt.stop)
  match ← document.excerptsSet sources words with
  | .ok () =>
    return .ok ()
  | .error .notExcerpts =>
    return .error .notExcerpted
  | .error .excerpted =>
    return .error .excerpted
  | .error .badRange =>
    return .error .badRange

/-- The library's answer to making an excerpt text of `list`: a new excerpt
document given the list, added to the table only when the library accepts
it, so a refused list makes no text and takes no id. -/
def createExcerpts (list : Array Excerpt) : StateT RealTexts IO (Except TextError TextId) := do
  let some sources ← sourcesOf? list | return .error .noSuchText
  let document ← Ffi.Document.excerptsNew
  match ← setList document sources list with
  | .error refusal =>
    return .error refusal
  | .ok () =>
    modifyGet fun table =>
        (.ok ⟨table.documents.size⟩,
          { table with documents := table.documents.push (some document) })

/-- The library's answer to replacing the list of the text `id` with `list`.
The text and whether it is an excerpt text are looked at here first, so the
refusals come in the port's order. -/
def setExcerpts (id : TextId) (list : Array Excerpt) :
    StateT RealTexts IO (Except TextError Unit) := do
  let some document ← document? id | return .error .noSuchText
  unless ← document.isExcerpts do
    return .error .notExcerpted
  let some sources ← sourcesOf? list | return .error .noSuchText
  setList document sources list

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
    return .ok (← (← get).snapshots.add (← document.snapshot))
  | .ask source query => do
    match ← snapshotOf source with
    | .error refusal =>
      return .error refusal
    | .ok snapshot =>
      answer snapshot query
  | .release source => release source
  | .apply id transaction origin => apply id transaction origin
  | .log id query => do
    let some document ← document? id | return .error .noSuchText
    answerLog document query
  | .forget id revision => forget id revision
  | .mark id held => mark id held
  | .marker id held => markerAt id held
  | .place id held next => place id held next
  | .unmark id held => unmark id held
  | .applyInverse id first last origin => applyInverse id first last origin
  | .dropInverses id first last => dropInverses id first last
  | .copy source => do
    match ← snapshotOf source with
    | .error refusal =>
      return .error refusal
    | .ok snapshot =>
      let document ← Ffi.Document.ofSnapshot snapshot
      modifyGet fun table =>
          (.ok ⟨table.documents.size⟩,
            { table with documents := table.documents.push (some document) })
  | .adopt held => do
    let some (_, snapshot) := (← get).arrived.find? (·.1 == held) | return .error .noSuchSnapshot
    return .ok (← (← get).snapshots.add snapshot)
  | .applyScript id base source script origin => applyScript id base source script origin
  | .excerpts list => createExcerpts list
  | .setExcerpts id list => setExcerpts id list

end RealTexts

/-- Runs a command against the Rust library, with `texts` as the texts made
so far: its result, or the refusal it failed with, and the table after its
last request.

`arrived` is what the run is handed: the snapshots a job held when it ended,
for the run of that job's command, and nothing for any other command. The
table that comes back holds none of it but what the command adopted. -/
def TextM.runReal {α : Type} (command : TextM α) (texts : RealTexts)
    (arrived : Array (JobSnapshotId × Ffi.Snapshot) := #[]) : IO (Except TextError α × RealTexts) :=
  do
  let (result, texts) ←
    (Program.runM (port := textPort) RealTexts.handle command.run).run { texts with arrived }
  return (result, { texts with arrived := #[] })

end Editor
