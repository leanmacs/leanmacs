import Editor.State

/-!
# Marks following line deletions and undo, in the editor state

The rules of `Editor/Marks.lean` run on the marks of the editor state
(`Editor/State.lean`, "The jump list and marks") once an event has been
handled: the loop calls `EditorState.followMarks` in each publish, right
after each buffer's undo tree was told the revision its text is at
(`Loop.publish`, `EditorState.recordHistories`). For each buffer that is
not an excerpt buffer:

1. **Erase**: each lowercase mark of the buffer whose line, as read at the
   last publish, an edit since removed (`Marks.Line.removedIn`) is erased.
   A global mark is not: as Vim's `mark_adjust` moves an uppercase mark
   of a deleted line to the line that takes its place, its marker stays
   where the deletion left it.
2. **Put back**: the lowercase marks the buffer's history puts back for
   the move its undo tree made since (`Marks.History.follow`) are set
   again, each held by a new marker at its row and column; a node made
   since keeps the marks at the last boundary.
3. **Boundary**: when the tree has no open group, the lowercase marks as
   they are now are the boundary a node made next keeps. Inside an open
   group (an insert session) the boundary stays the one from before it.
4. **Lines**: the line of every lowercase mark left is read, with the
   text's revision, for the next publish.

The markers of the marks erased, and of those a mark put back replaced,
are given up here, since no command is running to give them up. A buffer
whose text refuses is left as it was, and the first refusal is handed
back.

Pinned by `ModelTest.evilMarkChecks`.
-/

namespace Editor

open Marks

/-- `state` with the marks of the buffer `id`, which is `buffer`, followed
through the event just handled (steps 1 to 4 of the module docs). -/
private def EditorState.followMarksOf (state : EditorState) (id : BufferId) (buffer : Buffer) :
    TextM EditorState := do
  let text := buffer.text
  let history := buffer.markHistory
  -- 1. Erase.
  let erased ←
    if history.lines.isEmpty then
      pure #[]
    else
      let patch ← text.changesSince history.revision
      pure ((history.lines.filter (·.removedIn patch)).map (·.marker))
  let mut marks := buffer.marks.filter fun (_, marker) => !erased.contains marker
  -- 2. Put back.
  let (restored, history) := history.follow buffer.history
  for mark in restored do
    let offset ← offsetAt text mark.row mark.column
    let marker ← text.mark (.anchor { offset, bias := .after })
    marks := (marks.filter (·.1 != mark.char)).push (mark.char, marker)
  -- 3. Boundary.
  let history ←
    if buffer.history.pending then
      pure history
    else
      pure { history with boundary := ← marks.mapM fun (char, marker) => atOf char marker }
  -- 4. Lines.
  let markers := marks.map (·.2)
  let history ←
    if markers.isEmpty then
      pure { history with lines := #[] }
    else
      pure
          { history with
            lines := ← markers.mapM lineOf, revision := ← text.revision }
  return { state with
      buffers :=
        state.buffers.set! id.index
          (some
            { buffer with
              marks, markHistory := history }) }

/-- `state` with the marks of every buffer but the excerpt buffers followed
through the event just handled (the module docs), and the markers of the
marks erased or replaced given up. It is not refused: a buffer whose text
refuses is left as it was, and the first refusal is handed back. -/
def EditorState.followMarks (state : EditorState) : TextM (EditorState × Option TextError) := do
  let before := state
  let mut state := state
  let mut refusal := none
  for index in [0:state.buffers.size] do
    let id : BufferId := ⟨index⟩
    let some buffer := state.buffer? id | continue
    if buffer.excerpts.isSome then
      continue
    match ← observing (state.followMarksOf id buffer) with
    | .ok followed =>
      state := followed
    | .error error =>
      refusal := refusal <|> some error
  let placed := state.placeMarkers
  for marker in before.placeMarkers do
    unless placed.contains marker do
      if let .error error← observing (marker.text.unmark marker) then
        refusal := refusal <|> some error
  return (state, refusal)

end Editor
