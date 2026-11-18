import Editor.Ffi.Document

/-!
# Bindings: the snapshot

The bindings of `crates/editor-ffi/src/snapshot.rs`. The conventions they
follow, and the tests that pin each, are in the module docs of
`Editor/Ffi.lean` ("Handles", "Plain data").

`Document.ofSnapshot` binds `document.rs`'s `from_snapshot`; it is here
because it names both handle types.
-/

namespace Editor.Ffi

/-- The type behind `Snapshot`. It is opaque, so the only ways to get a
snapshot are `Document.snapshot` and a load's result (`filesTake`). -/
opaque SnapshotPointed : NonemptyType

/-- A text as it was at one moment, held by the Rust library: a third
handle. It is a document's text when the snapshot was taken, or the text of
a file the file service loaded. It never changes, whatever is done to the
document afterwards, and it stays alive after the document is freed. -/
def Snapshot : Type :=
  SnapshotPointed.type

instance : Nonempty Snapshot :=
  SnapshotPointed.property

/-- A snapshot of the document's text as it is now. It copies none of the
text. -/
@[extern "editor_glue_document_snapshot"]
opaque Document.snapshot (document : @& Document) : IO Snapshot

/-- What a snapshot is, as the glue builds it in one call: `UInt64` fields
only, so the order here is the layout the glue writes. -/
structure SnapshotInfo where
  /-- The revision of its document the snapshot holds: how many edits the
  document had accepted when the snapshot was taken. -/
  revision : UInt64
  /-- The length of the text in bytes. -/
  byteLength : UInt64
  /-- How many rows the text has: one more than its line feeds. -/
  rowCount : UInt64
  deriving DecidableEq, Repr, Inhabited

/-- The revision, the length in bytes and the row count of the snapshot. -/
@[extern "editor_glue_snapshot_info"]
opaque Snapshot.info (snapshot : @& Snapshot) : IO SnapshotInfo

/-- A copy of the whole text of the snapshot. -/
@[extern "editor_glue_snapshot_read"]
opaque Snapshot.read (snapshot : @& Snapshot) : IO String

/-- The unit a point's column is counted in. -/
inductive ColumnUnit where
  /-- Bytes of UTF-8. -/
  | bytes
  /-- UTF-16 code units. -/
  | utf16
  /-- Cells: how many cells of the row start before the position. A cell is
  one character, or a carriage return and the line feed after it together. -/
  | cells
  deriving DecidableEq, Repr

/-- A row and a column of a text, as the glue builds it: `UInt64` fields
only, so the order here is the layout the glue writes. The unit of the column
is the one the binding that returned the point was asked for. -/
structure Point where
  /-- Which row, from 0. A row begins after each line feed. -/
  row : UInt64
  /-- How far into the row. -/
  column : UInt64
  deriving DecidableEq, Repr

/-- The row and the column of the byte offset `offset` of the snapshot, with
the column counted in `unit`. `none` unless the offset is a position of the
text: within it, and not inside a character. -/
@[extern "editor_glue_snapshot_point_of"]
opaque Snapshot.pointOf (snapshot : @& Snapshot) (unit : ColumnUnit) (offset : USize) :
    IO (Option Point)

/-- The byte offset of the point `row`, `column` of the snapshot, with the
column counted in `unit`. `none` unless the point names a position of the
text: a row the text has, and a column within the row that is not inside a
character. -/
@[extern "editor_glue_snapshot_offset_of"]
opaque Snapshot.offsetOf (snapshot : @& Snapshot) (unit : ColumnUnit) (row column : UInt64) :
    IO (Option UInt64)

/-- Which words a motion goes by. -/
inductive WordKind where
  /-- Words: a longest run of word characters, or of punctuation. -/
  | word
  /-- WORDs: a longest run of characters that are not blank. -/
  | bigWord
  deriving DecidableEq, Repr

/-- A motion of the library: a way from one position of a text to another.
What each answers is the library's rule (`crates/editor-text`, `Motion`). A
count and a column are words: the library reads the largest as past any
text's rows or cells. -/
inductive Motion where
  /-- The first cell start after the position, or the end of the text. -/
  | nextCell
  /-- The last cell start before the position, or 0. -/
  | previousCell
  /-- The first start of a word of `kind` after the position, or the end of
  the text. -/
  | nextWordStart (kind : WordKind)
  /-- The first end of a word of `kind` after the position, empty lines not
  counted, or the end of the text. -/
  | nextWordEnd (kind : WordKind)
  /-- The last start of a word of `kind` before the position, or 0. -/
  | previousWordStart (kind : WordKind)
  /-- The last end of a word of `kind` before the position, or 0. -/
  | previousWordEnd (kind : WordKind)
  /-- Where the position's row starts. -/
  | lineStart
  /-- Where the content of the position's row ends. -/
  | lineEnd
  /-- The first position of the row's content whose character is not a
  blank, or where the content ends. -/
  | lineFirstNonBlank
  /-- The start of the text. -/
  | textStart
  /-- The end of the text. -/
  | textEnd
  /-- The position `column` cells into the row `count` rows up, or the
  first row. -/
  | rowsUp (count column : UInt64)
  /-- The position `column` cells into the row `count` rows down, or the
  last row. -/
  | rowsDown (count column : UInt64)
  deriving DecidableEq, Repr

/-- A motion as it crosses: its tag, and the count and the column of a
motion by rows, which are 0 for every other. The table of tags is in the
module docs of `crates/editor-ffi/src/motion.rs`, which checks the tag. -/
private def Motion.encode : Motion → UInt8 × UInt64 × UInt64
  | .nextCell => (0, 0, 0)
  | .previousCell => (1, 0, 0)
  | .nextWordStart .word => (2, 0, 0)
  | .nextWordEnd .word => (3, 0, 0)
  | .previousWordStart .word => (4, 0, 0)
  | .previousWordEnd .word => (5, 0, 0)
  | .nextWordStart .bigWord => (6, 0, 0)
  | .nextWordEnd .bigWord => (7, 0, 0)
  | .previousWordStart .bigWord => (8, 0, 0)
  | .previousWordEnd .bigWord => (9, 0, 0)
  | .lineStart => (10, 0, 0)
  | .lineEnd => (11, 0, 0)
  | .lineFirstNonBlank => (12, 0, 0)
  | .textStart => (13, 0, 0)
  | .textEnd => (14, 0, 0)
  | .rowsUp count column => (15, count, column)
  | .rowsDown count column => (16, count, column)

/-- `Snapshot.motion` as it crosses: the motion as a tag, a count and a
column. -/
@[extern "editor_glue_snapshot_motion"]
private opaque Snapshot.motionRaw (snapshot : @& Snapshot) (tag : UInt8) (count column : UInt64)
    (offset : USize) : IO (Option UInt64)

/-- Where `motion` leads from the byte offset `offset` of the snapshot.
`none` unless the offset is a position of the text: within it, and not inside
a character. -/
def Snapshot.motion (snapshot : Snapshot) (motion : Motion) (offset : USize) : IO (Option UInt64) :=
  let (tag, count, column) := motion.encode
  snapshot.motionRaw tag count column offset

/-- A copy of the content of the row `row` of the snapshot: the row without
its line break. `none` when the text has no such row. It reads that row and
no more of the text. -/
@[extern "editor_glue_snapshot_row"]
opaque Snapshot.row (snapshot : @& Snapshot) (row : UInt64) : IO (Option String)

/-- A copy of the snapshot's text from the byte offset `start` up to, not
including, `stop`. `none` unless both are positions of the text and
`start ≤ stop`. It reads that range and no more of the text. -/
@[extern "editor_glue_snapshot_slice"]
opaque Snapshot.slice (snapshot : @& Snapshot) (start stop : USize) : IO (Option String)

/-- How many snapshots the Rust library holds that have not been freed.

This exists for tests: `FfiTest` uses it to see a snapshot's finaliser run,
and `ContractTest` to see that the text port's table is the only holder of
its snapshots. -/
@[extern "editor_glue_snapshot_live"]
opaque Snapshot.live : IO UInt64

/-- A new document holding what `snapshot` holds: a text of its own, at
revision 0, with an empty log, no markers and no kept inverses, whatever the
snapshot's revision. It copies none of the text. An edit to it changes
neither the snapshot nor the document the snapshot was taken from, and it
outlives both. -/
@[extern "editor_glue_document_from_snapshot"]
opaque Document.ofSnapshot (snapshot : @& Snapshot) : IO Document

end Editor.Ffi
