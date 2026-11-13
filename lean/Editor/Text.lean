import Editor.Program

/-!
# The text port

The editor's interface to text storage, in the editor's own terms: make a
text, insert into it, delete from it, apply a transaction to it, read it,
take a snapshot of it, ask a text or a snapshot a question, ask a text's
edit log what changed and who wrote a range, forget the start of that log,
mark a text with anchors and selections that every edit moves, and release a
text or a snapshot. It is deliberately small. The point is the
pattern every later interface follows:

- the port, here: the requests, the reply to each, and the operations a
  command is written with;
- its pure model, `Editor/Text/Model.lean`, which tests run against and
  theorems are stated about;
- its real binding, `Editor/Text/Real.lean`, the only module of the port that
  imports `Editor.Ffi`;
- its contract, `Editor/Text/Contract.lean`: one list of properties, run
  against the model by `model-test` and against the real binding by
  `contract-test`.

A command is a value of `EditorM`: a program over this port that may be
refused. Config and compiled commands are written at that one type, and the
same value runs against the model and against the real binding.

## The rules of the port

- A text is named by a `TextId`, which is plain data. Only `createText` makes
  one that names a text; any other is refused with `noSuchText`.
- Offsets are byte offsets into the text's UTF-8, as `Nat`. A *position* is
  an offset that is a character boundary of the text, within it: its end is
  one.
- An edit is refused with `badRange` unless both of its offsets are
  positions and the start is not after the stop.
- A *transaction* is the changes to make to a text and, optionally, the
  selection before them and the selection after them (`Transaction`). It is
  plain data, applied by one request, all or nothing.
- The *changes* walk the text from its start to its end: each keeps the next
  bytes, removes them, or puts text in (`Change`). Changes that do nothing
  (an empty insert, a retain or a delete of no bytes) are ignored, and a run
  of deletes and inserts between two retains is one changed range, whatever
  order its changes are given in. The changes *fit* a text only when they
  end exactly at its length and every changed range starts and stops at a
  position. Changes that stop short are refused, not padded, so a
  transaction built for another state of the text is caught where the
  lengths differ.
- A *selection* is one or more ranges of two offsets, an anchor and a head,
  the index of the primary one, and one shape for them all (`Selection`,
  `Shape`). One with no range, or whose primary names none, is not a
  selection.
- The store keeps a selection in one *form*, whatever it was given: its
  ranges sorted by where they start (the lower end) and then by
  where they end, and ranges that overlap made one, from the lowest start
  to the highest end. In the exclusive shape two ranges overlap when the
  later starts before the earlier ends, or both start at one offset: two
  cursors at one place are one, and ranges that only touch stay two. In the
  other shapes both ends are on characters, so two overlap when the later
  starts at or before the earlier's end. A merged range points the way the
  primary did if the primary is one of those it is made of, and otherwise
  the way the first of them did, in the sorted order (of two that start and
  end alike, the one given first); a range with equal ends points forward.
  The primary is the range the one given as primary ended in. A selection
  is checked against a text in this form: an end of a range that merged
  into another is no end of the selection.
- A transaction is refused, in this order: with `noSuchText`; with
  `badSelection` when a selection it carries is not one; with `badChange`
  when its changes do not fit; with `badSelection` when an end of the
  selection before is not a position of the text before; and with
  `badSelection` when an end of the selection after is not a position of
  the text after.
- A *marker* is an anchor or a selection that a text holds (`Marker`,
  `TextId.mark`), named by a `MarkerId`. An *anchor* is an offset and a
  bias (`Anchor`, `Bias`). A marker is refused unless it is in the text as
  it is: with `badPosition` for an anchor whose offset is not a position,
  and with `badSelection` for a selection that is none or has an end that
  is not a position. A selection read back (`TextId.marker`) is in the form
  above.
- Every accepted edit moves every marker of its text: an insert, a delete
  or a transaction. A refused edit moves none. Where the edit keeps the
  text round a position, the position moves with it. Otherwise the bias
  decides:

  | Where the position is | `before` | `after` |
  |---|---|---|
  | Where text is inserted and nothing removed | Stays before the inserted text | Goes after it |
  | At the start of, or inside, a range that is replaced | The start of the replacement | The end of the replacement |
  | At the start of, or inside, a range that is removed | Where the range was | The same |
  | At the end of a removed or replaced range | After the replacement | The same |

  An anchor moves by its own bias. The ends of a selection's ranges move as
  anchors, and the selection is put in its form again, so ranges an edit
  brought together are one. Both ends of a range are moved with the bias
  `after`, but for the higher end of an exclusive range whose ends differ,
  which is moved with `before`: text inserted at either edge of such a
  range stays outside it, and text inserted at a cursor is before it. Those
  two ends are the one pair that can pass each other, when all of the range
  is replaced at once; the range is then a cursor after the replacement.
- Two anchors of one bias never pass each other, and one that stays before
  inserted text never passes one that goes after it. An anchor that goes
  after and a later one that stays before can swap.
- A marker id belongs to its text: it is refused with `noSuchMarker` by any
  other, and once it is given up (`TextId.unmark`), for good. An id is
  never used again. The id says which text gave it out (`MarkerId.text`)
  beside that text's number for the marker, since each text numbers its
  own: so another text refuses it even where it holds a marker under the
  same number (`MarkerId.numberIn?`). `TextId.place` puts another marker
  under an id, of
  either kind. It is refused, in this order: with `noSuchText`; with
  `badSelection` for a selection that is none; with `noSuchMarker`; and
  then as marking is.
- Marking, placing and giving a marker up are not edits: the revision and
  the edit log are as they were. A snapshot holds no marker. Releasing a
  text gives up its markers.
- A *cell* is the unit a cursor is on: one character, or a carriage return
  and the line feed after it together. A character is a Unicode scalar
  value, not an extended grapheme cluster. At the end of the text there is
  no cell. A row's *content* is its bytes without its line break: without
  its line feed, and without the carriage return before that line feed.
- The ends of a selection's range say where two cursors are. What the range
  *covers* is a question of a text or a snapshot (`TextQuery.extents`),
  answered by the selection's shape, for a range from `start`, its lower
  end, to `stop`, its higher:

  | Shape | Covers |
  |---|---|
  | `exclusive` | From `start` up to, not including, `stop` |
  | `inclusive` | From `start` through the cell at `stop` |
  | `line` | From the start of `start`'s row to the end of `stop`'s row, and through its line feed if it has one |
  | `block` | For each row from `start`'s to `stop`'s, one extent: with the anchor's and the head's columns counted in cells from their rows' starts, from the lower column through the cell at the higher, cut off at the row's content. A row too short for the lower column gives an empty extent at the end of its content |

  So a cursor on a character is an inclusive range with equal ends: on the
  last character of a line it covers that character and not the line break,
  on an empty line it covers the line break, and at the end of the text it
  covers nothing. No end is clamped: keeping a cursor off a line break is
  the editor's rule.
- The extents come back sorted by start and then by stop, and two of them
  are one when the later starts before the earlier stops or both start at
  one offset. Extents that only touch stay two, and an extent may be empty.
  The question is refused with `badSelection` for a selection that is none
  or has an end that is not a position.
- An *origin* says who made an edit (`Origin`): a number the editor chooses
  and the store never reads. It is given when a transaction is applied, not
  carried in it. An insert and a delete are the transaction with that one
  change and no selection, made by `Origin.unattributed`.
- A text has an *edit log*: what each accepted edit changed, and its origin.
  It holds no text. A snapshot has none.
- An *edit* is one changed range (`Edit`): a span of the text before and a
  span of the text after, each as byte offsets and as points with their
  columns in bytes. An insertion has an empty old span and a deletion an
  empty new one.
- What changed since a revision is one *patch* (`Patch`), however many edits
  were made since. Its old spans are ranges of the text at that revision and
  its new spans ranges of the text now; they are in order, and no two
  overlap or touch, because changes that came to overlap or touch are one
  edit. Text inserted and deleted again in between is in none. It is refused
  with `unknownRevision` for a revision the text has not reached.
- A *subscriber* is a revision the asker keeps: it asks what changed since
  the revision of the last patch it got. Nothing is registered with the
  store, so nothing is queued for a subscriber and there is nothing to
  release.
- A *trace* of a range of the text as it is now cuts it into pieces, in
  order, each with its author (`Author`): the edit that inserted its bytes,
  by the revision it produced and its origin, or `earlier`, for bytes that
  were in the text where its log starts. Neighbours with one author are one
  piece. A range that is not two positions in order is refused with
  `badRange`.
- `forget` moves where a text's log starts to a revision; it starts at 0,
  the text as it was made. From then on what changed since an earlier
  revision is refused with `forgotten`, and a trace names bytes written at
  or before that revision as `earlier` than it. Forgetting to a revision at
  or before where the log starts changes nothing, and to one the text has
  not reached is refused with `unknownRevision`. The text is untouched.
  Nothing else shortens a log: when to forget is the editor's to decide.
- A text has a *revision*, a number. A new text is at 0, and every accepted
  edit adds one, an edit that changes nothing included: an insert, a delete,
  or a transaction, however many changes it has. A refused edit adds none.
- A *snapshot* is a text as it was when the snapshot was taken, at the
  revision it had then. It never changes: an edit to the text, and releasing
  the text, leave it as it was. It is named by a `SnapshotId`. Only
  `TextId.snapshot` makes one that names a snapshot; any other is refused
  with `noSuchSnapshot`.
- A text and a snapshot answer the same questions (`TextQuery`), and a text
  answers as a snapshot taken at that moment would.
- A *row* begins at the start of the text and after each line feed. So a
  text has one more row than it has line feeds: an empty text has one row,
  and a text that ends in a line feed has an empty last row. A carriage
  return is an ordinary character of its row and starts none.
- A *point* is a row and a column. The column counts from the row's start,
  in bytes of UTF-8 or in UTF-16 code units: the query says which
  (`ColumnUnit`). A character outside the Basic Multilingual Plane is two
  code units.
- A conversion answers only for a position, and clamps nothing. The point of
  an offset that is not a position is refused with `badPosition`. So is the
  offset of a point that names none: in a row the text does not have, past
  the end of its row, inside a character, or between the two code units of
  one. The column just past a row's last character is the position before
  its line feed.
- `release` gives up a text or a snapshot. Its id is refused from then on,
  for good: an id is never used again. Releasing a text leaves its snapshots
  readable.
- A refused request changes nothing.
- A refusal is a `throw` in `EditorM`. A command that fails leaves the store
  as it was at the failure: nothing here rolls back the requests it had
  already made.

The library keeps a byte of a file that is not valid UTF-8 as one character
in `U+10DC80..U+10DCFF` (`crates/editor-text`). To this port it is a
character like any other: four bytes long, and two UTF-16 code units.

## Adding to the port

A new question about a text is a constructor of `TextQuery` with its case in
`TextQuery.Answer`, and operations here that ask it of a text and of a
snapshot. It needs a clause in the model (`TextModel.answer`) and in the real
binding (`RealTexts.answer`), and a property in the contract. It is not a
new request: `ask` carries every question.

A new question about a text's edit log is a constructor of `LogQuery` with
its case in `LogQuery.Answer`, and an operation here that asks it. It needs
a clause in the model (`TextModel.answerLog`) and in the real binding
(`RealTexts.answerLog`), and a property in the contract. It is not a new
request either: `log` carries every one.

Anything else is a constructor of `TextRequest` with its case in
`TextRequest.Reply`, and an operation here that makes the request. It then
needs a clause in the model (`TextModel.handle`), a clause in the real binding
(`RealTexts.handle`), and a property in the contract (`TextContract.properties`),
which is what pins it for both. Grow the port with requests, not with new
ways to run a program.
-/

namespace Editor

/-- The name of a text held by the text store. It is plain data, so a request
can carry it. -/
structure TextId where
  /-- Which text: the store's index for it. -/
  index : Nat
  deriving DecidableEq, Repr

/-- The name of a snapshot held by the text store: a text as it was at one
moment. It is plain data, so a request can carry it. -/
structure SnapshotId where
  /-- Which snapshot: the store's index for it. -/
  index : Nat
  deriving DecidableEq, Repr

/-- Why the text store refused a request. -/
inductive TextError where
  /-- The id names no text: no `createText` returned it, or the text was
  released. -/
  | noSuchText
  /-- An offset is past the end of the text or inside a character, or the
  range ends before it starts. -/
  | badRange
  /-- The id names no snapshot: no `TextId.snapshot` returned it, or the
  snapshot was released. -/
  | noSuchSnapshot
  /-- An offset, or a point, is not a position of the text. -/
  | badPosition
  /-- A transaction's changes do not fit the text: they do not end at its
  length, or a range they change starts or stops inside a character. -/
  | badChange
  /-- A transaction's selection has no range, its primary names none, or an
  end of one of its ranges is not a position of its text. -/
  | badSelection
  /-- The text has not reached the revision. -/
  | unknownRevision
  /-- The revision is before where the text's edit log starts: the log was
  forgotten up to a later one. -/
  | forgotten
  /-- The id names no marker of the text: no `TextId.mark` of that text
  returned it (another text's did, or none), or the marker was given up. -/
  | noSuchMarker
  deriving DecidableEq, Repr

/-- The unit a point's column is counted in. -/
inductive ColumnUnit where
  /-- Bytes of UTF-8. This is the unit tree-sitter counts in. -/
  | bytes
  /-- UTF-16 code units. This is the unit a language server counts in. -/
  | utf16
  deriving DecidableEq, Repr

/-- A row and a column of a text. The column counts from the row's start, in
the unit of the query the point is given to or comes from. -/
structure Point where
  /-- Which row, from 0. -/
  row : Nat
  /-- How far into the row. -/
  column : Nat
  deriving DecidableEq, Repr

/-- What a question is asked of: a text as it is now, or a snapshot. -/
inductive TextSource where
  /-- The text `id`, as it is when the request is made. -/
  | text (id : TextId)
  /-- The snapshot `id`. -/
  | snapshot (id : SnapshotId)
  deriving DecidableEq, Repr

/-- One range of a selection: two byte offsets, in either order. -/
structure SelectionRange where
  /-- The end that stays when the selection is extended. -/
  anchor : Nat
  /-- The end that moves. -/
  head : Nat
  deriving DecidableEq, Repr

/-- What the ranges of a selection cover, given their two ends. -/
inductive Shape where
  /-- From the lower end up to, not including, the higher: the ends are
  between characters. A range with equal ends is a bar cursor. -/
  | exclusive
  /-- From the lower end through the character at the higher: both ends are
  on characters. A range with equal ends is a cursor on one. -/
  | inclusive
  /-- The whole rows of both ends and those between them. -/
  | line
  /-- A rectangle of characters whose corners are the two ends. -/
  | block
  deriving DecidableEq, Repr

/-- A selection: ranges, which of them is the primary one, and the shape
they all have. It is one only if it has a range and `primary` names one. The
ranges may be given in any order: the store keeps a selection in one form,
which the rules of the port give. -/
structure Selection where
  /-- The ranges. -/
  ranges : Array SelectionRange
  /-- The index in `ranges` of the primary range. -/
  primary : Nat := 0
  /-- What the ranges cover. -/
  shape : Shape := .exclusive
  deriving DecidableEq, Repr

/-- A range of bytes a selection covers: from `start` up to, not including,
`stop`. It may be empty. -/
structure Extent where
  /-- The offset of the first byte. -/
  start : Nat
  /-- The offset one past the last byte. -/
  stop : Nat
  deriving DecidableEq, Repr

/-- A question about a text or a snapshot. A new question is a constructor
here, not a request. -/
inductive TextQuery where
  /-- Its revision: how many edits the text had accepted. -/
  | revision
  /-- Its length in bytes. -/
  | byteLength
  /-- How many rows it has: one more than its line feeds. -/
  | rowCount
  /-- The whole of it. -/
  | contents
  /-- The point of the byte offset `offset`, with its column in `unit`. -/
  | pointOf (unit : ColumnUnit) (offset : Nat)
  /-- The byte offset of `point`, whose column is in `unit`. -/
  | offsetOf (unit : ColumnUnit) (point : Point)
  /-- What `selection` covers, by its shape. -/
  | extents (selection : Selection)

/-- The type of the answer to each question. It is an `abbrev` so that an
answer's type unfolds where an instance is looked for: with a `def`,
`(← text.rowCount) == 3` finds no `BEq`. -/
abbrev TextQuery.Answer : TextQuery → Type
  | .revision => Nat
  | .byteLength => Nat
  | .rowCount => Nat
  | .contents => String
  | .pointOf .. => Point
  | .offsetOf .. => Nat
  | .extents _ => Array Extent

/-- Who made an edit: a number the editor chooses and the text store keeps
with the edit and never reads. What a number stands for is the editor's
table. -/
structure Origin where
  /-- The number. -/
  id : UInt64
  deriving DecidableEq, Repr

/-- The origin of an edit nobody is named for: what `TextId.insert` and
`TextId.delete` are recorded with. That 0 means this is the editor's
convention. -/
def Origin.unattributed : Origin :=
  ⟨0⟩

/-- One step of a transaction's walk over a text, with its length in bytes. -/
inductive Change where
  /-- Keep the next `count` bytes. -/
  | retain (count : Nat)
  /-- Remove the next `count` bytes. -/
  | delete (count : Nat)
  /-- Put `text` in at this point. -/
  | insert (text : String)
  deriving DecidableEq, Repr

/-- Which side of text inserted at an anchor the anchor stays on. -/
inductive Bias where
  /-- The anchor stays before the inserted text. -/
  | before
  /-- The anchor goes after the inserted text. -/
  | after
  deriving DecidableEq, Repr

/-- A position in a text that moves with every edit: an offset and a bias. -/
structure Anchor where
  /-- Where the anchor is: a byte offset. -/
  offset : Nat
  /-- Which side of text inserted at the anchor it stays on. -/
  bias : Bias
  deriving DecidableEq, Repr

/-- Something a text holds and moves with every edit it accepts. -/
inductive Marker where
  /-- One position, moved by its bias. -/
  | anchor (anchor : Anchor)
  /-- A selection. Read back, it is in the form the store keeps one in. -/
  | selection (selection : Selection)
  deriving DecidableEq, Repr

/-- The name of a marker a text holds. It is plain data, and it belongs to
the text that gave it out: it names that text, and every other text refuses
it. -/
structure MarkerId where
  /-- The text that gave the id out, and holds the marker. -/
  text : TextId
  /-- Which marker: the text's number for it. Each text numbers its own
  markers, so the number alone does not say whose it is. -/
  index : Nat
  deriving DecidableEq, Repr

/-- The number `text` knows the marker `id` by; `none` when another text
gave the id out, so that it names no marker of `text`. This is the port's
rule that a marker id belongs to its text, and the model and the real
binding both look a marker up through it. -/
def MarkerId.numberIn? (id : MarkerId) (text : TextId) : Option Nat :=
  if id.text = text then some id.index else none

/-- A transaction: the changes to make to a text, and optionally the
selection before them and the selection after them. It is plain data, built
by a command and applied by one request. -/
structure Transaction where
  /-- The changes, which walk the text from its start to its end. -/
  changes : Array Change
  /-- The selection in the text before the changes. -/
  before : Option Selection := none
  /-- The selection in the text after the changes. -/
  after : Option Selection := none
  deriving DecidableEq, Repr

/-- The transaction for a text of `length` bytes that replaces its bytes from
`start` up to, not including, `stop` with `s` and keeps the rest. It is what
`TextId.insert` and `TextId.delete` do, for a range in order within the
text. -/
def Transaction.replacing (length start stop : Nat) (s : String) : Transaction where
  changes := #[.retain start, .insert s, .delete (stop - start), .retain (length - stop)]

/-- A range of one text: its byte offsets, and their points with the columns
in bytes. -/
structure Span where
  /-- The offset the range starts at. -/
  start : Nat
  /-- The offset the range stops at, not included. -/
  stop : Nat
  /-- The point of `start`. -/
  startPoint : Point
  /-- The point of `stop`. -/
  stopPoint : Point
  deriving DecidableEq, Repr

/-- One changed range: the bytes of `old`, a range of the text before, were
replaced by the bytes of `new`, a range of the text after. An insertion has
an empty `old` and a deletion an empty `new`. It carries no text. -/
structure Edit where
  /-- The range that was replaced, in the text before. -/
  old : Span
  /-- The range that replaced it, in the text after. -/
  new : Span
  deriving DecidableEq, Repr

/-- What changed in a text between two of its revisions, as one set of edits
in order, no two of which overlap or touch. -/
structure Patch where
  /-- The revision the patch starts from: the old spans are ranges of the
  text then. -/
  since : Nat
  /-- The revision the patch reaches, which is the text's when it was asked:
  the new spans are ranges of the text then. -/
  revision : Nat
  /-- What changed. -/
  edits : Array Edit
  deriving DecidableEq, Repr

/-- Who wrote a piece of a text. -/
inductive Author where
  /-- The edit that produced `revision`, made by `origin`, inserted the
  bytes. -/
  | entry (revision : Nat) (origin : Origin)
  /-- The bytes were already in the text at `revision`, which is as far back
  as its log reaches: 0, the text as it was made, until some of the log is
  forgotten. -/
  | earlier (revision : Nat)
  deriving DecidableEq, Repr

/-- One piece of a traced range: the bytes of the text as it is now from
`start` up to, not including, `stop`, and who wrote them. -/
structure Attribution where
  /-- The offset the piece starts at. -/
  start : Nat
  /-- The offset the piece stops at, not included. -/
  stop : Nat
  /-- Who wrote its bytes. -/
  author : Author
  deriving DecidableEq, Repr

/-- A question about a text's edit log. A new question is a constructor here,
not a request. It is not a `TextQuery`: a snapshot answers every one of
those, and a snapshot has no log. -/
inductive LogQuery where
  /-- What changed since `revision`, as one patch. -/
  | since (revision : Nat)
  /-- Who wrote the bytes from `start` up to, not including, `stop`. -/
  | trace (start stop : Nat)

/-- The type of the answer to each question about a log. It is an `abbrev`
for the reason `TextQuery.Answer` is. -/
abbrev LogQuery.Answer : LogQuery → Type
  | .since _ => Patch
  | .trace .. => Array Attribution

/-- What a command may ask of the text store. -/
inductive TextRequest where
  /-- Make a new text holding `initial`. -/
  | create (initial : String)
  /-- Insert `s` into `text` at the byte offset `offset`. -/
  | insert (text : TextId) (offset : Nat) (s : String)
  /-- Delete the bytes of `text` from `start` up to, not including, `stop`. -/
  | delete (text : TextId) (start stop : Nat)
  /-- Read the whole of `text`. -/
  | read (text : TextId)
  /-- Take a snapshot of `text` as it is now. -/
  | snapshot (text : TextId)
  /-- Ask `query` of `source`. -/
  | ask (source : TextSource) (query : TextQuery)
  /-- Give `source` up: its id is refused from then on. -/
  | release (source : TextSource)
  /-- Apply `transaction` to `text`, with `origin` as who made the edit. -/
  | apply (text : TextId) (transaction : Transaction) (origin : Origin)
  /-- Ask `query` of the edit log of `text`. -/
  | log (text : TextId) (query : LogQuery)
  /-- Forget the edit log of `text` up to `revision`. -/
  | forget (text : TextId) (revision : Nat)
  /-- Have `text` hold `marker`. -/
  | mark (text : TextId) (marker : Marker)
  /-- Read the marker `id` of `text`, where it is now. -/
  | marker (text : TextId) (id : MarkerId)
  /-- Put `marker` in place of the marker `id` of `text`. -/
  | place (text : TextId) (id : MarkerId) (marker : Marker)
  /-- Give up the marker `id` of `text`. -/
  | unmark (text : TextId) (id : MarkerId)

/-- The type of the reply to each request: the new text's id for `create`,
and for the others a refusal or the result. -/
def TextRequest.Reply : TextRequest → Type
  | .create _ => TextId
  | .insert .. => Except TextError Unit
  | .delete .. => Except TextError Unit
  | .read _ => Except TextError String
  | .snapshot _ => Except TextError SnapshotId
  | .ask _ query => Except TextError query.Answer
  | .release _ => Except TextError Unit
  | .apply .. => Except TextError Nat
  | .log _ query => Except TextError query.Answer
  | .forget .. => Except TextError Unit
  | .mark .. => Except TextError MarkerId
  | .marker .. => Except TextError Marker
  | .place .. => Except TextError Unit
  | .unmark .. => Except TextError Unit

/-- The text port: `TextRequest` and the reply to each request. -/
abbrev textPort : Port :=
  { Request := TextRequest, Reply := TextRequest.Reply }

/-- A command: a program over the editor's port that may be refused with a
`TextError`. It may change editor state, and it cannot block: it holds no
`IO`, and the port has no request that waits. -/
abbrev EditorM :=
  ExceptT TextError (Program textPort)

/-- Makes a new text holding `initial` and returns its id. -/
def createText (initial : String) : EditorM TextId :=
  ExceptT.lift (Program.request (port := textPort) (.create initial))

/-- Inserts `s` into `text` at the byte offset `offset`. Refused with
`badRange` unless `offset` is a character boundary within the text. -/
def TextId.insert (text : TextId) (offset : Nat) (s : String) : EditorM Unit :=
  ExceptT.mk (Program.request (port := textPort) (.insert text offset s))

/-- Deletes the bytes of `text` from `start` up to, not including, `stop`.
Refused with `badRange` unless both are character boundaries within the text
and `start ≤ stop`. -/
def TextId.delete (text : TextId) (start stop : Nat) : EditorM Unit :=
  ExceptT.mk (Program.request (port := textPort) (.delete text start stop))

/-- The whole of `text`. -/
def TextId.read (text : TextId) : EditorM String :=
  ExceptT.mk (Program.request (port := textPort) (.read text))

/-- Takes a snapshot of `text` as it is now and returns its id. Later edits
to the text do not change what the snapshot holds. -/
def TextId.snapshot (text : TextId) : EditorM SnapshotId :=
  ExceptT.mk (Program.request (port := textPort) (.snapshot text))

/-- The answer of `source` to `query`. The operations below ask each question
by name, of a text or of a snapshot. -/
def TextSource.ask (source : TextSource) (query : TextQuery) : EditorM query.Answer :=
  ExceptT.mk (Program.request (port := textPort) (.ask source query))

/-- Gives `source` up. Its id is refused from then on. -/
def TextSource.release (source : TextSource) : EditorM Unit :=
  ExceptT.mk (Program.request (port := textPort) (.release source))

/-- Applies `transaction` to `text`, with `origin` as who made the edit, and
returns the revision it produced: one more than before, however many changes
it has.

Refused, changing nothing, with `badSelection` when a selection is none,
with `badChange` when the changes do not fit the text, and with
`badSelection` when an end of the selection before is not a position of the
text before, or one of the selection after is not a position of the text
after. That is the order the refusals are looked for in. -/
def TextId.apply (text : TextId) (transaction : Transaction) (origin : Origin := .unattributed) :
    EditorM Nat :=
  ExceptT.mk (Program.request (port := textPort) (.apply text transaction origin))

/-- The answer of the edit log of `text` to `query`. The operations below ask
each question by name. -/
def TextId.askLog (text : TextId) (query : LogQuery) : EditorM query.Answer :=
  ExceptT.mk (Program.request (port := textPort) (.log text query))

/-- What changed in `text` since `revision`, as one patch, however many edits
were made since. Empty when `revision` is the text's revision now.

Refused with `unknownRevision` for a revision the text has not reached, and
with `forgotten` for one before where its log starts.

A consumer that follows a text keeps the `revision` of the last patch it got
and asks again from there. -/
def TextId.changesSince (text : TextId) (revision : Nat) : EditorM Patch :=
  text.askLog (.since revision)

/-- Who wrote the bytes of `text` from `start` up to, not including, `stop`:
the range cut into pieces, in order, each with its author. Empty for an empty
range. Refused with `badRange` unless both offsets are positions and
`start ≤ stop`. -/
def TextId.trace (text : TextId) (start stop : Nat) : EditorM (Array Attribution) :=
  text.askLog (.trace start stop)

/-- Forgets the edit log of `text` up to `revision`: the log starts there
from then on. The text and its revision are untouched. A revision at or
before where the log starts already changes nothing. Refused with
`unknownRevision` for a revision the text has not reached. -/
def TextId.forget (text : TextId) (revision : Nat) : EditorM Unit :=
  ExceptT.mk (Program.request (port := textPort) (.forget text revision))

/-- Has `text` hold `marker`, and returns the id it is read back by. From
then on every edit the text accepts moves it, until it is given up.

Refused, holding nothing, with `badSelection` for a selection that is none
or has an end that is not a position of the text, and with `badPosition`
for an anchor whose offset is not one. -/
def TextId.mark (text : TextId) (marker : Marker) : EditorM MarkerId :=
  ExceptT.mk (Program.request (port := textPort) (.mark text marker))

/-- The marker `id` of `text`, where it is in the text as it is now. A
selection comes back in the form the store keeps one in. Refused with
`noSuchMarker` for an id the text holds no marker for. -/
def TextId.marker (text : TextId) (id : MarkerId) : EditorM Marker :=
  ExceptT.mk (Program.request (port := textPort) (.marker text id))

/-- Puts `marker` in place of the marker `id` of `text`, which keeps its id:
the marker is somewhere else, or of the other kind.

Refused, changing nothing, with `badSelection` for a selection that is none,
with `noSuchMarker` for an id the text holds no marker for, and then as
`TextId.mark` refuses a marker. That is the order the refusals are looked
for in. -/
def TextId.place (text : TextId) (id : MarkerId) (marker : Marker) : EditorM Unit :=
  ExceptT.mk (Program.request (port := textPort) (.place text id marker))

/-- Gives up the marker `id` of `text`. The id is refused from then on.
Refused with `noSuchMarker` for an id the text holds no marker for. -/
def TextId.unmark (text : TextId) (id : MarkerId) : EditorM Unit :=
  ExceptT.mk (Program.request (port := textPort) (.unmark text id))

/-- The revision of `text`: how many edits it has accepted. -/
def TextId.revision (text : TextId) : EditorM Nat :=
  (TextSource.text text).ask .revision

/-- The length of `text` in bytes. -/
def TextId.byteLength (text : TextId) : EditorM Nat :=
  (TextSource.text text).ask .byteLength

/-- How many rows `text` has: one more than its line feeds. -/
def TextId.rowCount (text : TextId) : EditorM Nat :=
  (TextSource.text text).ask .rowCount

/-- The point of the byte offset `offset` of `text`, with its column in
`unit`. Refused with `badPosition` unless `offset` is a position. -/
def TextId.pointOf (text : TextId) (offset : Nat) (unit : ColumnUnit := .bytes) : EditorM Point :=
  (TextSource.text text).ask (.pointOf unit offset)

/-- The byte offset of `point` in `text`, where the point's column is in
`unit`. Refused with `badPosition` unless `point` names a position. -/
def TextId.offsetOf (text : TextId) (point : Point) (unit : ColumnUnit := .bytes) : EditorM Nat :=
  (TextSource.text text).ask (.offsetOf unit point)

/-- The ranges of bytes `selection` covers in `text`, by its shape: sorted,
with those that overlap made one. Refused with `badSelection` for a
selection that is none or has an end that is not a position. -/
def TextId.extents (text : TextId) (selection : Selection) : EditorM (Array Extent) :=
  (TextSource.text text).ask (.extents selection)

/-- Gives `text` up. Its id is refused from then on; its snapshots still
read. -/
def TextId.release (text : TextId) : EditorM Unit :=
  (TextSource.text text).release

/-- The whole of the text `snapshot` holds. -/
def SnapshotId.read (snapshot : SnapshotId) : EditorM String :=
  (TextSource.snapshot snapshot).ask .contents

/-- The revision its text had when `snapshot` was taken. -/
def SnapshotId.revision (snapshot : SnapshotId) : EditorM Nat :=
  (TextSource.snapshot snapshot).ask .revision

/-- The length in bytes of the text `snapshot` holds. -/
def SnapshotId.byteLength (snapshot : SnapshotId) : EditorM Nat :=
  (TextSource.snapshot snapshot).ask .byteLength

/-- How many rows the text `snapshot` holds has. -/
def SnapshotId.rowCount (snapshot : SnapshotId) : EditorM Nat :=
  (TextSource.snapshot snapshot).ask .rowCount

/-- The point of the byte offset `offset` of the text `snapshot` holds, with
its column in `unit`. Refused with `badPosition` unless `offset` is a
position. -/
def SnapshotId.pointOf (snapshot : SnapshotId) (offset : Nat) (unit : ColumnUnit := .bytes) :
    EditorM Point :=
  (TextSource.snapshot snapshot).ask (.pointOf unit offset)

/-- The byte offset of `point` in the text `snapshot` holds, where the
point's column is in `unit`. Refused with `badPosition` unless `point` names
a position. -/
def SnapshotId.offsetOf (snapshot : SnapshotId) (point : Point) (unit : ColumnUnit := .bytes) :
    EditorM Nat :=
  (TextSource.snapshot snapshot).ask (.offsetOf unit point)

/-- The ranges of bytes `selection` covers in the text `snapshot` holds, by
its shape: sorted, with those that overlap made one. Refused with
`badSelection` for a selection that is none or has an end that is not a
position. -/
def SnapshotId.extents (snapshot : SnapshotId) (selection : Selection) : EditorM (Array Extent) :=
  (TextSource.snapshot snapshot).ask (.extents selection)

/-- Gives `snapshot` up. Its id is refused from then on. -/
def SnapshotId.release (snapshot : SnapshotId) : EditorM Unit :=
  (TextSource.snapshot snapshot).release

end Editor
