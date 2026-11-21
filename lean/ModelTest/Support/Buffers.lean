import Editor.Api
import Editor.Buffers
import Editor.Buffers.Compiled
import Editor.Command
import Editor.Command.Call
import Editor.Config.Packages
import Editor.DisplayRules
import Editor.Ex.Line
import Editor.FileWatch
import Editor.FileWatch.Model
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Job.Model
import Editor.Language
import Editor.Layout
import Editor.Loop.Driver
import Editor.Mode
import Editor.Process
import Editor.Process.Environment
import Editor.Process.Model
import Editor.Program
import Editor.ProjectMode
import Editor.Scene
import Editor.State
import Editor.Test.Driver
import Editor.Test.Ex
import Editor.Test.Files
import Editor.Test.Keys
import Editor.Test.Loop
import Editor.Test.Minibuffer
import Editor.Test.Models
import Editor.Text
import Editor.Value
import Editor.Workspace
import FilesApiTest.Fake

/-!
# Model tests: support: Buffers

The buffer commands' keys and the driver they are pressed on, with buffers
opened on it. Shared by several test modules under `ModelTest/Editor/`; it holds
no checks of its own.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- What a step of the buffer command checks is handed. The commands are the
ones compiled code registers for files, the buffers and the ex line
(`files-api`'s fake's, `FilesApiTest.fake`, `Buffers.package.registered.commands`,
and the kit's ex line's, `Editor.Test.exLinePackage`, `Editor/Test/Ex.lean`,
which binds the ex names files' and the buffers' tests type to the
interfaces' names) and the kit's minibuffer's
(`Test.Minibuffer.package.registered.commands`, `Editor/Test/Minibuffer.lean`), each under the name it is registered under, told of the kit's ex
line's ex names (`exLinePackage.registered.ex`), and four written here: `split`, which
splits the window it is called with and leaves the focus,
`edit-then-close`, which inserts `x` at its window's cursors and then runs
`close-buffer` inside itself, so the edit and the close are one command,
`dock-others`, which docks every other window of the tiled list at the
left edge, and `close-anyway`,
which closes its window's buffer with `Buffers.close`, checking nothing.

One keymap, the same for every view: `C-e e` runs the ex command, `C-e y`
and `C-e t` the minibuffer's accept command and its command that moves to
the next candidate, `C-b b` runs `switch-buffer` with the arguments the Vim
scheme gives a command a key is bound to, a count and a register, `C-b n`
runs it with `note.txt`, `C-b s` runs `split`, `C-b x` runs
`edit-then-close`, `C-b d` runs `close-buffer` with no argument, `C-b m`
runs it with the name the minibuffer's buffer has (`Prompt.bufferName`),
`C-b h` runs `dock-others`, `C-b t` runs `new-tab`, which opens a tab after the one in
view on the call's window's buffer (`ViewId.newTab`), and `C-b c` runs
`close-anyway`. -/
def bufferKeys : Loop.Keys TestScheme.scheme :=
  let registrations :=
    FilesApiTest.fake.registered.commands ++ Test.Minibuffer.package.registered.commands ++
      Buffers.package.registered.commands ++
      exLinePackage.registered.commands
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
      ("new-tab", fun call => do
        discard <| call.target.window.id.newTab
        return none),
      ("close-anyway", fun call => do
        Buffers.close call.target.window.buffer
        return none)]
  {
    dispatchKeys
      [("C-e e", invoke Ex.name), ("C-e y", invoke Test.Minibuffer.acceptName),
        ("C-e t", invoke Test.Minibuffer.nextName),
        ("C-b b", { command := Buffers.switchName, arguments := [.nat 0, .str ""] }),
        ("C-b n", { command := Buffers.switchName, arguments := [.str "note.txt"] }),
        ("C-b s", invoke "split"), ("C-b x", invoke "edit-then-close"),
        ("C-b d", invoke Buffers.closeName),
        ("C-b m", { command := Buffers.closeName, arguments := [.str Prompt.bufferName] }),
        ("C-b h", invoke "dock-others"), ("C-b t", invoke "new-tab"),
        ("C-b c", invoke "close-anyway")]
      (compiled ++ written) with
    registered :=
      { ex := fun name => exLinePackage.registered.ex.findRev? (·.name == name),
        exNames := exNamesOf exLinePackage.registered.ex } }

/-- A driver of the buffer command checks over the initial state, with the
`files-api`'s fake's jobs and the files of the file command checks; `none` if
making the state was refused. -/
def buffersDriver : Option TestDriver :=
  (Loop.Driver.over bufferKeys FilesApiTest.jobs (EditorState.initial ⟨640, 480⟩)
        editorModel).toOption.map
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
