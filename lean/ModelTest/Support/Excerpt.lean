import Editor.Api
import Editor.Command
import Editor.Command.Call
import Editor.Config.Registry
import Editor.Event
import Editor.Invocation
import Editor.Keymap
import Editor.Loop
import Editor.Loop.Driver
import Editor.Program
import Editor.State
import Editor.Test.Editing
import Editor.Test.Excerpt
import Editor.Test.Keys
import Editor.Test.Loop
import Editor.Test.Models
import ModelTest.Support.Switching

/-!
# Model tests: support: Excerpt

The excerpt buffer checks' driver, under `switching`, the scheme written
for the core's checks (`ModelTest/Support/Switching.lean`), with the kit's
editing keys. The commands the checks run (`excerptRegistrations`) and what
a check reads of an excerpt buffer are the kit's
(`Editor/Test/Excerpt.lean`), so a scheme package's checks of its own keys
in an excerpt buffer run the same commands. Shared by several test modules
under `ModelTest/Editor/`; it holds no checks of its own.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- A driver of the excerpt buffer checks: a loop over `switching`. -/
abbrev ExcerptDriver :=
  Loop.Driver switching

/-- What `undo-told` and `redo-told` say of a move that was made. -/
def historyMoved : String :=
  "history: moved"

/-- What `undo-told` and `redo-told` say when there was no step to move
to. -/
def historyNothing : String :=
  "history: nothing"

/-- What a move in a buffer's history answered (`BufferId.undo`,
`BufferId.redo`), as the commands `undo-told` and `redo-told` of the excerpt
buffer checks say it in the echo area: that it moved, that there was
nothing to move to, or the refusal. -/
def historyTold : Except BufferRefusal (Option Undone) → String
  | .ok (some _) => historyMoved
  | .ok none => historyNothing
  | .error refusal => s!"history: refused: {repr refusal}"

/-- What a step of the excerpt buffer checks is handed, under `switching`:
a printable key types, as the test scheme's does; `C-b` begins a session
the scheme reports, as a scheme's insert state is, and `C-e` ends it; the
kit's editing keys, `C-z` and `C-Z` its undo and redo among them
(`Editor/Test/Editing.lean`); and `C-u` and `C-r`, which run `undo-told`
and `redo-told`: one move in the history of the window's buffer, undone or
redone, whose answer the command says (`historyTold`) and whose selection
it leaves alone. The commands are those of `excerptRegistrations`, then
`more`, under their names, the kit's editing commands, and the two. -/
def excerptKeys (more : Array Config.Registration := #[]) : Loop.Keys switching :=
  let told (step : BufferId → EditorM (Except BufferRefusal (Option Undone))) : Dispatched :=
    fun call => do
    message (historyTold (← step call.target.window.buffer))
    return none
  let commands : List (String × Dispatched) :=
    editingDispatched ++ [("undo-told", told BufferId.undo), ("redo-told", told BufferId.redo)]
  { maps := fun _ _ =>
      [Keymap.ofList
          ((editingBindings ++
                [("C-b", invoke "begin"), ("C-e", invoke "end"), ("C-u", invoke "undo-told"),
                  ("C-r", invoke "redo-told")]).map
            fun (text, invocation) => (keys text, invocation))]
    command? := fun name =>
      match (excerptRegistrations ++ more).findRev? (·.name == name) with
      | some { action := .call run, .. } =>
        some fun call => do
          run call
          return none
      | _ =>
        match commands.find? (·.1 == name) with
        | some (_, command) => some command
        | none => if switchingTable.any (·.1 == name) then some fun _ => pure none else none }

/-- A driver of the excerpt buffer checks: `excerptKeys more`, over an empty
buffer, once `make-ex` has run, so the window shows `ex` with its cursor at
its start; `none` if making the state was refused. -/
def excerptDriverWith (more : Array Config.Registration := #[]) : Option ExcerptDriver :=
  (Loop.Driver.over (excerptKeys more) (fun _ => none) (barState "" 0) editorModel).toOption.map
    (excerptInvoked · "make-ex")

/-- `driver` once the keys `moves` names are pressed, if any, and each of
`texts` is then committed in one session the scheme reports: `C-b`, the
texts, `C-e`. The cursor is left after the last text. -/
def sessionTyped (driver : ExcerptDriver) (moves : String) (texts : List String) : ExcerptDriver :=
  let moved := if moves.isEmpty then driver else keysFed driver moves
  keysFed (excerptFed (keysFed moved "C-b") (texts.map Event.commit)) "C-e"

/-- The driver of the excerpt buffer checks with their own commands alone
(`excerptDriverWith`). -/
def excerptDriver : Option ExcerptDriver :=
  excerptDriverWith

end ModelTest
