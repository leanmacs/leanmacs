import Editor.Display
import Editor.Ffi
import Editor.Text.Real

/-!
# The real binding of the display interface

The display interface (`Editor/Display.lean`) answered by the Rust
library's layout (`crates/editor-layout`, behind `Ffi.Display`), over its
fake shaper until a real one exists (the display pipeline's phase 3).

It needs only the read half of the text binding's table of snapshots
(`SnapshotReader`): a query names its text by a `SnapshotId`, which the
table turns into the library's snapshot, and the library reaches the
document behind it, for its edit log, through the snapshot itself.

- A snapshot the table does not hold is refused here with
  `noSuchSnapshot`; an offset that is not a position, by the library, with
  `badPosition`.
- Numbers are `Nat` here and machine words in the library. One no word
  holds is sent as the largest word, which no text is long enough to
  accept, so it is refused, or, for a width, a height or a goal, is wider
  than any view: never cut down to one the library would read as another.

It is never imported by `Editor` or by anything `model-test` reaches: it
links the Rust library. `contract-test` holds it to the display contract
(`Editor/Display/Contract.lean`), and `ffi-test display` to the fixture
frame checked in at `tests/display/frame.expected`.
-/

namespace Editor

/-- The real binding: the library's display, and the read half of the text
binding's table of snapshots it finds a query's snapshot in. -/
structure RealDisplay where
  /-- The library's display. -/
  display : Ffi.Display
  /-- The snapshots a query may name. -/
  snapshots : SnapshotReader

namespace RealDisplay

/-- The library's machine word for an offset of the port: one no word
holds is the largest, past the end of every text. -/
def offset (number : Nat) : USize :=
  if number < USize.size then number.toUSize else (USize.size - 1).toUSize

/-- The rows a view shows: `Display.rowsShown`'s answer. -/
def rows (real : RealDisplay) (query : Display.RowsQuery) :
    IO (Except DisplayError (Array Display.Row)) := do
  let some snapshot ← real.snapshots.find? query.snapshot | return .error .noSuchSnapshot
  let answer ←
    real.display.rows snapshot (RealTexts.word query.width) (RealTexts.word query.height)
        (offset query.anchor)
  match answer with
  | some rows =>
    return .ok (rows.map fun row => { start := row.start.toNat, stop := row.stop.toNat })
  | none =>
    return .error .badPosition

/-- Where a move goes: `Display.linesFrom`'s answer. -/
def move (real : RealDisplay) (query : Display.MoveQuery) :
    IO (Except DisplayError Display.Moved) := do
  let some snapshot ← real.snapshots.find? query.snapshot | return .error .noSuchSnapshot
  let answer ←
    real.display.move snapshot (RealTexts.word query.width) (offset query.position) query.lines
        (query.goal.map RealTexts.word)
  match answer with
  | some moved =>
    return .ok { position := moved.position.toNat, goal := moved.goal.toNat }
  | none =>
    return .error .badPosition

/-- Answers `request` from the library. -/
def handle (real : RealDisplay) : (request : DisplayRequest) → IO request.Reply
  | .publish _ => pure ()
  | .rows query => real.rows query
  | .move query => real.move query

end RealDisplay

/-- Runs a display program against the real binding `real`: its result, or
the refusal it failed with. -/
def DisplayM.runReal {α : Type} (program : DisplayM α) (real : RealDisplay) :
    IO (Except DisplayError α) :=
  Program.runM (port := displayPort) real.handle program.run

end Editor
