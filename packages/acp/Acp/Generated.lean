import Editor.Api
import Editor.Jumps

/-!
# A buffer whose text acp generates

A conversation buffer and a permission queue buffer are read-only, and
their text is regenerated whole from acp's stores after each change
(`Acp.Generated.rewrite`): written again inside `BufferId.writing`, so a
read-only buffer takes it, with each view of the buffer keeping its
cursor's row, clamped to the new text. A buffer that follows its end (a
conversation's) moves a view whose cursor was on the last line, or the
empty row after it, to the new last line instead.
-/

namespace Acp.Generated

open Editor

/-- The row of the cursor of `view` in `text`, if it has one. -/
def cursorRow (view : ViewId) (text : TextId) : EditorM (Option Nat) := do
  match ← view.selection with
  | .ok selection =>
    let head := (selection.ranges[selection.primary]?.map (·.head)).getD 0
    return some (← text.pointOf head).row
  | .error _ =>
    return none

/-- Writes `content` as the whole text of the buffer `id` (the module docs):
each view keeps its cursor's row, clamped to the text; with `follow`, a view
whose cursor is on the last line, or the empty row after it, moves to the
new last line. Nothing for a buffer there is none of. -/
def rewrite (id : BufferId) (content : String) (follow : Bool) : EditorM Unit := do
  let .ok text ← id.text | return
  let state ← editorState
  let count ← text.lineCount
  let mut followers := #[]
  let mut kept := #[]
  for window in state.windows.filter (·.buffer == id) do
    if let some row← cursorRow window.id text then
      if follow && row + 1 ≥ count then
        followers := followers.push window.id
      else
        kept := kept.push (window.id, row)
  id.writing do
      text.replaceRange 0 (← text.byteLength) content
  let count ← text.lineCount
  let last ← text.offsetOf { row := count - 1, column := 0 }
  for view in followers do
    Jumps.placeCursor view last
  for (view, row) in kept do
    Jumps.placeCursor view (← text.offsetOf ⟨min row (count - 1), 0⟩)

end Acp.Generated
