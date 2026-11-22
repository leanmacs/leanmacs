import Editor.Api
import Editor.Command.Call
import Editor.Package
import Editor.Setup
import EvilApi

/-!
# The fake of `evil-api`

A package that registers a command under every name the interface
declares, each written over the core's API alone: `insert-newline` breaks
the line at the selections, `insert-tab` types a tab there, and `undo` and
`redo` take one step of the buffer's history and place the selection the
step hands back. A consumer's tests use it in place of any implementation,
so they import no implementation package.
-/

namespace EvilApiTest

open Editor

/-- One step of the buffer's history by `step` (`BufferId.undo` or `redo`),
with the selection it hands back placed; nothing when there is no step. -/
def stepped (step : BufferId → EditorM (Except BufferRefusal (Option Undone))) (call : Call) :
    EditorM Unit := do
  if let .ok (some undone)← step call.target.window.buffer then
    if let some selection := undone.selection then
      call.target.select selection

/-- The fake: a package named `evil-fake` that registers a command under
each of `EvilApi.names`, over the core's API (the module docs). -/
def fake : Package :=
  { name := "evil-fake"
    setup := do
      commandWith EvilApi.insertNewlineName fun call => call.target.insertLineBreak
      commandWith EvilApi.insertTabName fun call => call.target.insertAtSelections "\t"
      commandWith EvilApi.undoName (stepped BufferId.undo)
      commandWith EvilApi.redoName (stepped BufferId.redo) }

end EvilApiTest
