import Editor.Evil

/-!
# Evil's undo and redo

`u` and `C-r` on the buffer's undo tree
(`docs/design/keymaps-and-modes.md`, "Undo and redo"). The tree and its
moves are the editor API's (`BufferId.undo`, `BufferId.redo`,
`Editor/Api.lean`, "Undo"), which hand back the selection to place and
place nothing. Placing it is these commands'.

- **One step is what the loop closed** (`Editor/Loop.lean`, "Insert
  sessions"): a command in normal state, and a whole insert session, so the
  deletion of a change and the text typed after it are taken back
  together.
- **`undo`** moves back up to `count` steps, 1 with no count, and stops at
  the first that finds nothing. It then places one range of the shape its
  call's report says, with both ends on the head of the primary range the
  last step handed back, rested by the report's rule.
- **What an undo hands back is the selection from before the step's first
  edit**, which every edit of evil's carries as the selection from before
  its command (`Target.replaceCarrying`): the cursor the user saw. A step
  that began with typed text hands back the bar the insert began at, and
  the cell after that bar is the one the cursor was on. So an undo does
  not step back.
- **`redo`** moves forward the same way, and places what is handed back by
  the rule of entering a state (`Editor/Evil.lean`, "Entering a state"): a
  selection handed back in the exclusive shape is the bar an insert
  session ended with, and under a report of another shape its head first
  steps back one cell on its line, as `<Escape>` does. So a redo of a
  session leaves the cursor where `<Escape>` left it.
- **A step whose edits carried no selection** hands none back, and the
  cursor rests where the window's selection marker is, which the text
  moved with the edit.
- **With no step to take** the command says so in the echo area
  (`nothingToUndo`, `nothingToRedo`) and changes nothing. In a buffer a
  session restore made or reopened (`Buffer.historyRestored`), whose
  history starts at the restore, `undo` at the root says that instead
  (`nothingBeforeRestore`). It does not give
  up: nothing is rolled back, and nothing was done.
- **In an excerpt buffer** a step is one in each source buffer the step
  edited (`Editor/Api.lean`, "Undo"). When a source buffer moved since, the
  command says so instead (`sourceMovedSays`, with the source's name) and
  changes nothing. When a source buffer of the step was removed since, the
  command says so (`sourceRemovedSays`, with the name the step recorded),
  and that source is dropped from the step, the step with it once none is
  left, so the next `u` or `C-r` takes what is left, or the step under it.
  Such a step carries no selection, so the cursor rests where the window's
  marker moved.
- **The window keeps no wanted column** after either.
- **This is not Vim's rule for the cursor**, which leaves it at the start
  of the changed text: the phase asks for the cursor from before the
  change.

Pinned by `ModelTest.evilUndoChecks`, by key.
-/

namespace Editor.Evil

/-- What `undo` says in the echo area when the history has no step to
undo. -/
def nothingToUndo : String :=
  "nothing to undo"

/-- What `undo` says in the echo area when the history has no step to undo
in a buffer a session restore made or reopened: its history starts at the
restore. -/
def nothingBeforeRestore : String :=
  "nothing to undo: no history before the restore"

/-- What `redo` says in the echo area when the history has no step to
redo. -/
def nothingToRedo : String :=
  "nothing to redo"

/-- What `undo` and `redo` say in the echo area when an excerpt buffer's step
is refused because its source buffer called `name` changed since. -/
def sourceMovedSays (name : String) : String :=
  s!"{name} changed since"

/-- What `undo` and `redo` say in the echo area when an excerpt buffer's step
reached a source buffer called `name`, as it was called when the step was
closed, that has since been removed. -/
def sourceRemovedSays (name : String) : String :=
  s!"{name} was closed; its edits cannot be undone or redone here"

/-- Takes `step`, a move in a buffer's history, up to `count` times, 1 for a
count of 0, and stops at the first that finds nothing: how many were made,
the selection the last one handed back, if it handed one, and the refusal
that stopped it, if one did. -/
def moves (step : EditorM (Except BufferRefusal (Option Undone))) (count : Nat) :
    EditorM (Nat × Option Selection × Option BufferRefusal) := do
  let mut made := 0
  let mut handed := none
  for _ in [0:max count 1] do
    match ← step with
    | .ok (some moved) =>
      made := made + 1
      handed := moved.selection
    | .ok none =>
      break
    | .error refusal =>
      return (made, handed, some refusal)
  return (made, handed, none)

/-- What `undo` or `redo` says when it made no move: `sourceMovedSays` of the
source buffer's name for an excerpt step refused because a source moved,
`sourceRemovedSays` of the name the step recorded for one refused because a
source was removed, and `nothing` otherwise. -/
def unmovedSays (nothing : String) : Option BufferRefusal → EditorM String
  | some (.sourceMoved source) => do
    match (← editorState).buffer? source with
    | some buffer =>
      return sourceMovedSays buffer.name
    | none =>
      return nothing
  | some (.sourceRemoved name) => return sourceRemovedSays name
  | _ => return nothing

/-- The head of the primary range of `handed`, the selection a move in the
history handed back; the head of the window's own selection when it handed
none. -/
def headOf (call : Call) (handed : Option Selection) : TextM Nat := do
  let selection ←
    match handed with
    | some selection =>
      pure selection
    | none =>
      call.target.selection
  let some range := selection.ranges[selection.primary]? | throw .badSelection
  return range.head

/-- The undo command, Vim's `u`, as it is called (the module docs): up to
`count` steps of the target's buffer's history are undone, and the cursor
is put where the last of them says it was before the step, rested by the
rule of the call's report. With no step to undo it says so
(`nothingToUndo`), or, in a buffer a restore made, that its history starts
there (`nothingBeforeRestore`). -/
def undo (call : Call) : EditorM Unit := do
  let (made, handed, refused) ← moves call.target.window.buffer.undo (countOf call)
  if made == 0 then
    let nothing :=
      if call.target.buffer.historyRestored then nothingBeforeRestore else nothingToUndo
    message (← unmovedSays nothing refused)
  else
    settle call (← headOf call handed)
    discard <| call.target.window.id.setWanted none

/-- The redo command, Vim's `C-r`, as it is called (the module docs): up to
`count` steps of the target's buffer's history are redone, and the cursor
is put where the last of them left it: a bar handed back, which an insert
session ended with, first steps back one cell on its line under a report
of another shape, and the head is then rested by the report's rule. With no
step to redo it says so (`nothingToRedo`). -/
def redo (call : Call) : EditorM Unit := do
  let (made, handed, refused) ← moves call.target.window.buffer.redo (countOf call)
  if made == 0 then
    message (← unmovedSays nothingToRedo refused)
  else
    let text := call.target.buffer.text
    let head ← headOf call handed
    let leavesInsert := (handed.map (·.shape)) == some .exclusive && call.report.shape != .exclusive
    let back ←
      if leavesInsert && (← text.motion .lineStart head) < head then
        text.motion .previousCell head
      else
        pure head
    settle call back
    discard <| call.target.window.id.setWanted none

end Editor.Evil
