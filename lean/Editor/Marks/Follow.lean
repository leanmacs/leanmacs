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
   where the deletion left it. That matches Vim's line, not its column:
   Vim keeps the mark's column, and the marker here is at the start of
   the line (a recorded departure, task
   `global-mark-keeps-column-on-line-delete`).
2. **Put back**: the lowercase marks the buffer's history puts back for
   the move its undo tree made since (`Marks.History.follow`) are set
   again, each held by a new place marker (`Marks.placeMarker`) at its
   row and column; a node made
   since keeps the marks at the last boundary.
3. **Boundary**: when the tree has no open group, the lowercase marks as
   they are now are the boundary a node made next keeps. Inside an open
   group (an insert session) the boundary stays the one from before it.
4. **Lines**: the line of every lowercase mark left is read, with the
   text's revision, for the next publish.

The four steps are one function of a buffer (`Buffer.followedMarks`), and
each step of an undo or a redo runs them too, on its buffer, as the step is
taken (`BufferId.followMarks`, `Editor/Api.lean`): so a counted undo or
redo puts the marks back step by step, as Vim's `u_undoredo` does, and the
publish after it finds no move left to follow. The markers of the marks a
step erased or replaced are given up by the loop once its command has run
to its end, as a command's are (`Loop.gaveUp`); those of marks a later step
of the same command replaced again are not, as no marker a command made and
the state it left does not hold is.

The markers of the marks erased, and of those a mark put back replaced,
are given up here, since no command is running to give them up, by the
rule a finished command's are given up by (`EditorState.givenUpPlaces`).
A buffer whose text refuses is left as it was, and the first refusal is
handed back.

Pinned by `ModelTest.evilMarkChecks`.
-/

namespace Editor

open Marks

/-- The marks of `buffer` and what it keeps beside them, followed through
what changed since its history last looked (steps 1 to 4 of the module
docs). -/
def Buffer.followedMarks (buffer : Buffer) : TextM (Array (Char × MarkerId) × History) := do
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
    let marker ← placeMarker text offset
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
  return (marks, history)

/-- `state` with the marks of the buffer `id`, which is `buffer`, followed
through the event just handled (`Buffer.followedMarks`). -/
private def EditorState.followMarksOf (state : EditorState) (id : BufferId) (buffer : Buffer) :
    TextM EditorState := do
  let (marks, history) ← buffer.followedMarks
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
  let given ← EditorState.givenUpPlaces before state
  return (state, refusal <|> given)

end Editor
