import Editor.Api
import Editor.Buffers
import Editor.Buffers.Compiled
import Editor.Command
import Editor.Command.Call
import Editor.Command.Dispatch
import Editor.Compile.Contribution
import Editor.Config.Registry
import Editor.Config.Stores
import Editor.DisplayRules
import Editor.Ex
import Editor.Ex.Compiled
import Editor.Ex.Line
import Editor.FileWatch
import Editor.FileWatch.Model
import Editor.Files
import Editor.Files.Compiled
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Job.Model
import Editor.Language
import Editor.Layout
import Editor.Loop
import Editor.Loop.Driver
import Editor.Minibuffer
import Editor.Minibuffer.Compiled
import Editor.Mode
import Editor.Process
import Editor.Process.Environment
import Editor.Process.Model
import Editor.Program
import Editor.Scene
import Editor.State
import Editor.Text
import Editor.Value
import Editor.Workspace
import ModelTest.Support.Driver
import ModelTest.Support.Files
import ModelTest.Support.Keys
import ModelTest.Support.Loop
import ModelTest.Support.Models

/-!
# Model tests: support: Buffers

The buffer commands' keys and the driver they are pressed on, with buffers
opened on it. Shared by several test modules under `ModelTest/Editor/`; it holds
no checks of its own.
-/

namespace ModelTest

open Editor

/-- What a step of the buffer command checks is handed. The commands are the
ones compiled code registers for files, the minibuffer, the buffers and the
ex line (`Files.commands`, `Minibuffer.commands`, `Buffers.commands`,
`Ex.commands`), each under the name it is registered under, told of the ex
names that ship (`Ex.bindings`), and five written here: `split`, which
splits the window it is called with and leaves the focus,
`edit-then-close`, which inserts `x` at its window's cursors and then runs
`close-buffer` inside itself, so the edit and the close are one command,
`dock-others`, which docks every other window of the tiled list at the
left edge, `focus-main`, which focuses the first window of the tiled list,
and `make-notes`, which makes a buffer called `notes`, or a free name made
from it, holding `a note`, adds the minor mode `notes` to it and displays
it for the command `make-notes` (`BufferId.display`), and `close-anyway`,
which closes its window's buffer with `Buffers.close`, checking nothing.

One keymap, the same for every view: `C-e e` runs the ex command, `C-e y`
and `C-e t` the minibuffer's accept command and its command that moves to
the next candidate, `C-b b` runs `switch-buffer` with the arguments the Vim
scheme gives a command a key is bound to, a count and a register, `C-b n`
runs it with `note.txt`, `C-b s` runs `split`, `C-b x` runs
`edit-then-close`, `C-b d` runs `close-buffer` with no argument, `C-b m`
runs it with the name the minibuffer's buffer has (`Prompt.bufferName`),
`C-b h` runs `dock-others`, `C-b f` runs `focus-main`, `C-b o` runs
`make-notes`, `C-b t` runs `new-tab`, which opens a tab after the one in
view on the call's window's buffer (`ViewId.newTab`), and `C-b c` runs
`close-anyway`. -/
def bufferKeys : Loop.Keys TestScheme.scheme :=
  let registrations := Files.commands ++ Minibuffer.commands ++ Buffers.commands ++ Ex.commands
  let compiled : List (String × Dispatched) :=
    registrations.toList.filterMap fun registration =>
      match registration.action with
      | .call run =>
        some
          (registration.name, fun call => do
            run call
            return none)
      | _ => none
  let written : List (String × Dispatched) :=
    [("split", fun call => do
        discard <| call.target.window.id.split
        return none),
      ("edit-then-close", fun call => do
        discard <| call.target.window.id.insertAtSelections "x"
        discard <| runCommand Buffers.closeName { call with arguments := [] }
        return none),
      ("dock-others", fun call => do
        for view in (← editorState).frame.windows do
          if view != call.target.window.id then
            discard <| view.arrange (.edge .left)
        return none),
      ("focus-main", fun _ => do
        if let some main := (← editorState).frame.windows[0]? then
          discard <| main.focus
        return none),
      ("new-tab", fun call => do
        discard <| call.target.window.id.newTab
        return none),
      ("close-anyway", fun call => do
        Buffers.close call.target.window.buffer
        return none),
      ("make-notes", fun call => do
        let name := (← editorState).freeName "notes"
        let .ok notes ← createBuffer name "a note" | giveUp "making notes was refused"
        discard <| notes.addMinorMode "notes"
        discard <| notes.display call.target.window.id "make-notes"
        return none)]
  {
    dispatchKeys
      [("C-e e", invoke Ex.name), ("C-e y", invoke Minibuffer.acceptName),
        ("C-e t", invoke Minibuffer.nextName),
        ("C-b b", { command := Buffers.switchName, arguments := [.nat 0, .str ""] }),
        ("C-b n", { command := Buffers.switchName, arguments := [.str "note.txt"] }),
        ("C-b s", invoke "split"), ("C-b x", invoke "edit-then-close"),
        ("C-b d", invoke Buffers.closeName),
        ("C-b m", { command := Buffers.closeName, arguments := [.str Prompt.bufferName] }),
        ("C-b h", invoke "dock-others"), ("C-b f", invoke "focus-main"),
        ("C-b o", invoke "make-notes"), ("C-b t", invoke "new-tab"),
        ("C-b c", invoke "close-anyway")]
      (compiled ++ written) with
    registered :=
      { ex := fun name => Ex.bindings.findRev? (·.name == name),
        exNames := exNamesOf Ex.bindings } }

/-- A driver of the buffer command checks over the initial state, with the
file commands' jobs and the files of the file command checks; `none` if
making the state was refused. -/
def buffersDriver : Option TestDriver :=
  (Loop.Driver.over bufferKeys fileJobs (EditorState.initial ⟨640, 480⟩) editorModel).toOption.map
    fun driver => { driver with jobs := { files := commandFiles } }

/-- `driver` with `note.txt`, `crlf.txt` and `lf.txt` opened in view 0, in
that order, each by the ex line `e` and its path, and each load finished
before the next: the loads are jobs 1, 2 and 3. The open buffers are then
`scratch`, `note.txt`, `crlf.txt` and `lf.txt`, and `lf.txt` is the most
recently used. -/
def threeOpen (driver : TestDriver) : TestDriver :=
  [("note.txt", 1), ("crlf.txt", 2), ("lf.txt", 3)].foldl
    (fun driver (name, job) => ((fedTo driver (exLine s!"e {inFiles name}")).1.finish job).1) driver

/-- `buffersDriver` with `threeOpen`'s three files open. -/
def buffersOpen : Option TestDriver :=
  buffersDriver.map threeOpen

/-- The name of the buffer view `view` of `driver` shows. -/
def shownName (driver : TestDriver) (view : ViewId := ⟨0⟩) : Option String :=
  (showing driver view).map (·.buffer.name)

end ModelTest
