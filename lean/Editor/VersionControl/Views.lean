import Editor.Api
import Editor.Command.Call
import Editor.Workspace.Attach

/-!
# What the version-control buffers share

The few steps every version-control buffer of generated text takes the same
way, kept once so that no buffer's module reaches into another's for them:

- **A day** (`dayOf`): a time in seconds since the epoch as its date in
  UTC, `YYYY-MM-DD`, as the log's and the blame's rows show it, each part
  padded with zeros (`zeroPadded`).
- **The cursor's row** (`selectionRow`, and `cursorRowOf` for a command's
  own window): the row of the primary cursor's head, which each buffer that
  lists one thing per row reads to find the thing on it.
- **A read-only buffer** (`readOnlyBufferOf`): a buffer of generated text,
  under the first free name of the one asked for, read-only and given a
  workspace. It is defined beside the workspace's attach
  (`Editor/Workspace/Attach.lean`), which this module imports, so that the
  working sets' drifted quotes (`Editor/WorkingSet/Run.lean`) make theirs
  the same way without importing a version-control module.
- **Showing it** (`displayFor`): where the display rules say for an opener,
  asked from the view that started the read, or from the focused one when
  that view is gone.

Written over the editor API (`Editor/Api.lean`). `dayOf` is pinned by
`ModelTest.versionControlViewsChecks` on values; the rest by the checks of
the buffers that call it.
-/

namespace Editor.VersionControl

/-- `value` in decimal, padded with zeros to `width` digits. -/
def zeroPadded (width value : Nat) : String :=
  let digits := toString value
  String.ofList (List.replicate (width - digits.length) '0') ++ digits

/-- The date, `YYYY-MM-DD` in UTC, of the time `seconds` since the epoch:
the civil date of its day (Howard Hinnant's `civil_from_days`). -/
def dayOf (seconds : Nat) : String :=
  let z := seconds / 86400 + 719468
  let era := z / 146097
  let dayOfEra := z - era * 146097
  let yearOfEra := (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146096) / 365
  let dayOfYear := dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
  let shifted := (5 * dayOfYear + 2) / 153
  let day := dayOfYear - (153 * shifted + 2) / 5 + 1
  let month := if shifted < 10 then shifted + 3 else shifted - 9
  let year := yearOfEra + era * 400 + if month ≤ 2 then 1 else 0
  s!"{zeroPadded 4 year}-{zeroPadded 2 month}-{zeroPadded 2 day}"

/-- The row in `text` of the head of `selection`'s primary range. -/
def selectionRow (text : TextId) (selection : Selection) : EditorM Nat := do
  let head := (selection.ranges[selection.primary]?.map (·.head)).getD 0
  return (← text.pointOf head).row

/-- The row of `call`'s cursor. -/
def cursorRowOf (call : Call) : EditorM Nat := do
  selectionRow call.target.buffer.text (← call.target.selection)

/-- Shows the buffer `id` where the display rules say for `opener`, asked
from `view`, or from the focused view when `view` is gone; focused unless
`focus` is false. -/
def displayFor (id : BufferId) (view : ViewId) (opener : String) (focus : Bool := true) :
    EditorM Unit := do
  let state ← editorState
  let asking := if (state.window? view).isSome then view else state.frame.focused
  discard <| id.display asking opener (focus := focus)

end Editor.VersionControl
