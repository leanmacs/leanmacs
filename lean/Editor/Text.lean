import Editor.Program

/-!
# The text port

The editor's interface to text storage, in the editor's own terms: make a
text, insert into it, delete from it, read it, take a snapshot of it, ask a
text or a snapshot a question, and release either. It is deliberately small.
The point is the pattern every later interface follows:

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
- A text has a *revision*, a number. A new text is at 0, and every accepted
  edit adds one, an edit that changes nothing included. A refused edit adds
  none.
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

/-- Gives `snapshot` up. Its id is refused from then on. -/
def SnapshotId.release (snapshot : SnapshotId) : EditorM Unit :=
  (TextSource.snapshot snapshot).release

end Editor
